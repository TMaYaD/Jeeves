/// A Place's hours on Next (issue #1074), over a real in-memory store.
///
/// An Outcome whose current Action is at a named Place that carries hours is
/// off the Next List while those hours are closed, and comes back on its own
/// when the Place opens. The location does not matter: the Place's hours hide
/// the Outcome even while the user is standing at the Place. An Action with a
/// time of its own follows that time instead. Up Next is untouched: hiding is
/// on Next only.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/place_area.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/models/time_window_hours.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/providers/time_window_provider.dart';
import 'package:jeeves/services/location_source.dart';
import 'package:jeeves/services/notification_service.dart';

import '../helpers/fake_location_source.dart';
import '../test_helpers.dart';

const _userId = 'local';

/// The point of the Place named "Hardware store".
const GeoPoint _store = (
  latitudeDegrees: 52.3702,
  longitudeDegrees: 4.8952,
);

/// A point about 15 m from the store — inside its 150 m area.
const GeoPoint _insideStore = (
  latitudeDegrees: 52.3703,
  longitudeDegrees: 4.8953,
);

/// Monday to Friday, 11:00 to 20:00.
final _storeHours = <int, DayHours>{
  for (var day = 1; day <= 5; day++)
    day: (startMinute: 11 * 60, endMinute: 20 * 60),
};

/// Monday to Friday, 09:00 to 20:00.
final _earlyHours = <int, DayHours>{
  for (var day = 1; day <= 5; day++)
    day: (startMinute: 9 * 60, endMinute: 20 * 60),
};

/// Monday to Friday, 22:00 to 23:00.
final _eveningHours = <int, DayHours>{
  for (var day = 1; day <= 5; day++)
    day: (startMinute: 22 * 60, endMinute: 23 * 60),
};

/// Saturday, 09:00 to 12:00.
final _saturdayHours = <int, DayHours>{
  6: (startMinute: 9 * 60, endMinute: 12 * 60),
};

