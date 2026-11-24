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
}
