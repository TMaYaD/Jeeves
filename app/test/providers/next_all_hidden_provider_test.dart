/// When everything on Next is hidden (issue #1076), over a real in-memory
/// store.
///
/// The Next list is empty because time or place hides every Outcome on it —
/// which is a different thing from the Next list having no Outcomes at all,
/// and the empty state has to tell the two apart.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/action_place_and_time_window.dart';
import 'package:jeeves/models/time_window_hours.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/current_location_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/place_gate_provider.dart';
import 'package:jeeves/providers/tag_filter_provider.dart';
import 'package:jeeves/providers/time_window_provider.dart';
import 'package:jeeves/services/notification_service.dart';

import '../helpers/fake_location_source.dart';
import '../test_helpers.dart';

const _userId = 'local';

/// Monday to Friday, 09:00 to 17:00.
final _workHours = <int, DayHours>{
  for (var day = 1; day <= 5; day++)
    day: (startMinute: 9 * 60, endMinute: 17 * 60),
};

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;
  late DateTime Function() clock;
  var started = false;

  /// Starts a container over [db], with the clock and the location stood in
  /// for. The location is unknown unless a test says otherwise: with no
  /// location nothing is hidden by place.
  void startContainer({CurrentLocation location = const LocationUnknown()}) {
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWith((ref) => () => clock()),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
      currentLocationProvider.overrideWith(() => FixedLocationNotifier(location)),
    ]);
    started = true;
  }

  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    // 2026-11-11 is a Wednesday; 17:00 is just after the window has closed.
    clock = () => DateTime(2026, 11, 11, 17, 0);
    started = false;
  });

  tearDown(() async {
    if (started) container.dispose();
    await db.close();
  });

  /// Waits for [provider] to answer [done], then returns what it answered.
  Future<T> eventually<T>(
    ProviderListenable<T> provider,
    bool Function(T) done,
  ) async {
    final sub = container.listen(provider, (_, _) {});
    addTearDown(sub.close);
    for (var i = 0; i < 800; i++) {
      final value = sub.read();
      if (done(value)) return value;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return sub.read();
  }

  /// Waits until the store's feeds have delivered, so the providers under
  /// test have read real rows rather than their empty start.
  ///
  /// Without this the answer would be read before the windows and the places
  /// have arrived, and the set of hidden Outcomes would still be empty.
  Future<void> settle() async {
    await eventually<AsyncValue<List<Todo>>>(
        nextBeforeHidingProvider, (v) => v.hasValue);
    await eventually<AsyncValue<Map<String, ActionTimeWindow>>>(
        currentTimeWindowsProvider, (v) => v.hasValue);
    await eventually<AsyncValue<Map<String, ActionPlace>>>(
        currentPlacesProvider, (v) => v.hasValue);
    await container.pump();
  }

  /// Seeds an Outcome with a current Action, and returns the Action's id.
  Future<String> insertOutcome(String id) async {
    final now = DateTime.now();
    await db.into(db.todos).insert(TodosCompanion(
          id: Value(id),
          title: Value('Outcome $id'),
          intent: const Value('next'),
          userId: const Value(_userId),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
    await seedCurrentAction(db,
        outcomeId: id, text: 'work on $id', userId: _userId);
    return (await db.actionDao.getCurrentAction(id))!.id;
  }

  /// Seeds an Outcome whose current Action is in a closed named window.
  Future<void> insertWindowedOutcome(String id, String windowId) async {
    final actionId = await insertOutcome(id);
    await db.actionDao.setTimeWindow(actionId, windowId);
  }

  /// Seeds a named time window.
  Future<String> createWindow(String name) async {
    final id = await db.timeWindowDao.createTimeWindow(
      name: name,
      hours: _workHours,
      userId: _userId,
    );
    expect(id, isNotNull);
    return id!;
  }

  test('with no Outcomes on Next, nothing is hidden', () async {
    startContainer();
    await settle();

    expect(container.read(nextAllHiddenProvider), isFalse);
  });

  test('with every Outcome on Next hidden, everything is hidden', () async {
    final windowId = await createWindow('Work hours');
    await insertWindowedOutcome('o1', windowId);
    await insertWindowedOutcome('o2', windowId);
    await insertWindowedOutcome('o3', windowId);
    startContainer();
    await settle();

    expect(container.read(nextAllHiddenProvider), isTrue);
  });

  test('with one Outcome on Next still showing, not everything is hidden',
      () async {
    final windowId = await createWindow('Work hours');
    await insertWindowedOutcome('o1', windowId);
    await insertOutcome('plain');
    startContainer();
    await settle();

    expect(container.read(nextAllHiddenProvider), isFalse);
  });

  test('an Outcome the user is away from is hidden by place too', () async {
    final windowId = await createWindow('Work hours');
    await insertWindowedOutcome('o1', windowId);
    final actionId = await insertOutcome('o2');
    final placeId = await db.placeDao.createNamedPlace(
      name: 'Home',
      latitudeDegrees: 52.3702,
      longitudeDegrees: 4.8952,
      radiusMeters: 150,
      userId: _userId,
    );
    await db.actionDao.setNamedPlace(actionId, placeId!);
    // The user is a long way from the Place.
    startContainer(
        location: const LocationKnown((
          latitudeDegrees: 0,
          longitudeDegrees: 0,
        )));
    await settle();

    expect(container.read(nextAllHiddenProvider), isTrue);
  });

  test('a Label filter that matches nothing keeps the ordinary empty state',
      () async {
    final windowId = await createWindow('Work hours');
    await insertWindowedOutcome('o1', windowId);
    await insertWindowedOutcome('o2', windowId);
    startContainer();
    await settle();
    expect(container.read(nextAllHiddenProvider), isTrue);

    // The user filters Next by a Label no Outcome carries: they are
    // filtering, not waiting.
    container.read(tagFilterProvider.notifier).toggle('label-none-carry');
    await eventually<AsyncValue<List<Todo>>>(
        nextBeforeHidingProvider, (v) => v.hasValue && v.value!.isEmpty);

    expect(container.read(nextAllHiddenProvider), isFalse);
  });
}
