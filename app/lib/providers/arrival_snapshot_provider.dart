/// Keeps the device-local arrival snapshot in step with the switched-on Places
/// and the Outcomes and Habits due at them (issues #1092, #1095).
///
/// The snapshot is what the background arrival code reads while Jeeves is
/// closed. It is written here, in the foreground, from the store — and from
/// the device-local record of the Places the user switched on, which lives in
/// shared preferences rather than in the store.
///
/// The visit record is pruned to the same Places: a visit at a Place Jeeves no
/// longer watches is a visit nobody acts on.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../models/action_place_and_time_window.dart';
import '../models/habit_commitment.dart';
import '../models/habit_days.dart';
import '../models/habit_for_day.dart';
import '../models/habit_progress.dart';
import '../services/arrival_snapshot.dart';
import '../services/arrival_visit_rule.dart';
import '../services/geofence_registrar.dart';
import '../services/location_source.dart';
import 'arrival_notification_settings.dart';
import 'database_provider.dart';
import 'habit_progress_provider.dart'
    show habitHistoriesProvider, habitTodayProvider;
import 'location_source_provider.dart';
import 'place_gate_provider.dart';

/// The user's named Places, watched.
final namedPlacesProvider = StreamProvider<List<Place>>((ref) {
  return ref.watch(databaseProvider).placeDao.watchNamedPlaces();
});

/// The Outcomes on Next, watched.
///
/// Next before any hiding: an Outcome whose time window has closed is still
/// due at its Place, and the arrival notification is about being there, not
/// about the clock.
final nextOutcomesProvider = StreamProvider<List<Todo>>((ref) {
  return ref.watch(databaseProvider).todoDao.watchNext();
});

/// The files the arrival path reads and writes on this device.
final arrivalFilesProvider = FutureProvider<ArrivalFiles>((ref) async {
  ref.keepAlive();
  return ArrivalFiles.inApplicationSupport();
});

/// The OS's list of Places to watch.
final geofenceRegistrarProvider = Provider<GeofenceRegistrar>((ref) {
  return createGeofenceRegistrar();
});

/// The writer that keeps the arrival snapshot in step.
///
/// It is a provider of its own because the reconciler below is rebuilt every
/// time the app learns something new, and a writer that was thrown away with
/// every rebuild would not know what it had already written.
final arrivalSnapshotWriterProvider = Provider<ArrivalSnapshotWriter?>((ref) {
  // The web has no arrival notification, so it has no snapshot to keep.
  if (!arrivalNotificationsSupported) return null;

  final writer = ArrivalSnapshotWriter(
    files: ref.watch(arrivalFilesProvider.future),
    registrar: ref.watch(geofenceRegistrarProvider),
    permission: () => ref.read(locationSourceProvider).permission(),
  );
  // Android can drop a geofence while Jeeves is away, so the OS's list is
  // checked again each time the app comes back.
  final observer = _ResumeObserver(writer.reconcileGeofencesAgain);
  WidgetsBinding.instance.addObserver(observer);
  ref.onDispose(() {
    WidgetsBinding.instance.removeObserver(observer);
    writer.dispose();
  });
  return writer;
});

/// Writes the arrival snapshot for what the app knows now.
///
/// Nothing else reads it, so without a watch in `main.dart` it would never
/// run. On the web it does nothing at all: there is no arrival notification
/// there, so there is no snapshot to keep.
///
/// Each of the things it reads is watched, so the snapshot is rewritten
/// whenever any of them changes: the switched-on Places (in shared
/// preferences), the named Places, the Outcomes on Next, the Place each
/// Outcome carries, the Habits with their days, and today.
final arrivalSnapshotReconcilerProvider = Provider<void>((ref) {
  if (!arrivalNotificationsSupported) return;

  final writer = ref.watch(arrivalSnapshotWriterProvider);
  if (writer == null) return;

  final switchedOn = ref.watch(arrivalPlaceIdsProvider);
  final named = ref.watch(namedPlacesProvider);
  final next = ref.watch(nextOutcomesProvider);
  final current = ref.watch(currentPlacesProvider);
  final habitHistories = ref.watch(habitHistoriesProvider);
  final habitToday = ref.watch(habitTodayProvider);

  // Until all five have answered, what is known is not what is true: an
  // empty fallback would read as "nothing is switched on" and the visit
  // record would be pruned away. The provider is rebuilt as each one lands.
  if (!switchedOn.hasValue ||
      !named.hasValue ||
      !next.hasValue ||
      !current.hasValue ||
      !habitHistories.hasValue) {
    return;
  }

  writer.reconcile(
    switchedOnPlaceIds: switchedOn.requireValue,
    namedPlaces: named.requireValue,
    nextOutcomes: next.requireValue,
    currentPlaces: current.requireValue,
    habitHistories: habitHistories.requireValue,
    today: parseHabitDay(habitToday)!,
  );
});

