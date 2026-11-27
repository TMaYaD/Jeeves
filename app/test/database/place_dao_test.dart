/// The Place DAO: create, edit, delete and watch (issue #239).
///
/// The rules under test: a named place is listed, a rename shows the new
/// name, a one-time pin is never listed, a delete detaches the place from
/// every Action that used it, and a write that the model cannot accept —
/// a radius out of range, a blank or over-long name — stores nothing.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/place_dao.dart' show pinPlaceKind;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/place_area.dart';
import 'package:jeeves/models/time_window_hours.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/domain_op_capture.dart';

import '../test_helpers.dart';

const _userId = 'test-user';
final _ts = DateTime.utc(2026, 11, 24, 9);

void main() {
  setUpAll(configureSqliteForTests);

  late RecordingDomainOpCapture capture;
  late GtdDatabase db;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    capture = RecordingDomainOpCapture();
    db = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
  });
  tearDown(() async => db.close());

  /// An Action pointing at [placeId], written straight into the column — the
  /// Action-side setters arrive with step 4.
  Future<void> seedAction(String actionId, {String? placeId}) async {
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
          placeId: Value(placeId),
          createdAt: Value(_ts),
        ));
  }

  Future<String?> placeIdOf(String actionId) async {
    final row = await (db.select(db.actions)
          ..where((a) => a.id.equals(actionId)))
        .getSingle();
    return row.placeId;
  }

  Future<String?> createHardwareStore({int? radiusMeters}) =>
      db.placeDao.createNamedPlace(
        name: 'Hardware store',
        latitudeDegrees: 52.3702,
        longitudeDegrees: 4.8952,
        radiusMeters: radiusMeters,
        userId: _userId,
        now: _ts,
      );

  test('a created place is listed by watchNamedPlaces', () async {
    final id = await createHardwareStore();

    final places = await db.placeDao.watchNamedPlaces().first;
    expect(places, hasLength(1));
    expect(places.first.id, id);
    expect(places.first.name, 'Hardware store');
    expect(places.first.kind, 'named');
    expect(places.first.latitudeMicrodegrees, 52370200);
    expect(places.first.longitudeMicrodegrees, 4895200);
    // No radius given: the place takes the default area.
    expect(places.first.radiusMeters, PlaceArea.defaultRadiusMeters);
  });

  test('a rename shows the new name', () async {
    final id = await createHardwareStore();
    capture.clear();

    final written =
        await db.placeDao.updateNamedPlace(placeId: id!, name: '  Bike shop  ');

    expect(written, isTrue);
    final places = await db.placeDao.watchNamedPlaces().first;
    expect(places.single.name, 'Bike shop');
    final op = capture.forCollection(placesCollection).single;
    expect(op.entityId, id);
    expect(op.fields['name'], 'Bike shop');
  });

  test('an unchanged point is not a change', () async {
    final id = await createHardwareStore();
    capture.clear();

    // The stored coordinates, handed back: the point did not move, so
    // nothing is written and no op is authored. A write here would also
    // quietly undo another device's move of the point, if it synced first.
    final written = await db.placeDao.updateNamedPlace(
      placeId: id!,
      latitudeDegrees: 52.3702,
      longitudeDegrees: 4.8952,
    );

    expect(written, isFalse);
    expect(capture.recorded, isEmpty);
  });

  test('a pin row never appears in watchNamedPlaces', () async {
    await db.into(db.places).insert(PlacesCompanion(
          id: const Value('pin-1'),
          userId: const Value(_userId),
          kind: const Value(pinPlaceKind),
          name: const Value('Dropped pin'),
          latitudeMicrodegrees: const Value(52370200),
          longitudeMicrodegrees: const Value(4895200),
          radiusMeters: const Value(150),
          createdAt: Value(_ts),
        ));

    expect(await db.placeDao.watchNamedPlaces().first, isEmpty);
  });

  test('delete removes the place and clears the reference on the two Actions '
      'that used it', () async {
    final id = await createHardwareStore();
    await seedAction('a1', placeId: id);
    await seedAction('a2', placeId: id);
    await seedAction('a3');
    capture.clear();

    await db.placeDao.deletePlace(id!, now: _ts);

    expect(await (db.select(db.places)..where((p) => p.id.equals(id))).get(),
        isEmpty);
    expect(await placeIdOf('a1'), isNull);
    expect(await placeIdOf('a2'), isNull);
    // An Action that never held the place is left alone.
    expect(await placeIdOf('a3'), isNull);

    // The place is tombstoned, and every Action it detached is asserted.
    final placeOps = capture.forCollection(placesCollection);
    expect(placeOps, hasLength(1));
    expect(placeOps.single.entityId, id);
    expect(placeOps.single.tombstone, isTrue);
    final actionOps = capture.forCollection(actionsCollection);
    expect(actionOps, hasLength(2));
    expect({for (final op in actionOps) op.entityId}, {'a1', 'a2'});
    for (final op in actionOps) {
      expect(op.fields.containsKey('place_id'), isTrue);
      expect(op.fields['place_id'], isNull);
    }
  });

  test('a delete detaches the Habit that used the place', () async {
    final id = await createHardwareStore();
    // A Habit pointing at the Place, written straight into the column — the
    // Habit-side setter has its own suite.
    await db.into(db.habits).insert(HabitsCompanion.insert(
          id: const Value('h1'),
          userId: _userId,
          title: 'Read a book',
          createdAt: '2026-11-24T09:00:00.000Z',
          placeId: Value(id),
        ));
    capture.clear();

    await db.placeDao.deletePlace(id!, now: _ts);

    final habit = await (db.select(db.habits)..where((h) => h.id.equals('h1')))
        .getSingle();
    expect(habit.placeId, isNull);
    // The Habit tables are device-local, so the detach authors no op: the
    // Place's tombstone is the only op there is.
    expect(capture.recorded, hasLength(1));
    expect(capture.forCollection(placesCollection).single.tombstone, isTrue);
  });

  test('an out-of-range radius and a blank or over-long name are refused and '
      'write nothing', () async {
    expect(await createHardwareStore(radiusMeters: 49), isNull);
    expect(await createHardwareStore(radiusMeters: 2001), isNull);
    expect(
      await db.placeDao.createNamedPlace(
        name: '   ',
        latitudeDegrees: 52.3702,
        longitudeDegrees: 4.8952,
        userId: _userId,
        now: _ts,
      ),
      isNull,
    );
    expect(
      await db.placeDao.createNamedPlace(
        name: 'x' * 101,
        latitudeDegrees: 52.3702,
        longitudeDegrees: 4.8952,
        userId: _userId,
        now: _ts,
      ),
      isNull,
    );

    expect(await db.select(db.places).get(), isEmpty);
    expect(capture.recorded, isEmpty);
  });

  test('an update that the model cannot accept writes nothing', () async {
    final id = await createHardwareStore();
    capture.clear();

    expect(
      await db.placeDao.updateNamedPlace(placeId: id!, radiusMeters: 49),
      isFalse,
    );
    expect(
      await db.placeDao.updateNamedPlace(placeId: id, name: ''),
      isFalse,
    );
    // Half a point is not a point.
    expect(
      await db.placeDao.updateNamedPlace(placeId: id, latitudeDegrees: 52.37),
      isFalse,
    );

    final place = await (db.select(db.places)..where((p) => p.id.equals(id)))
        .getSingle();
    expect(place.name, 'Hardware store');
    expect(place.radiusMeters, PlaceArea.defaultRadiusMeters);
    expect(capture.recorded, isEmpty);
  });

  test('a moved place and a widened area are written and asserted', () async {
    final id = await createHardwareStore();
    capture.clear();

    final written = await db.placeDao.updateNamedPlace(
      placeId: id!,
      latitudeDegrees: 52.1,
      longitudeDegrees: 4.1,
      radiusMeters: 300,
    );

    expect(written, isTrue);
    final place =
        await (db.select(db.places)..where((p) => p.id.equals(id))).getSingle();
    expect(place.latitudeMicrodegrees, 52100000);
    expect(place.longitudeMicrodegrees, 4100000);
    expect(place.radiusMeters, 300);
    final op = capture.forCollection(placesCollection).single;
    expect(op.fields['latitude_microdegrees'], 52100000);
    expect(op.fields['longitude_microdegrees'], 4100000);
    expect(op.fields['radius_meters'], 300);
  });

  test('the use count and the place gate read the same Action', () async {
    final id = await createHardwareStore();
    // An Outcome whose current Action points at the Place.
    await seedAction('a1', placeId: id);
    // A second, live Outcome with no Place at all.
    await db.into(db.todos).insert(TodosCompanion(
          id: const Value('todo-a2'),
          title: const Value('outcome a2'),
          userId: const Value(_userId),
          createdAt: Value(_ts),
          updatedAt: Value(_ts),
        ));
    await db.into(db.actions).insert(ActionsCompanion(
          id: const Value('a2'),
          outcomeId: const Value('todo-a2'),
          userId: const Value(_userId),
          actionText: const Value('action a2'),
          role: const Value('current'),
          createdAt: Value(_ts),
        ));

    final listed = await db.placeDao.watchNamedPlacesWithUseCount().first;
    expect(listed.single.useCount, 1);

    final current = await db.actionDao.watchCurrentPlaces().first;
    expect(current.keys, ['todo-a1']);
    expect(current['todo-a1']!.id, id);
  });

  test('a conflict leaves one current Action, and the count follows it',
      () async {
    final id = await createHardwareStore();
    final other = await db.placeDao.createNamedPlace(
      name: 'Bike shop',
      latitudeDegrees: 52.1,
      longitudeDegrees: 4.1,
      userId: _userId,
      now: _ts,
    );
    // Two current Actions for one Outcome, as a sync conflict can leave
    // behind: one points at the hardware store, one at the bike shop.
    await seedAction('a1', placeId: id);
    await db.into(db.actions).insert(ActionsCompanion(
          id: const Value('a2'),
          outcomeId: const Value('todo-a1'),
          userId: const Value(_userId),
          actionText: const Value('action a1 again'),
          role: const Value('current'),
          placeId: Value(other),
          // Written later, so it wins.
          createdAt: Value(_ts),
          updatedAt: Value(_ts.add(const Duration(minutes: 5))),
        ));

    // The gate reads the winner, which points at the bike shop.
    final current = await db.actionDao.watchCurrentPlaces().first;
    expect(current['todo-a1']!.id, other);

    // The count agrees with the gate: the hardware store is not used, and the
    // bike shop is used once.
    final listed = await db.placeDao.watchNamedPlacesWithUseCount().first;
    final byName = {for (final row in listed) row.name: row.useCount};
    expect(byName['Hardware store'], 0);
    expect(byName['Bike shop'], 1);
  });

  group('the hours a place carries (issue #1074)', () {
    /// Mon–Fri 11:00–20:00 — the hardware store's hours.
    final monToFri = <int, DayHours>{
      for (var day = 1; day <= 5; day++)
        day: (startMinute: 11 * 60, endMinute: 20 * 60),
    };

    Future<String> createWindow({String name = 'Weekday hours'}) async {
      final id = await db.timeWindowDao.createTimeWindow(
        name: name,
        hours: monToFri,
        userId: _userId,
        now: _ts,
      );
      return id!;
    }

    Future<Place> placeRow(String placeId) =>
        (db.select(db.places)..where((p) => p.id.equals(placeId))).getSingle();

    Future<String> seedPin() async {
      await db.into(db.places).insert(PlacesCompanion(
            id: const Value('pin-1'),
            userId: const Value(_userId),
            kind: const Value(pinPlaceKind),
            name: const Value('Dropped pin'),
            latitudeMicrodegrees: const Value(52370200),
            longitudeMicrodegrees: const Value(4895200),
            radiusMeters: const Value(150),
            createdAt: Value(_ts),
          ));
      return 'pin-1';
    }

    test('a window gives the place its hours and a zone', () async {
      final placeId = await createHardwareStore();
      final windowId = await createWindow();
      capture.clear();

      final written = await db.placeDao.setPlaceHours(
        placeId: placeId!,
        timeWindowId: windowId,
        timeZone: 'Europe/Berlin',
        now: _ts,
      );

      expect(written, isTrue);
      final place = await placeRow(placeId);
      expect(place.timeWindowId, windowId);
      expect(place.hours, isNull);
      expect(place.timeZone, 'Europe/Berlin');

      // One op, all three fields: a peer never sees a window and own hours
      // side by side.
      final op = capture.forCollection(placesCollection).single;
      expect(op.entityId, placeId);
      expect(op.fields.keys.toSet(),
          {'time_window_id', 'hours', 'time_zone', 'updated_at'});
      expect(op.fields['time_window_id'], windowId);
      expect(op.fields['hours'], isNull);
      expect(op.fields['time_zone'], 'Europe/Berlin');
      expect(op.fields['updated_at'], '2026-11-24T09:00:00.000Z');
    });

    test('hours of the place\'s own are written as the canonical JSON',
        () async {
      final placeId = await createHardwareStore();
      final hours = TimeWindowHours.create(monToFri)!;
      capture.clear();

      final written = await db.placeDao.setPlaceHours(
        placeId: placeId!,
        hours: hours,
        timeZone: 'Europe/Berlin',
        now: _ts,
      );

      expect(written, isTrue);
      final place = await placeRow(placeId);
      expect(place.timeWindowId, isNull);
      expect(place.hours, hours.encode());
      expect(place.timeZone, 'Europe/Berlin');

      final op = capture.forCollection(placesCollection).single;
      expect(op.fields['time_window_id'], isNull);
      expect(op.fields['hours'], hours.encode());
      expect(op.fields['time_zone'], 'Europe/Berlin');
    });

    test('a pin carries no hours', () async {
      final pinId = await seedPin();
      capture.clear();

      final written = await db.placeDao.setPlaceHours(
        placeId: pinId,
        hours: TimeWindowHours.create(monToFri),
        now: _ts,
      );

      expect(written, isFalse);
      final place = await placeRow(pinId);
      expect(place.hours, isNull);
      expect(place.timeZone, isNull);
      expect(capture.recorded, isEmpty);
    });

    test('both kinds of hours at once are refused', () async {
      final placeId = await createHardwareStore();
      final windowId = await createWindow();
      capture.clear();

      final written = await db.placeDao.setPlaceHours(
        placeId: placeId!,
        timeWindowId: windowId,
        hours: TimeWindowHours.create(monToFri),
        now: _ts,
      );

      expect(written, isFalse);
      final place = await placeRow(placeId);
      expect(place.timeWindowId, isNull);
      expect(place.hours, isNull);
      expect(capture.recorded, isEmpty);
    });

    test('a window id that names no window is refused', () async {
      final placeId = await createHardwareStore();
      capture.clear();

      final written = await db.placeDao.setPlaceHours(
        placeId: placeId!,
        timeWindowId: 'no-such-window',
        now: _ts,
      );

      expect(written, isFalse);
      final place = await placeRow(placeId);
      expect(place.timeWindowId, isNull);
      expect(capture.recorded, isEmpty);
    });

    test('a place that does not exist is refused', () async {
      final windowId = await createWindow();
      capture.clear();

      final written = await db.placeDao.setPlaceHours(
        placeId: 'no-such-place',
        timeWindowId: windowId,
        now: _ts,
      );

      expect(written, isFalse);
      expect(capture.recorded, isEmpty);
    });

    test('clearing writes nulls for all three fields', () async {
      final placeId = await createHardwareStore();
      final windowId = await createWindow();
      await db.placeDao.setPlaceHours(
        placeId: placeId!,
        timeWindowId: windowId,
        timeZone: 'Europe/Berlin',
        now: _ts,
      );
      capture.clear();

      final written = await db.placeDao.setPlaceHours(placeId: placeId, now: _ts);

      expect(written, isTrue);
      final place = await placeRow(placeId);
      expect(place.timeWindowId, isNull);
      expect(place.hours, isNull);
      expect(place.timeZone, isNull);

      final op = capture.forCollection(placesCollection).single;
      expect(op.fields['time_window_id'], isNull);
      expect(op.fields['hours'], isNull);
      expect(op.fields['time_zone'], isNull);
    });

    test('a write that changes nothing authors nothing', () async {
      final placeId = await createHardwareStore();
      final windowId = await createWindow();
      await db.placeDao.setPlaceHours(
        placeId: placeId!,
        timeWindowId: windowId,
        timeZone: 'Europe/Berlin',
        now: _ts,
      );
      capture.clear();

      final written = await db.placeDao.setPlaceHours(
        placeId: placeId,
        timeWindowId: windowId,
        timeZone: 'Europe/Berlin',
        now: _ts,
      );

      expect(written, isFalse);
      expect(capture.recorded, isEmpty);
    });

    test('a zone with no hours is not stored', () async {
      final placeId = await createHardwareStore();
      capture.clear();

      final written = await db.placeDao.setPlaceHours(
        placeId: placeId!,
        timeZone: 'Europe/Berlin',
        now: _ts,
      );

      expect(written, isFalse);
      final place = await placeRow(placeId);
      expect(place.timeZone, isNull);
      expect(capture.recorded, isEmpty);
    });
  });
}
