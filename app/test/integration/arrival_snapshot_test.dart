/// The arrival snapshot journey (issue #1092), over a real store and the
/// real providers.
///
/// The background arrival code may not open the store, so the foreground app
/// writes down what is due at each Place the user asked to hear about. This
/// journey proves that the snapshot says what it should: the Outcomes due at
/// a switched-on Place, and nothing else.
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/daos/habit_dao.dart' show HabitCommitmentDraft;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart' show HabitRepeatKind;
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/models/place_area.dart';
import 'package:jeeves/providers/arrival_notification_settings.dart';
import 'package:jeeves/providers/arrival_snapshot_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/services/location_source.dart';
import 'package:jeeves/services/arrival_snapshot.dart';
import 'package:jeeves/services/arrival_visit_rule.dart';

import '../helpers/fake_geofence_registrar.dart';
import '../helpers/fake_location_source.dart';
import '../test_helpers.dart';

const _userId = 'local';

/// The point of the Place named "Hardware store".
const double _storeLatitude = 52.3702;
const double _storeLongitude = 4.8952;

/// The point of the Place named "Corner shop".
const double _shopLatitude = 52.3710;
const double _shopLongitude = 4.8960;

/// The point of the one-time pin.
const double _pinLatitude = 52.3720;
const double _pinLongitude = 4.8970;

