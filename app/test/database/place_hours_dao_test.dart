/// The hours a Place gives its Actions (issue #1074), over a real store.
///
/// The rules under test: the hours are keyed by Outcome id and carry the
/// Place they come from, a one-time pin never carries hours, the window a
/// Place names gives it its hours, hours the app cannot read are absent, and
/// editing the window the Place uses re-emits the read.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/place_area.dart';
import 'package:jeeves/models/time_window_hours.dart';

import '../test_helpers.dart';

const _userId = 'test-user';
final _ts = DateTime.utc(2026, 11, 24, 9);

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

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = GtdDatabase(NativeDatabase.memory());
  });
  tearDown(() async => db.close());

  /// An Outcome with a current Action.
  Future<String> seedOutcome(String actionId) async {
    await db.into(db.todos).insert(TodosCompanion(
          id: Value('todo-$actionId'),
          title: Value('outcome $actionId'),
          userId: const Value(_userId),
          createdAt: Value(_ts),
          updatedAt: Value(_ts),
        ));
    await db.into(db.actions).insert(ActionsCompanion(
          id: Value(actionId),
          outcomeId: Value('todo-$actionId'),
          userId: const Value(_userId),
          actionText: Value('action $actionId'),
          role: const Value('current'),
          createdAt: Value(_ts),
        ));
    return 'todo-$actionId';
  }

  Future<String> createPlace(String name) async {
    final id = await db.placeDao.createNamedPlace(
      name: name,
      latitudeDegrees: 52.37,
      longitudeDegrees: 4.89,
      radiusMeters: 150,
      userId: _userId,
      now: _ts,
    );
    expect(id, isNotNull);
    return id!;
  }

  Future<String> createWindow(String name) async {
    final id = await db.timeWindowDao.createTimeWindow(
      name: name,
      hours: _storeHours,
      userId: _userId,
      now: _ts,
    );
    expect(id, isNotNull);
    return id!;
  }

  test('the hours are keyed by Outcome id, with the Place they come from',
      () async {
    final placeId = await createPlace('Hardware store');
    final outcomeId = await seedOutcome('a1');
    await db.actionDao.setNamedPlace('a1', placeId);
    await db.placeDao.setPlaceHours(
      placeId: placeId,
      hours: TimeWindowHours.create(_storeHours),
      now: _ts,
    );

    final hours = await db.actionDao.watchCurrentPlaceHours().first;

    expect(hours.keys, {outcomeId});
    expect(hours[outcomeId]!.placeId, placeId);
    expect(hours[outcomeId]!.placeName, 'Hardware store');
    expect(hours[outcomeId]!.hours.hours.days, [1, 2, 3, 4, 5]);
    // No zone: the hours are read on the phone's clock.
    expect(hours[outcomeId]!.hours.location, isNull);
  });

  test('a Place with no hours is absent', () async {
    final placeId = await createPlace('Hardware store');
    await seedOutcome('a1');
    await db.actionDao.setNamedPlace('a1', placeId);

    final hours = await db.actionDao.watchCurrentPlaceHours().first;

    expect(hours, isEmpty);
  });

  test('a one-time pin never carries hours', () async {
    await seedOutcome('a1');
    final pinId = await db.actionDao.setPin(
      'a1',
      PlaceArea.create(latitudeDegrees: 52.37, longitudeDegrees: 4.89)!,
    );
    expect(pinId, isNotNull);
    // The row is made to claim hours the app never writes for a pin: the
    // read has to ignore a pin whatever its row says.
    await db.customStatement(
      "UPDATE places SET hours = '${TimeWindowHours.create(_storeHours)!.encode()}' "
      "WHERE id = '$pinId'",
    );

    final hours = await db.actionDao.watchCurrentPlaceHours().first;

    expect(hours, isEmpty);
  });

  test('the window a Place names gives it its hours', () async {
    final windowId = await createWindow('Store hours');
    final placeId = await createPlace('Hardware store');
    final outcomeId = await seedOutcome('a1');
    await db.actionDao.setNamedPlace('a1', placeId);
    await db.placeDao.setPlaceHours(
      placeId: placeId,
      timeWindowId: windowId,
      now: _ts,
    );

    final hours = await db.actionDao.watchCurrentPlaceHours().first;

    expect(hours.keys, {outcomeId});
    expect(hours[outcomeId]!.hours.timeWindowId, windowId);
    expect(hours[outcomeId]!.hours.timeWindowName, 'Store hours');
    expect(hours[outcomeId]!.hours.hours.days, [1, 2, 3, 4, 5]);
  });

  test('a window that is gone is absent', () async {
    final windowId = await createWindow('Store hours');
    final placeId = await createPlace('Hardware store');
    await seedOutcome('a1');
    await db.actionDao.setNamedPlace('a1', placeId);
    await db.placeDao.setPlaceHours(
      placeId: placeId,
      timeWindowId: windowId,
      now: _ts,
    );
    // The window row goes without the Place being told.
    await db.delete(db.timeWindows).go();

    final hours = await db.actionDao.watchCurrentPlaceHours().first;

    expect(hours, isEmpty);
  });

  test('hours the app cannot read are absent', () async {
    final placeId = await createPlace('Hardware store');
    await seedOutcome('a1');
    await db.actionDao.setNamedPlace('a1', placeId);
    await db.customStatement(
      "UPDATE places SET hours = 'not json' WHERE id = '$placeId'",
    );

    final hours = await db.actionDao.watchCurrentPlaceHours().first;

    expect(hours, isEmpty);
  });

  test('a zone the tz database does not know is absent', () async {
    final placeId = await createPlace('Hardware store');
    await seedOutcome('a1');
    await db.actionDao.setNamedPlace('a1', placeId);
    await db.placeDao.setPlaceHours(
      placeId: placeId,
      hours: TimeWindowHours.create(_storeHours),
      timeZone: 'Mars/Olympus',
      now: _ts,
    );

    final hours = await db.actionDao.watchCurrentPlaceHours().first;

    expect(hours, isEmpty);
  });

  test('a known zone is read on that clock', () async {
    final placeId = await createPlace('Hardware store');
    final outcomeId = await seedOutcome('a1');
    await db.actionDao.setNamedPlace('a1', placeId);
    await db.placeDao.setPlaceHours(
      placeId: placeId,
      hours: TimeWindowHours.create(_storeHours),
      timeZone: 'Europe/Berlin',
      now: _ts,
    );

    final hours = await db.actionDao.watchCurrentPlaceHours().first;

    expect(hours.keys, {outcomeId});
    expect(hours[outcomeId]!.hours.location, isNotNull);
    expect(hours[outcomeId]!.hours.location!.name, 'Europe/Berlin');
  });

  test('editing the window the Place uses re-emits the read', () async {
    final windowId = await createWindow('Store hours');
    final placeId = await createPlace('Hardware store');
    await seedOutcome('a1');
    await db.actionDao.setNamedPlace('a1', placeId);
    await db.placeDao.setPlaceHours(
      placeId: placeId,
      timeWindowId: windowId,
      now: _ts,
    );

    final emissions = <List<int>>[];
    final sub = db.actionDao.watchCurrentPlaceHours().listen((hours) {
      emissions.add([
        for (final h in hours.values) h.hours.hours.hoursForDay(1)!.startMinute,
      ]);
    });
    addTearDown(sub.cancel);
    await pumpEventQueue();

    await db.timeWindowDao.updateTimeWindow(
      windowId: windowId,
      hours: _earlyHours,
    );
    await pumpEventQueue();

    // The Place follows the window, so the hours it carries changed.
    expect(emissions.last, [9 * 60]);
  });
}