/// What is due at each of the switched-on Places.
///
/// A Place is in the snapshot when the user switched it on and it still
/// exists as a named Place. An Outcome is due at it when the Outcome is on
/// Next and its current Action carries that Place — the time of day and the
/// user's own whereabouts make no difference here, because the notification
/// is about being at the Place, not about the clock.
///
/// A one-time pin is never in the snapshot: it belongs to a single Action and
/// is never listed, so no Place id of the snapshot is ever a pin's.
///
/// A Habit is due at a Place when it carries that Place; the snapshot records
/// the days over the next [arrivalHabitHorizonDays] it is for, by the same rule
/// the Habit notification uses. [today] is a UTC calendar day.
ArrivalSnapshot buildArrivalSnapshot({
  required Set<String> switchedOnPlaceIds,
  required List<Place> namedPlaces,
  required List<Todo> nextOutcomes,
  required Map<String, ActionPlace> currentPlaces,
  required List<HabitHistory> habitHistories,
  required DateTime today,
}) {
  final places = <ArrivalPlace>[];
  for (final place in namedPlaces) {
    if (!switchedOnPlaceIds.contains(place.id)) continue;

    final titles = <String>[];
    for (final outcome in nextOutcomes) {
      final carried = currentPlaces[outcome.id];
      if (carried == null || carried.id != place.id) continue;
      titles.add(outcome.title);
    }

    final habits = <ArrivalHabit>[];
    for (final history in habitHistories) {
      if (history.habit.placeId != place.id) continue;
      final todayProgress = computeHabitProgress(history, today);
      final forDayKeys = <String>[];
      for (var offset = 0; offset < arrivalHabitHorizonDays; offset++) {
        final day = DateTime.utc(today.year, today.month, today.day + offset);
        if (isHabitForDay(history, todayProgress, day: day, today: today)) {
          forDayKeys.add(habitDayKey(day));
        }
      }
      if (forDayKeys.isEmpty) continue;
      habits.add((title: history.habit.title, forDayKeys: forDayKeys));
    }

    places.add((
      id: place.id,
      // A named Place always has a name; the column is nullable only because
      // a one-time pin may carry one of its own.
      name: place.name ?? '',
      latitudeMicrodegrees: place.latitudeMicrodegrees,
      longitudeMicrodegrees: place.longitudeMicrodegrees,
      radiusMeters: place.radiusMeters,
      dueCount: titles.length,
      dueTitles: titles.take(arrivalDueTitlesLimit).toList(growable: false),
      dueHabits: habits,
    ));
  }
  return (places: places);
}

class _ResumeObserver with WidgetsBindingObserver {
  _ResumeObserver(this._onResumed);

  final void Function() _onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResumed();
  }
}

/// Keeps the arrival snapshot on disk equal to what the app knows, and the
/// OS watching exactly the Places in it.
///
/// The writes are queued, so two changes that arrive together are written one
/// after the other and the file ends with the newer of them.
class ArrivalSnapshotWriter {
  ArrivalSnapshotWriter({
    required this.files,
    required this.registrar,
    required this.permission,
  });

  /// Where the two files are.
  final Future<ArrivalFiles> files;

  /// The OS's list of Places to watch.
  final GeofenceRegistrar registrar;

  /// The location permission as it stands now.
  final Future<LocationPermission> Function() permission;

  /// The snapshot most recently built, so the OS's list can be checked again
  /// without waiting for something to change. Null until the first one is
  /// built: an empty stand-in would make a resume remove every registered
  /// Place from the OS.
  ArrivalSnapshot? _latest;

  /// The snapshot as last written, so that an unchanged one is not written
  /// again.
  ArrivalSnapshot? _written;

  /// Where the files are, once they have been looked up. Null when they
  /// cannot be found — a phone that has no support directory has no arrival
  /// snapshot, and there is nothing to retry.
  Future<ArrivalFiles?>? _files;

  Future<void> _queue = Future.value();

  /// Writes the snapshot for what the app knows now, and prunes the visit
  /// record to the same Places.
  void reconcile({
    required Set<String> switchedOnPlaceIds,
    required List<Place> namedPlaces,
    required List<Todo> nextOutcomes,
    required Map<String, ActionPlace> currentPlaces,
    required List<HabitHistory> habitHistories,
    required DateTime today,
  }) {
    _enqueue(() => _write(
          switchedOnPlaceIds: switchedOnPlaceIds,
          namedPlaces: namedPlaces,
          nextOutcomes: nextOutcomes,
          currentPlaces: currentPlaces,
          habitHistories: habitHistories,
          today: today,
        ));
  }

