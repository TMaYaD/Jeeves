/// The place page journey (issue #1090), over a real in-memory store.
///
/// Every Outcome with a Place is listed, and the Places that are near each
/// other are drawn together, so the user sees at a glance which errands one
/// trip covers. Each row says whether it is on Next or elsewhere.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/place_area.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/providers/place_page_provider.dart';
import 'package:jeeves/screens/place_page/place_page_screen.dart';
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

/// A point about 300 m north of Home — near it.
const GeoPoint _near = (
  latitudeDegrees: 52.3729,
  longitudeDegrees: 4.8952,
);

/// A point about 200 m north of Home — near it.
const GeoPoint _veryNear = (
  latitudeDegrees: 52.3720,
  longitudeDegrees: 4.8952,
);

/// A point about 50 km away — nowhere near Home.
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

/// The labels of every Place on the page, in the order they are drawn.
List<String> _labels(List<PlacePageGroup> groups) => [
      for (final group in groups)
        for (final place in group.places)
          place.label,
    ];

/// Let the real work happen: the place page is a live Drift watch, so the
/// frames are pumped one at a time, never through `pumpAndSettle`.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late FakeLocationSource location;
  ProviderContainer? container;

  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    location = FakeLocationSource();
  });

  tearDown(() async {
    container?.dispose();
    await location.dispose();
    await db.close();
  });

  Future<List<PlacePageGroup>> groups({
    bool Function(List<PlacePageGroup>)? ready,
  }) async {
    final sub = container!.listen(placePageGroupsProvider, (_, _) {});
    addTearDown(sub.close);
    for (var i = 0; i < 800; i++) {
      final value = sub.read();
      // The "On Next" marker is the Next list's own answer, so the Next list
      // must have answered before a marker means anything: until it does,
      // every row reads as not on Next.
      final nextAnswered = container!.read(nextProvider).hasValue;
      if (value.hasValue &&
          value.value!.isNotEmpty &&
          nextAnswered &&
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
    // One Place per group, in name order.
    expect(_labels(listed), ['Home', 'Office']);
    final home = listed.first.places.single;
    expect(home.rows.single.todo.id, 'home-outcome');
    expect(home.rows.single.isOnNext, isFalse,
        reason: 'the user is not at Home');
    final office = listed.last.places.single;
    expect(office.rows.single.todo.id, 'office-outcome');
    expect(office.rows.single.isOnNext, isTrue,
        reason: 'the user is at the Office');
  });

  test('a pin far from Home is its own Place, after Home', () async {
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
    // The pin is not near Home, so it is a group of its own, under its own
    // name.
    expect(_labels(listed), ['Home', 'Post office']);
    expect(listed, hasLength(2));
  });

  test('Places near each other are one group', () async {
    final hardwareAction = await _insertOutcome(db, 'hardware-outcome');
    final pharmacyAction = await _insertOutcome(db, 'pharmacy-outcome');
    final officeAction = await _insertOutcome(db, 'office-outcome');
    final hardwareId = await db.placeDao.createNamedPlace(
      name: 'Hardware store',
      latitudeDegrees: _home.latitudeDegrees,
      longitudeDegrees: _home.longitudeDegrees,
      radiusMeters: 150,
      userId: _userId,
    );
    final pharmacyId = await db.placeDao.createNamedPlace(
      name: 'Pharmacy',
      latitudeDegrees: _near.latitudeDegrees,
      longitudeDegrees: _near.longitudeDegrees,
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
    await db.actionDao.setNamedPlace(hardwareAction, hardwareId);
    await db.actionDao.setNamedPlace(pharmacyAction, pharmacyId);
    await db.actionDao.setNamedPlace(officeAction, officeId);
    location.freshPoint = _home;

    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      locationSourceProvider.overrideWithValue(location),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);

    final listed = await groups();
    // The hardware store and the pharmacy are 300 m apart: one group. The
    // office is 50 km away: a group of its own.
    expect(listed, hasLength(2));
    expect(listed.first.places.map((p) => p.label),
        ['Hardware store', 'Pharmacy']);
    expect(listed.last.places.map((p) => p.label), ['Office']);
  });

  test('a pin near a Place is in that Place\'s group', () async {
    final actionId = await _insertOutcome(db, 'at-home');
    final homeId = await db.placeDao.createNamedPlace(
      name: 'Home',
      latitudeDegrees: _home.latitudeDegrees,
      longitudeDegrees: _home.longitudeDegrees,
      radiusMeters: 150,
      userId: _userId,
    );
    await db.actionDao.setNamedPlace(actionId, homeId);
    final pinnedAction = await _insertOutcome(db, 'at-the-corner');
    final area = PlaceArea.create(
      latitudeDegrees: _veryNear.latitudeDegrees,
      longitudeDegrees: _veryNear.longitudeDegrees,
      radiusMeters: 150,
    )!;
    await db.actionDao.setPin(pinnedAction, area, name: 'Corner shop');
    location.freshPoint = _home;

    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      locationSourceProvider.overrideWithValue(location),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);

    final listed = await groups();
    expect(listed, hasLength(1));
    expect(listed.single.places.map((p) => p.label), ['Home', 'Corner shop']);
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
      ready: (groups) => groups.single.places.single.rows.isNotEmpty &&
          !groups.single.places.single.rows.single.isOnNext,
    );
    final row = listed.single.places.single.rows.single;
    expect(row.todo.id, 'timed');
    // The user is at the Place, but the Outcome is not on Next: its time is
    // closed.
    expect(row.isOnNext, isFalse);
  });

  group('the place page draws the places that are near each other together',
      () {
    late String hardwareStoreId;
    late String pharmacyId;
    late String officeId;

    setUp(() async {
      final hardwareAction = await _insertOutcome(db, 'hardware-outcome');
      final pharmacyAction = await _insertOutcome(db, 'pharmacy-outcome');
      final officeAction = await _insertOutcome(db, 'office-outcome');
      hardwareStoreId = (await db.placeDao.createNamedPlace(
        name: 'Hardware store',
        latitudeDegrees: _home.latitudeDegrees,
        longitudeDegrees: _home.longitudeDegrees,
        radiusMeters: 150,
        userId: _userId,
      ))!;
      pharmacyId = (await db.placeDao.createNamedPlace(
        name: 'Pharmacy',
        latitudeDegrees: _near.latitudeDegrees,
        longitudeDegrees: _near.longitudeDegrees,
        radiusMeters: 150,
        userId: _userId,
      ))!;
      officeId = (await db.placeDao.createNamedPlace(
        name: 'Office',
        latitudeDegrees: _elsewhere.latitudeDegrees,
        longitudeDegrees: _elsewhere.longitudeDegrees,
        radiusMeters: 150,
        userId: _userId,
      ))!;
      await db.actionDao.setNamedPlace(hardwareAction, hardwareStoreId);
      await db.actionDao.setNamedPlace(pharmacyAction, pharmacyId);
      await db.actionDao.setNamedPlace(officeAction, officeId);
      location.freshPoint = _home;
    });

    testWidgets('the near Places share a group, the far one does not',
        (tester) async {
      final router = GoRouter(
        initialLocation: '/places',
        routes: [
          GoRoute(path: '/places', builder: (_, _) => const PlacePageScreen()),
        ],
      );
      final widgetContainer = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        locationSourceProvider.overrideWithValue(location),
        notificationServiceProvider.overrideWithValue(StubNotificationService()),
      ]);
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: widgetContainer,
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await _settle(tester);

        // The two Places that are near each other are drawn as one group.
        final groupLine =
            find.byKey(Key('place_page_nearby_group_$hardwareStoreId'));
        expect(groupLine, findsOneWidget);

        // The Pharmacy is in that group: it comes after the group line, and
        // before the Office, which is 50 km away.
        final pharmacy = find.byKey(Key('place_page_place_$pharmacyId'));
        final office = find.byKey(Key('place_page_place_$officeId'));
        expect(pharmacy, findsOneWidget);
        expect(office, findsOneWidget);
        final groupTop = tester.getTopLeft(groupLine).dy;
        final pharmacyTop = tester.getTopLeft(pharmacy).dy;
        final officeTop = tester.getTopLeft(office).dy;
        expect(groupTop, lessThan(pharmacyTop));
        expect(pharmacyTop, lessThan(officeTop));

        // The Office is on its own: no group line for it.
        expect(find.byKey(Key('place_page_nearby_group_$officeId')),
            findsNothing);
      } finally {
        // The tree comes down first, so the watchers let go of the store, and
        // the container goes in the real zone, where the store's own teardown
        // can finish.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(() async => widgetContainer.dispose());
      }
    });
  });
}