void main() {
  // The location provider watches the app lifecycle, which needs the binding.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late FakeLocationSource location;
  ProviderContainer? container;
  late DateTime Function() clock;

  void startContainer() {
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWith((ref) => () => clock()),
      locationSourceProvider.overrideWithValue(location),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    location = FakeLocationSource();
    // The user has allowed the location on this phone.
    location.permissionState = LocationPermission.whileInUse;
    // Wednesday 2026-01-14, 10:59 — a minute before the store opens.
    clock = () => DateTime(2026, 1, 14, 10, 59);
  });

  tearDown(() async {
    container?.dispose();
    container = null;
    await location.dispose();
    await db.close();
  });

  Future<T> eventually<T>(
    ProviderListenable<T> provider,
    bool Function(T) done,
  ) async {
    final sub = container!.listen(provider, (_, _) {});
    addTearDown(sub.close);
    for (var i = 0; i < 800; i++) {
      final value = sub.read();
      if (done(value)) return value;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return sub.read();
  }

  Future<Set<String>> nextIds(bool Function(Set<String>) done) async {
    final value = await eventually<AsyncValue<List<Todo>>>(
      nextProvider,
      (v) => v.hasValue && done({for (final t in v.value!) t.id}),
    );
    return {for (final t in value.value ?? const <Todo>[]) t.id};
  }

  /// An Outcome with a current Action, and the id of that Action.
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

  /// The Place named "Hardware store".
  Future<String> createStore() async {
    final id = await db.placeDao.createNamedPlace(
      name: 'Hardware store',
      latitudeDegrees: _store.latitudeDegrees,
      longitudeDegrees: _store.longitudeDegrees,
      radiusMeters: 150,
      userId: _userId,
    );
    expect(id, isNotNull);
    return id!;
  }

  Future<String> createWindow(String name, Map<int, DayHours> hours) async {
    final id = await db.timeWindowDao.createTimeWindow(
      name: name,
      hours: hours,
      userId: _userId,
    );
    expect(id, isNotNull);
    return id!;
  }

  /// Gives the Place [placeId] its hours: the window [windowId] gives it, or
  /// hours of its own.
  Future<void> setStoreHours(
    String placeId, {
    String? windowId,
    Map<int, DayHours>? hours,
    String? timeZone,
  }) async {
    await db.placeDao.setPlaceHours(
      placeId: placeId,
      timeWindowId: windowId,
      hours: hours == null ? null : TimeWindowHours.create(hours),
      timeZone: timeZone,
    );
  }

  test('a Place\'s hours hide the Outcome from Next, and the Place opening '
      'brings it back on its own', () async {
    final windowId = await createWindow('Store hours', _storeHours);
    final placeId = await createStore();
    await setStoreHours(placeId, windowId: windowId);
    final actionId = await insertOutcome('o1');
    await db.actionDao.setNamedPlace(actionId, placeId);
    await insertOutcome('plain');
    // The user is standing in the store: the Place's hours hide the Outcome
    // all the same.
    location.freshPoint = _insideStore;
    startContainer();

    expect(await nextIds((ids) => !ids.contains('o1')), {'plain'});

    // The clock moves to the opening. Nothing but the boundary tick is
    // rebuilt: the Outcome comes back because the Place opened.
    final stopwatch = Stopwatch()..start();
    clock = () => DateTime(2026, 1, 14, 10, 59, 59).add(stopwatch.elapsed);
    container!.invalidate(timeWindowBoundaryTickProvider);

    // A minute before the opening the Outcome is still hidden: nothing but
    // the clock moved.
    expect(await nextIds((ids) => !ids.contains('o1')), {'plain'});

    expect(await nextIds((ids) => ids.contains('o1')), {'o1', 'plain'});
  });

  test('a Place\'s hours hide the Outcome with no location at all', () async {
    final windowId = await createWindow('Store hours', _storeHours);
    final placeId = await createStore();
    await setStoreHours(placeId, windowId: windowId);
    final actionId = await insertOutcome('o1');
    await db.actionDao.setNamedPlace(actionId, placeId);
    await insertOutcome('plain');
    // The phone has never had a fix.
    location.freshPoint = null;
    location.lastKnownPoint = null;
    startContainer();

    expect(await nextIds((ids) => !ids.contains('o1')), {'plain'});
  });

  test('changing the Place\'s hours changes it for every Action at the Place',
      () async {
    final windowId = await createWindow('Store hours', _storeHours);
    final placeId = await createStore();
    await setStoreHours(placeId, windowId: windowId);
    final first = await insertOutcome('o1');
    final second = await insertOutcome('o2');
    await db.actionDao.setNamedPlace(first, placeId);
    await db.actionDao.setNamedPlace(second, placeId);
    await insertOutcome('plain');
    startContainer();

    expect(await nextIds((ids) => !ids.contains('o1')), {'plain'});

    // The window the Place uses opens earlier: every Action at the Place
    // follows it, and the read of the Place's hours re-emits.
    await db.timeWindowDao.updateTimeWindow(
      windowId: windowId,
      hours: _earlyHours,
    );

    expect(
      await nextIds((ids) => ids.contains('o1') && ids.contains('o2')),
      {'o1', 'o2', 'plain'},
    );

    // The Place carries hours of its own now, and they are read on the
    // phone's clock: an evening window closes them again.
    await setStoreHours(placeId, hours: _eveningHours);

    expect(
      await nextIds((ids) => !ids.contains('o1') && !ids.contains('o2')),
      {'plain'},
    );
  });

  test('a Place with no hours leaves its Outcome on Next', () async {
    final placeId = await createStore();
    final actionId = await insertOutcome('o1');
    await db.actionDao.setNamedPlace(actionId, placeId);
    startContainer();

    expect(await nextIds((ids) => ids.contains('o1')), {'o1'});
  });

  test('an Action with its own window follows it, not the Place\'s hours',
      () async {
    final placeId = await createStore();
    await setStoreHours(placeId, hours: _storeHours);
    final ownWindowId = await createWindow('Saturday', _saturdayHours);
    final actionId = await insertOutcome('o1');
    await db.actionDao.setNamedPlace(actionId, placeId);
    await db.actionDao.setTimeWindow(actionId, ownWindowId);
    await insertOutcome('plain');
    // Saturday 09:30 — the Place's hours are Monday to Friday, so they are
    // closed; the Action's own window is open.
    clock = () => DateTime(2026, 1, 17, 9, 30);
    startContainer();

    expect(await nextIds((ids) => ids.contains('o1')), {'o1', 'plain'});
  });

  test('an Action with a Time context follows it, not the Place\'s hours',
      () async {
    final placeId = await createStore();
    await setStoreHours(placeId, hours: _storeHours);
    final actionId = await insertOutcome('o1');
    await db.actionDao.setNamedPlace(actionId, placeId);
    await db.actionDao.setTimeContext(
      actionId,
      TimeContext.create(fromDate: DateTime(2020, 1, 1)),
    );
    await insertOutcome('plain');
    startContainer();

    expect(await nextIds((ids) => ids.contains('o1')), {'o1', 'plain'});
  });

  test('a one-time pin never carries hours', () async {
    final actionId = await insertOutcome('o1');
    final pinId = await db.actionDao.setPin(
      actionId,
      PlaceArea.create(
        latitudeDegrees: _store.latitudeDegrees,
        longitudeDegrees: _store.longitudeDegrees,
      )!,
    );
    expect(pinId, isNotNull);
    startContainer();

    expect(await nextIds((ids) => ids.contains('o1')), {'o1'});
  });

  test('a Place in another time zone opens on its own clock', () async {
    final placeId = await createStore();
    await setStoreHours(
      placeId,
      hours: _storeHours,
      timeZone: 'Europe/Berlin',
    );
    final actionId = await insertOutcome('o1');
    await db.actionDao.setNamedPlace(actionId, placeId);
    await insertOutcome('plain');
    // 09:59 UTC is 10:59 in Berlin: the store has not opened yet.
    clock = () => DateTime.utc(2026, 1, 14, 9, 59);
    startContainer();

    expect(await nextIds((ids) => !ids.contains('o1')), {'plain'});

    // The clock moves to the opening on the store's clock.
    final stopwatch = Stopwatch()..start();
    clock = () => DateTime.utc(2026, 1, 14, 9, 59, 59).add(stopwatch.elapsed);
    container!.invalidate(timeWindowBoundaryTickProvider);

    // A minute before the opening the Outcome is still hidden: nothing but
    // the clock moved.
    expect(await nextIds((ids) => !ids.contains('o1')), {'plain'});

    expect(await nextIds((ids) => ids.contains('o1')), {'o1', 'plain'});
  });

  test('the Outcome stays in Up Next while the Place is closed', () async {
    final windowId = await createWindow('Store hours', _storeHours);
    final placeId = await createStore();
    await setStoreHours(placeId, windowId: windowId);
    final actionId = await insertOutcome('o1');
    await db.actionDao.setNamedPlace(actionId, placeId);
    startContainer();

    final upNext = await eventually<AsyncValue<List<Todo>>>(
      nextForFocusSessionPlanningProvider,
      (v) => v.hasValue && v.value!.isNotEmpty,
    );
    expect(upNext.value!.map((t) => t.id), contains('o1'));
  });
}