  /// Checks the OS's list of Places against the latest snapshot again.
  void reconcileGeofencesAgain() {
    _enqueue(() async {
      final latest = _latest;
      if (latest == null) return;
      final arrivalFiles = await _resolveFiles();
      if (arrivalFiles == null) return;
      await _reconcileGeofences(arrivalFiles, latest);
    });
  }

  /// Completes once every write queued so far has finished.
  Future<void> settled() => _queue;

  void dispose() {}

  Future<void> _enqueue(Future<void> Function() job) {
    _queue = _queue.then((_) => job()).catchError((Object error, StackTrace stack) {
      debugPrint('Arrival snapshot write failed: $error\n$stack');
    });
    return _queue;
  }

  Future<void> _write({
    required Set<String> switchedOnPlaceIds,
    required List<Place> namedPlaces,
    required List<Todo> nextOutcomes,
    required Map<String, ActionPlace> currentPlaces,
    required List<HabitHistory> habitHistories,
    required DateTime today,
  }) async {
    final snapshot = buildArrivalSnapshot(
      switchedOnPlaceIds: switchedOnPlaceIds,
      namedPlaces: namedPlaces,
      nextOutcomes: nextOutcomes,
      currentPlaces: currentPlaces,
      habitHistories: habitHistories,
      today: today,
    );

    _latest = snapshot;

    final arrivalFiles = await _resolveFiles();
    if (arrivalFiles == null) return;

    final written = _written;
    if (written == null || !_sameSnapshot(written, snapshot)) {
      await arrivalFiles.writeSnapshot(snapshot);
      _written = snapshot;
    }

    await _pruneVisits(arrivalFiles, snapshot);
    await _reconcileGeofences(arrivalFiles, snapshot);
  }

  /// Makes the OS watch exactly the Places of [snapshot].
  Future<void> _reconcileGeofences(
    ArrivalFiles arrivalFiles,
    ArrivalSnapshot snapshot,
  ) async {
    final before = await arrivalFiles.readRegisteredAreas();
    final after = await reconcileGeofences(
      registrar: registrar,
      snapshot: snapshot,
      areas: before,
      permission: await permission(),
    );
    if (!_sameAreas(before, after)) await arrivalFiles.writeRegisteredAreas(after);
  }

  /// Where the files are, looked up once.
  ///
  /// A phone that cannot say where its support directory is has no arrival
  /// snapshot: the lookup is not retried, and the failure is said once.
  Future<ArrivalFiles?> _resolveFiles() {
    return _files ??= files.then<ArrivalFiles?>((arrivalFiles) {
      return arrivalFiles;
    }).catchError((Object error, StackTrace stack) {
      debugPrint('Arrival snapshot has nowhere to live: $error\n$stack');
      return null;
    });
  }

  /// Takes the Places out of the visit record that the snapshot no longer
  /// holds: the user switched them off, or the Place is gone.
  Future<void> _pruneVisits(
    ArrivalFiles arrivalFiles,
    ArrivalSnapshot snapshot,
  ) async {
    final visits = await arrivalFiles.readVisits();
    final watched = {for (final place in snapshot.places) place.id};
    final kept = <String, PlaceVisit>{
      for (final entry in visits.entries)
        if (watched.contains(entry.key)) entry.key: entry.value,
    };
    if (kept.length == visits.length) return;
    await arrivalFiles.writeVisits(kept);
  }
}

/// Whether two snapshots say the same thing.
bool _sameSnapshot(ArrivalSnapshot a, ArrivalSnapshot b) {
  if (a.places.length != b.places.length) return false;
  for (var index = 0; index < a.places.length; index++) {
    final first = a.places[index];
    final second = b.places[index];
    if (first.id != second.id) return false;
    if (first.name != second.name) return false;
    if (first.latitudeMicrodegrees != second.latitudeMicrodegrees) return false;
    if (first.longitudeMicrodegrees != second.longitudeMicrodegrees) return false;
    if (first.radiusMeters != second.radiusMeters) return false;
    if (first.dueCount != second.dueCount) return false;
    if (first.dueTitles.length != second.dueTitles.length) return false;
    for (var title = 0; title < first.dueTitles.length; title++) {
      if (first.dueTitles[title] != second.dueTitles[title]) return false;
    }
    if (first.dueHabits.length != second.dueHabits.length) return false;
    for (var habit = 0; habit < first.dueHabits.length; habit++) {
      final a = first.dueHabits[habit];
      final b = second.dueHabits[habit];
      if (a.title != b.title) return false;
      if (a.forDayKeys.length != b.forDayKeys.length) return false;
      for (var key = 0; key < a.forDayKeys.length; key++) {
        if (a.forDayKeys[key] != b.forDayKeys[key]) return false;
      }
    }
  }
  return true;
}

bool _sameAreas(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
