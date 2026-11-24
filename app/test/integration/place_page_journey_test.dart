/// The place page journey (issue #55), over a real in-memory store.
///
/// Every Outcome with a Place is listed, grouped by Place and then by the
/// pins, and each row says whether it is on Next or elsewhere.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/place_area.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/providers/place_page_provider.dart';
import 'package:jeeves/services/location_source.dart';
import 'package:jeeves/services/notification_service.dart';

import '../helpers/fake_location_source.dart';
import '../test_helpers.dart';

const _userId = 'local';

/// The point of the Place named "Home".
const GeoPoint _home = (
  latitudeDegrees: 52.3702,
  longitudeDegrees: 4.8952,
);

/// A point about 40 km away — nowhere near Home.
const GeoPoint _elsewhere = (
  latitudeDegrees: 52.0800,
  longitudeDegrees: 4.3000,
);

Future<String> _insertOutcome(GtdDatabase db, String id) async {
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

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late FakeLocationSource location;
  late ProviderContainer container;

  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    location = FakeLocationSource();
  });

  tearDown(() async {
    container.dispose();
    await location.dispose();
    await db.close();
  });

  Future<List<PlacePageGroup>> groups({
    bool Function(List<PlacePageGroup>)? ready,
  }) async {
    final sub = container.listen(placePageGroupsProvider, (_, _) {});
    addTearDown(sub.close);
    for (var i = 0; i < 800; i++) {
      final value = sub.read();
      if (value.hasValue &&
          value.value!.isNotEmpty &&
          (ready == null || ready(value.value!))) {
        return value.value!;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return sub.read().value ?? const [];
  }

  test('an Outcome hidden by a Place is listed, and says where it stands',
      () async {
    // Two Outcomes: one at "Home", one at the office.
    final homeAction = await _insertOutcome(db, 'home-outcome');
    final officeAction = await _insertOutcome(db, 'office-outcome');
    final homeId = await db.placeDao.createNamedPlace(
      name: 'Home',
      latitudeDegrees: _home.latitudeDegrees,
      longitudeDegrees: _home.longitudeDegrees,
      radiusMeters: 150,
      userId: _userId,
    );
    final officeId = await db.placeDao.createNamedPlace(
      name: 'Office',
      latitudeDegrees: _elsewhere.latitudeDegrees,
      longitudeDegrees: _elsewhere.longitudeDegrees,
      radiusMeters: 150,
      userId: _userId,
    );
    await db.actionDao.setNamedPlace(homeAction, homeId);
    await db.actionDao.setNamedPlace(officeAction, officeId);
    // The user is at the office.
    location.freshPoint = _elsewhere;

    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      locationSourceProvider.overrideWithValue(location),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);

    final listed = await groups();
    // One group per named Place, in name order.
    expect(listed.map((g) => g.label), ['Home', 'Office']);
    final home = listed.first.rows.single;
    expect(home.todo.id, 'home-outcome');
    expect(home.isOnNext, isFalse, reason: 'the user is not at Home');
    final office = listed.last.rows.single;
    expect(office.todo.id, 'office-outcome');
    expect(office.isOnNext, isTrue, reason: 'the user is at the Office');
  });

  test('a pin comes after the named places', () async {
    final actionId = await _insertOutcome(db, 'pinned');
    final homeId = await db.placeDao.createNamedPlace(
      name: 'Home',
      latitudeDegrees: _home.latitudeDegrees,
      longitudeDegrees: _home.longitudeDegrees,
      radiusMeters: 150,
      userId: _userId,
    );
    await db.actionDao.setNamedPlace(actionId, homeId);
    final pinnedAction = await _insertOutcome(db, 'also-pinned');
    final area = PlaceArea.create(
      latitudeDegrees: 52.3000,
      longitudeDegrees: 4.8000,
      radiusMeters: 150,
    )!;
    await db.actionDao.setPin(pinnedAction, area, name: 'Post office');
    location.freshPoint = _home;

    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      locationSourceProvider.overrideWithValue(location),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);

    final listed = await groups();
    expect(listed.map((g) => g.label), ['Home', 'Pins']);
  });

  test('an Outcome at the Place but outside its time is not marked on Next',
      () async {
    final actionId = await _insertOutcome(db, 'timed');
    final homeId = await db.placeDao.createNamedPlace(
      name: 'Home',
      latitudeDegrees: _home.latitudeDegrees,
      longitudeDegrees: _home.longitudeDegrees,
      radiusMeters: 150,
      userId: _userId,
    );
    await db.actionDao.setNamedPlace(actionId, homeId);
    // The user is standing at Home.
    location.freshPoint = _home;
    // The Action's time context is a day that is not today.
    final today = DateTime.now().weekday;
    await db.actionDao.setTimeContext(
      actionId,
      TimeContext.create(days: {today == 7 ? 1 : 7})!,
    );

    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      locationSourceProvider.overrideWithValue(location),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);

    final listed = await groups(
      ready: (groups) =>
          groups.single.rows.isNotEmpty && !groups.single.rows.single.isOnNext,
    );
    final row = listed.single.rows.single;
    expect(row.todo.id, 'timed');
    // The user is at the Place, but the Outcome is not on Next: its time is
    // closed.
    expect(row.isOnNext, isFalse);
  });
}