/// Saturday 28 November 2026, midday: the day every Habit test runs on, so
/// nothing here depends on the day the suite runs.
final DateTime _clockNow = DateTime(2026, 11, 28, 12);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late Directory directory;
  late ArrivalFiles files;
  late ProviderContainer container;
  late FakeGeofenceRegistrar registrar;
  late FakeLocationSource location;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    directory = Directory.systemTemp.createTempSync('jeeves-arrival-snapshot');
    files = ArrivalFiles(directory);
    registrar = FakeGeofenceRegistrar();
    location = FakeLocationSource()
      ..permissionState = LocationPermission.always;
    container = ProviderContainer(overrides: [
      geofenceRegistrarProvider.overrideWithValue(registrar),
      locationSourceProvider.overrideWithValue(location),
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => _clockNow),
      arrivalFilesProvider.overrideWith((ref) async => files),
    ]);
    addTearDown(container.dispose);
    // Nothing else reads the reconciler, so without this it would never run —
    // the same watch `main.dart` makes.
    container.listen(arrivalSnapshotReconcilerProvider, (_, _) {});
  });

  tearDown(() async {
    await db.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  /// Creates a named Place and returns its id.
  Future<String> createPlace(String name, double latitude, double longitude) async {
    final id = await db.placeDao.createNamedPlace(
      name: name,
      latitudeDegrees: latitude,
      longitudeDegrees: longitude,
      radiusMeters: 150,
      userId: _userId,
    );
    return id!;
  }

  /// Creates an Outcome with a current Action, and returns the Action's id.
  Future<String> createOutcome(String id, String title) async {
    final now = DateTime.now();
    await db.into(db.todos).insert(TodosCompanion(
          id: Value(id),
          title: Value(title),
          intent: const Value('next'),
          userId: const Value(_userId),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
    await seedCurrentAction(db, outcomeId: id, text: 'work on $title', userId: _userId);
    return (await db.actionDao.getCurrentAction(id))!.id;
  }

  /// Puts the Outcome at a named Place.
  Future<void> putAtPlace(String outcomeId, String placeId) async {
    final actionId = (await db.actionDao.getCurrentAction(outcomeId))!.id;
    await db.actionDao.setNamedPlace(actionId, placeId);
  }

  /// Puts the Outcome at a one-time pin of its own.
  Future<void> putAtPin(String outcomeId) async {
    final actionId = (await db.actionDao.getCurrentAction(outcomeId))!.id;
    await db.actionDao.setPin(
      actionId,
      PlaceArea.create(
        latitudeDegrees: _pinLatitude,
        longitudeDegrees: _pinLongitude,
      )!,
    );
  }

  /// Gives the Outcome a time window that closed earlier today.
  Future<void> closeItsTimeWindow(String outcomeId) async {
    final windowId = await db.timeWindowDao.createTimeWindow(
      name: 'Early',
      // One minute after midnight, on every day: closed by the time the test
      // runs, whatever hour it is.
      hours: {
        for (var day = 1; day <= 7; day++)
          day: (startMinute: 1, endMinute: 2),
      },
      userId: _userId,
    );
    final actionId = (await db.actionDao.getCurrentAction(outcomeId))!.id;
    await db.actionDao.setTimeWindow(actionId, windowId);
  }

  /// Waits for the snapshot on disk to say what the test waits for.
  Future<ArrivalSnapshot> waitForSnapshot(
    bool Function(ArrivalSnapshot snapshot) done,
  ) async {
    ArrivalSnapshot last = emptyArrivalSnapshot;
    for (var attempt = 0; attempt < 800; attempt++) {
      last = await files.readSnapshot();
      if (done(last)) return last;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final raw = files.snapshotFile.existsSync()
        ? files.snapshotFile.readAsStringSync()
        : '(no file)';
    fail('the arrival snapshot never held what the test waited for.\n'
        'file: $raw');
  }

  /// Waits for the visit record on disk to say what the test waits for.
  Future<Map<String, PlaceVisit>> waitForVisits(
    bool Function(Map<String, PlaceVisit> visits) done,
  ) async {
    for (var attempt = 0; attempt < 800; attempt++) {
      final visits = await files.readVisits();
      if (done(visits)) return visits;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('the visit record never held what the test waited for');
  }

  /// The Place with [id] in the snapshot, or null.
  ArrivalPlace? placeIn(ArrivalSnapshot snapshot, String id) {
    for (final place in snapshot.places) {
      if (place.id == id) return place;
    }
    return null;
  }

  test('the snapshot holds what is due at a switched-on Place, and nothing '
      'else', () async {
    final storeId = await createPlace('Hardware store', _storeLatitude, _storeLongitude);
    final shopId = await createPlace('Corner shop', _shopLatitude, _shopLongitude);

    // Two Outcomes at the hardware store: one plainly due, and one whose time
    // window closed earlier today. The time of day makes no difference to the
    // arrival notification — the user is at the Place, and the Outcome is
    // there.
    await createOutcome('o-screws', 'Buy screws');
    await putAtPlace('o-screws', storeId);
    await createOutcome('o-drill', 'Return the drill');
    await putAtPlace('o-drill', storeId);
    await closeItsTimeWindow('o-drill');

    // An Outcome at a one-time pin: a pin belongs to a single Action and is
    // never listed, so it is never a Place to arrive at.
    await createOutcome('o-pin', 'Find the shed');
    await putAtPin('o-pin');

    // An Outcome at a Place the user did not switch on.
    await createOutcome('o-shop', 'Milk');
    await putAtPlace('o-shop', shopId);

    // The user asked to hear about the hardware store only.
    await container
        .read(arrivalPlaceIdsProvider.notifier)
        .turnOn(storeId);

    final snapshot = await waitForSnapshot(
      (snapshot) => (placeIn(snapshot, storeId)?.dueCount ?? 0) == 2,
    );

    final store = placeIn(snapshot, storeId)!;
    expect(store.name, 'Hardware store');
    expect(store.dueCount, 2);
    expect(store.dueTitles, contains('Buy screws'));
    expect(store.dueTitles, contains('Return the drill'));
    expect(store.latitudeMicrodegrees, 52370200);
    expect(store.longitudeMicrodegrees, 4895200);
    expect(store.radiusMeters, 150);

    // The Place with the switch off is not in the snapshot, and neither is
    // the pin: the snapshot holds the switched-on Place and nothing else.
    expect(placeIn(snapshot, shopId), isNull);
    expect(snapshot.places, hasLength(1));
  });

  test('finishing an Outcome takes it out of the snapshot', () async {
    final storeId = await createPlace('Hardware store', _storeLatitude, _storeLongitude);
    await createOutcome('o-screws', 'Buy screws');
    await putAtPlace('o-screws', storeId);
    await container
        .read(arrivalPlaceIdsProvider.notifier)
        .turnOn(storeId);

    await waitForSnapshot(
      (snapshot) => (placeIn(snapshot, storeId)?.dueCount ?? 0) == 1,
    );

    // The user finishes it.
    await db.todoDao.markDone('o-screws');

    final snapshot = await waitForSnapshot(
      (snapshot) => placeIn(snapshot, storeId)?.dueCount == 0,
    );
    expect(placeIn(snapshot, storeId)!.dueTitles, isEmpty);
  });

  test('switching a Place off takes it and its visit out', () async {
    final storeId = await createPlace('Hardware store', _storeLatitude, _storeLongitude);
    await createOutcome('o-screws', 'Buy screws');
    await putAtPlace('o-screws', storeId);
    await container
        .read(arrivalPlaceIdsProvider.notifier)
        .turnOn(storeId);

    await waitForSnapshot(
      (snapshot) => placeIn(snapshot, storeId) != null,
    );

    // The phone remembers a visit at that Place.
    await files.writeVisits({
      storeId: (
        inside: false,
        lastExitAtUtc: DateTime.utc(2026, 11, 26, 9, 30),
        notifiedThisVisit: true,
      ),
    });

    // The user switches the Place off.
    await container
        .read(arrivalPlaceIdsProvider.notifier)
        .turnOff(storeId);

    final snapshot = await waitForSnapshot(
      (snapshot) => placeIn(snapshot, storeId) == null,
    );
    expect(snapshot.places, isEmpty);

    // The visit at a Place Jeeves no longer watches is gone too.
    final visits = await waitForVisits((visits) => !visits.containsKey(storeId));
    expect(visits, isEmpty);
  });

  group('the Habits due at a Place', () {
    const everyDay = HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay);

    /// Creates a Habit and returns its id.
    Future<String> createHabit(
      String title, {
      HabitCommitmentDraft commitment = everyDay,
    }) =>
        db.habitDao.createHabit(
          userId: _userId,
          title: title,
          today: '2026-11-28',
          now: _clockNow,
          firstCommitment: commitment,
        );

    Future<void> switchOn(String placeId) =>
        container.read(arrivalPlaceIdsProvider.notifier).turnOn(placeId);

    test('an every-day Habit is in the snapshot with every day of the week',
        () async {
      final gymId = await createPlace('Gym', _storeLatitude, _storeLongitude);
      final habitId = await createHabit('Workout');
      await db.habitDao.setNamedPlace(habitId, gymId, now: _clockNow);
      await switchOn(gymId);

      final snapshot = await waitForSnapshot(
        (snapshot) => (placeIn(snapshot, gymId)?.dueHabits ?? []).isNotEmpty,
      );

      final gym = placeIn(snapshot, gymId)!;
      expect(gym.dueCount, 0);
      expect(gym.dueHabits.single.title, 'Workout');
      expect(gym.dueHabits.single.forDayKeys, [
        '2026-11-28',
        '2026-11-29',
        '2026-11-30',
        '2026-12-01',
        '2026-12-02',
        '2026-12-03',
        '2026-12-04',
      ]);
    });

    test('a Habit at a switched-off Place or at a pin is not in the snapshot',
        () async {
      final gymId = await createPlace('Gym', _storeLatitude, _storeLongitude);
      final shopId = await createPlace('Corner shop', _shopLatitude, _shopLongitude);
      final shopHabit = await createHabit('Buy bread');
      await db.habitDao.setNamedPlace(shopHabit, shopId, now: _clockNow);
      final pinHabit = await createHabit('Stretch');
      await db.habitDao.setPin(
        pinHabit,
        PlaceArea.create(
            latitudeDegrees: _pinLatitude, longitudeDegrees: _pinLongitude)!,
        now: _clockNow,
      );
      await switchOn(gymId);

      final snapshot = await waitForSnapshot((s) => placeIn(s, gymId) != null);
      await container.read(arrivalSnapshotWriterProvider)!.settled();

      expect(snapshot.places, hasLength(1));
      expect(placeIn(snapshot, gymId)!.dueHabits, isEmpty);
    });

    test('a Habit on chosen weekdays has only those days', () async {
      final gymId = await createPlace('Gym', _storeLatitude, _storeLongitude);
      // Monday and Wednesday.
      final habitId = await createHabit(
        'Swim',
        commitment: const HabitCommitmentDraft(
          repeatKind: HabitRepeatKind.chosenWeekdays,
          chosenWeekdays: [1, 3],
        ),
      );
      await db.habitDao.setNamedPlace(habitId, gymId, now: _clockNow);
      await switchOn(gymId);

      final snapshot = await waitForSnapshot(
        (snapshot) => (placeIn(snapshot, gymId)?.dueHabits ?? []).isNotEmpty,
      );

      expect(placeIn(snapshot, gymId)!.dueHabits.single.forDayKeys,
          ['2026-11-30', '2026-12-02']);
    });

    test('a Check-in today takes today out, and the file is rewritten',
        () async {
      final gymId = await createPlace('Gym', _storeLatitude, _storeLongitude);
      final habitId = await createHabit('Workout');
      await db.habitDao.setNamedPlace(habitId, gymId, now: _clockNow);
      await switchOn(gymId);
      await waitForSnapshot((s) =>
          placeIn(s, gymId)?.dueHabits.singleOrNull?.forDayKeys.first ==
          '2026-11-28');

      await db.habitDao.addCheckIn(
        habitId: habitId,
        userId: _userId,
        countsForDay: '2026-11-28',
        now: _clockNow,
      );

      final snapshot = await waitForSnapshot((s) =>
          placeIn(s, gymId)?.dueHabits.singleOrNull?.forDayKeys.first ==
          '2026-11-29');
      expect(
          placeIn(snapshot, gymId)!.dueHabits.single.forDayKeys, hasLength(6));
    });

    test('a pause leaves no day key in the paused days, and a Habit paused '
        'for the whole horizon is not in the snapshot', () async {
      final gymId = await createPlace('Gym', _storeLatitude, _storeLongitude);
      final pausedBriefly = await createHabit('Workout');
      await db.habitDao.setNamedPlace(pausedBriefly, gymId, now: _clockNow);
      await db.habitDao.pause(
        habitId: pausedBriefly,
        userId: _userId,
        today: '2026-11-29',
        now: _clockNow,
        resumesOn: '2026-12-02',
      );
      final pausedAlways = await createHabit('Swim');
      await db.habitDao.setNamedPlace(pausedAlways, gymId, now: _clockNow);
      await db.habitDao.pause(
        habitId: pausedAlways,
        userId: _userId,
        today: '2026-11-28',
        now: _clockNow,
      );
      await switchOn(gymId);

      final snapshot = await waitForSnapshot(
        (snapshot) => (placeIn(snapshot, gymId)?.dueHabits ?? []).isNotEmpty,
      );

      final habits = placeIn(snapshot, gymId)!.dueHabits;
      expect(habits, hasLength(1));
      expect(habits.single.title, 'Workout');
      expect(habits.single.forDayKeys, [
        '2026-11-28',
        '2026-12-02',
        '2026-12-03',
        '2026-12-04',
      ]);
    });
  });

  /// Waits until [done] holds, or fails with [what].
  Future<void> waitUntil(bool Function() done, String what) async {
    for (var attempt = 0; attempt < 800; attempt++) {
      if (done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('never happened: $what');
  }

  group('the OS watches exactly the switched-on Places', () {
    test('switching on registers the Place once, with its radius', () async {
      final homeId = await createPlace('Home', _storeLatitude, _storeLongitude);
      await container.read(arrivalPlaceIdsProvider.notifier).turnOn(homeId);

      await waitUntil(() => registrar.watched.containsKey(homeId), 'registered');
      await waitForSnapshot((s) => placeIn(s, homeId) != null);
      expect(registrar.registrations, hasLength(1));
      expect(registrar.registrations.single.radiusMeters, 150);
    });

    test('editing the area removes the Place and registers it again',
        () async {
      final homeId = await createPlace('Home', _storeLatitude, _storeLongitude);
      await container.read(arrivalPlaceIdsProvider.notifier).turnOn(homeId);
      await waitUntil(() => registrar.registrations.length == 1, 'first');

      await db.placeDao.updateNamedPlace(placeId: homeId, radiusMeters: 400);

      await waitUntil(() => registrar.registrations.length == 2, 'second');
      expect(registrar.removals, [homeId]);
      expect(registrar.watched[homeId]!.radiusMeters, 400);
    });

    test('an unrelated change does not register the Place again', () async {
      final homeId = await createPlace('Home', _storeLatitude, _storeLongitude);
      await container.read(arrivalPlaceIdsProvider.notifier).turnOn(homeId);
      await waitUntil(() => registrar.registrations.length == 1, 'first');

      await createOutcome('o-a', 'Water the plants');
      await putAtPlace('o-a', homeId);
      await waitForSnapshot((s) => placeIn(s, homeId)?.dueCount == 1);

      expect(registrar.registrations, hasLength(1));
      expect(registrar.removals, isEmpty);
    });

    test('switching off removes the Place', () async {
      final homeId = await createPlace('Home', _storeLatitude, _storeLongitude);
      await container.read(arrivalPlaceIdsProvider.notifier).turnOn(homeId);
      await waitUntil(() => registrar.watched.containsKey(homeId), 'registered');

      await container.read(arrivalPlaceIdsProvider.notifier).turnOff(homeId);

      await waitUntil(() => registrar.watched.isEmpty, 'removed');
    });

    test('deleting the Place removes it', () async {
      final homeId = await createPlace('Home', _storeLatitude, _storeLongitude);
      await container.read(arrivalPlaceIdsProvider.notifier).turnOn(homeId);
      await waitUntil(() => registrar.watched.containsKey(homeId), 'registered');

      await db.placeDao.deletePlace(homeId);

      await waitUntil(() => registrar.watched.isEmpty, 'removed');
    });

    test('with location only while using, nothing is registered', () async {
      location.permissionState = LocationPermission.whileInUse;
      final homeId = await createPlace('Home', _storeLatitude, _storeLongitude);
      await container.read(arrivalPlaceIdsProvider.notifier).turnOn(homeId);

      await waitForSnapshot((s) => placeIn(s, homeId) != null);
      await container.read(arrivalSnapshotWriterProvider)!.settled();

      expect(registrar.registrations, isEmpty);
    });

    test('coming back to the app registers a Place the OS lost', () async {
      final homeId = await createPlace('Home', _storeLatitude, _storeLongitude);
      await container.read(arrivalPlaceIdsProvider.notifier).turnOn(homeId);
      await waitUntil(() => registrar.registrations.length == 1, 'first');

      // The OS forgets the geofence while Jeeves is away.
      registrar.watched.clear();
      TestWidgetsFlutterBinding.instance
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await waitUntil(() => registrar.watched.containsKey(homeId), 'again');
      expect(registrar.registrations, hasLength(2));
    });

    test('a refused registration is tried again on the next run', () async {
      registrar.registerError = StateError('permission missing');
      final homeId = await createPlace('Home', _storeLatitude, _storeLongitude);
      await container.read(arrivalPlaceIdsProvider.notifier).turnOn(homeId);
      await waitForSnapshot((s) => placeIn(s, homeId) != null);
      await container.read(arrivalSnapshotWriterProvider)!.settled();
      expect(registrar.watched, isEmpty);

      registrar.registerError = null;
      TestWidgetsFlutterBinding.instance
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await waitUntil(() => registrar.watched.containsKey(homeId), 'retried');
    });
  });
}
