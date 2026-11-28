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

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/models/place_area.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/providers/place_page_provider.dart';
import 'package:jeeves/screens/place_page/place_page_screen.dart';
import 'package:jeeves/services/location_source.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/widgets/outcome_multi_select.dart';

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

/// Creates a Habit, at the named Place or pin when given.
Future<String> _insertHabit(
  GtdDatabase db,
  String title, {
  String? placeId,
  PlaceArea? pinArea,
  String? pinName,
}) {
  final now = DateTime.now();
  return db.habitDao.createHabit(
    userId: _userId,
    title: title,
    today: habitDayKey(now),
    now: now,
    firstCommitment: defaultNewHabitCommitment,
    placeId: placeId,
    pinArea: pinArea,
    pinName: pinName,
  );
}

Future<String> _namedPlace(GtdDatabase db, String name) async =>
    (await db.placeDao.createNamedPlace(
      name: name,
      latitudeDegrees: _home.latitudeDegrees,
      longitudeDegrees: _home.longitudeDegrees,
      radiusMeters: 150,
      userId: _userId,
    ))!;

/// The titles of a section's Habits.
List<String> _habitTitles(PlacePageSection place) =>
    [for (final row in place.habits) row.habit.title];

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

/// The five named Places, in the order the page lists them.
const _placeNames = ['Alpha', 'Bravo', 'Charlie', 'Delta', 'Echo'];

/// Seeds the five named Places, each with an Outcome.
Future<Map<String, String>> _seedPlaces(GtdDatabase db) async {
  final ids = <String, String>{};
  var offset = 0.0;
  for (final name in _placeNames) {
    final placeId = await db.placeDao.createNamedPlace(
      name: name,
      latitudeDegrees: _home.latitudeDegrees + offset,
      longitudeDegrees: _home.longitudeDegrees,
      radiusMeters: 150,
      userId: _userId,
    );
    offset += 0.01;
    expect(placeId, isNotNull, reason: 'the Place "$name" is saved');
    final id = placeId!;
    final actionId = await _insertOutcome(db, 'outcome-${name.toLowerCase()}');
    await db.actionDao.setNamedPlace(actionId, id);
    ids[name] = id;
  }
  return ids;
}

/// Whether the text is on the screen of the place page's list.
///
/// A header above the top of the list is off the screen, whether the list has
/// built it or not.
bool _onScreen(WidgetTester tester, Finder finder) {
  if (finder.evaluate().isEmpty) return false;
  final list = tester.getRect(find.byType(CustomScrollView));
  return tester.getRect(finder).overlaps(list);
}

/// Whether the header is at the top of the list.
bool _atTop(WidgetTester tester, String name) {
  final header = find.text(name);
  if (header.evaluate().isEmpty) return false;
  final list = tester.getRect(find.byType(CustomScrollView));
  final offset = tester.getRect(header).top - list.top;
  // Not above the top either: a header scrolled out of sight is not "at the
  // top".
  return offset >= 0 && offset < 50;
}

/// Scrolls the list up until the header is on the screen.
Future<void> _scrollUpTo(WidgetTester tester, Finder header) async {
  for (var i = 0; i < 10; i++) {
    if (_onScreen(tester, header)) return;
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
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
    container = null;
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

  ProviderContainer makeContainer() => container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        locationSourceProvider.overrideWithValue(location),
        notificationServiceProvider
            .overrideWithValue(StubNotificationService()),
      ]);

  /// Ready once the sections hold [habitCount] Habits between them.
  bool Function(List<PlacePageGroup>) habitsReady(int habitCount) =>
      (listed) =>
          listed.fold<int>(
              0,
              (sum, group) =>
                  sum +
                  group.places.fold<int>(0, (n, p) => n + p.habits.length)) ==
          habitCount;

  test('a Habit with a Place is listed under it, after the Outcomes',
      () async {
    final pool = await _namedPlace(db, 'Pool');
    final action = await _insertOutcome(db, 'pool-outcome');
    await db.actionDao.setNamedPlace(action, pool);
    await _insertHabit(db, 'Swim', placeId: pool);
    makeContainer();

    final listed = await groups(ready: habitsReady(1));
    expect(_labels(listed), ['Pool']);
    final section = listed.single.places.single;
    expect(section.rows.single.todo.id, 'pool-outcome');
    expect(_habitTitles(section), ['Swim']);
    expect(section.habits.single.state, HabitState.active);
  });

  test('a Place only a Habit uses is a section with no Outcomes', () async {
    final gym = await _namedPlace(db, 'Gym');
    await _insertHabit(db, 'Lift', placeId: gym);
    makeContainer();

    final listed = await groups(ready: habitsReady(1));
    expect(_labels(listed), ['Gym']);
    expect(listed.single.places.single.rows, isEmpty);
    expect(_habitTitles(listed.single.places.single), ['Lift']);
  });

  test('a Habit with no Place, and an archived Habit, are not listed',
      () async {
    final pool = await _namedPlace(db, 'Pool');
    await _insertHabit(db, 'Floss');
    final archivedId = await _insertHabit(db, 'Old swim', placeId: pool);
    await _insertHabit(db, 'Swim', placeId: pool);
    final now = DateTime.now();
    await db.habitDao.archive(
        habitId: archivedId,
        userId: _userId,
        today: habitDayKey(now),
        now: now);
    makeContainer();

    final listed = await groups(ready: habitsReady(1));
    expect(_labels(listed), ['Pool']);
    expect(_habitTitles(listed.single.places.single), ['Swim']);
  });

  test('a paused Habit is listed, and says it is paused', () async {
    final pool = await _namedPlace(db, 'Pool');
    final habitId = await _insertHabit(db, 'Swim', placeId: pool);
    final now = DateTime.now();
    await db.habitDao.pause(
        habitId: habitId,
        userId: _userId,
        today: habitDayKey(now),
        now: now);
    makeContainer();

    final listed = await groups(ready: habitsReady(1));
    expect(listed.single.places.single.habits.single.state,
        HabitState.paused);
  });

  test('a Habit with a pin is listed under the pin\'s name', () async {
    final area = PlaceArea.create(
      latitudeDegrees: 52.3000,
      longitudeDegrees: 4.8000,
      radiusMeters: 150,
    )!;
    await _insertHabit(db, 'Post letters', pinArea: area, pinName: 'Post office');
    makeContainer();

    final listed = await groups(ready: habitsReady(1));
    expect(_labels(listed), ['Post office']);
  });

  test('a Place only a Habit uses is no errand stop', () async {
    final gym = await _namedPlace(db, 'Gym');
    await _insertHabit(db, 'Lift', placeId: gym);
    makeContainer();

    final listed = await groups(ready: habitsReady(1));
    expect(errandStopsFrom(listed, {'anything'}), isEmpty);
  });

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

  testWidgets('the page opens at the Place it is given', (tester) async {
    final placeIds = await _seedPlaces(db);
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      locationSourceProvider.overrideWithValue(location),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);

    final router = GoRouter(
      initialLocation: '/places',
      routes: [
        GoRoute(path: '/places', builder: PlacePageScreen.buildRoute),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container!,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    try {
      await _settle(tester);

      // Without a Place, the page opens as it always did: at the first group,
      // at the top of the list.
      expect(_atTop(tester, 'Alpha'), isTrue);

      // With one, the page opens at that Place: its group at the top, and the
      // Places above it above the top of the list.
      router.go('/places?place=${placeIds['Echo']}');
      await _settle(tester);
      expect(_atTop(tester, 'Echo'), isTrue);
      expect(_onScreen(tester, find.text('Alpha')), isFalse);

      // The Places above it are reached by scrolling up.
      await _scrollUpTo(tester, find.text('Alpha'));
      expect(_onScreen(tester, find.text('Alpha')), isTrue);
    } finally {
      // The widget tree goes with the test; the container is disposed by the
      // tear-down, with the store.
      await tester.pumpWidget(const SizedBox.shrink());
      // The Habit list holds the day-rollover timer; it goes with the
      // container, inside the body, or the test fails its timer check.
      container?.dispose();
      container = null;
      await tester.pumpAndSettle();
    }
  }, timeout: const Timeout(Duration(seconds: 120)));

  testWidgets('a Place that is not on the page opens the first group',
      (tester) async {
    await _seedPlaces(db);
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      locationSourceProvider.overrideWithValue(location),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);

    final router = GoRouter(
      initialLocation: '/places?place=not-a-place',
      routes: [
        GoRoute(path: '/places', builder: PlacePageScreen.buildRoute),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container!,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    try {
      await _settle(tester);

      // The Place is not on the page, so the page opens as it always did: at
      // the first group, at the top of the list.
      expect(_atTop(tester, 'Alpha'), isTrue);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      // The Habit list holds the day-rollover timer; it goes with the
      // container, inside the body, or the test fails its timer check.
      container?.dispose();
      container = null;
      await tester.pumpAndSettle();
    }
  }, timeout: const Timeout(Duration(seconds: 120)));

  group('Habits on the page', () {
    /// Pumps the page, with a stand-in for the Habit's detail route.
    Future<GoRouter> pumpPage(WidgetTester tester) async {
      makeContainer();
      final router = GoRouter(
        initialLocation: '/places',
        routes: [
          GoRoute(path: '/places', builder: (_, _) => const PlacePageScreen()),
          GoRoute(
            path: '/habits/:id',
            builder: (_, _) => const Scaffold(body: Text('habit detail')),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container!,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await _settle(tester);
      return router;
    }

    Future<void> tearDownTree(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      // The Habit list holds the day-rollover timer; it goes with the
      // container, inside the body, or the test fails its timer check.
      container?.dispose();
      container = null;
      await tester.pumpAndSettle();
    }

    testWidgets('a Habit is under its Place, marked as a Habit',
        (tester) async {
      final pool = await _namedPlace(db, 'Pool');
      final action = await _insertOutcome(db, 'pool-outcome');
      await db.actionDao.setNamedPlace(action, pool);
      final habitId = await _insertHabit(db, 'Swim', placeId: pool);
      await _insertHabit(db, 'Floss');
      await pumpPage(tester);
      try {
        expect(find.byKey(Key('place_page_place_$pool')), findsOneWidget);
        expect(find.byKey(Key('place_page_habit_row_$habitId')),
            findsOneWidget);
        expect(find.text('Swim'), findsOneWidget);
        expect(find.text('Floss'), findsNothing,
            reason: 'a Habit without a Place is not on the page');
        expect(find.byKey(const Key('place_marker_habit')), findsOneWidget);
        expect(find.text('Habit'), findsOneWidget);
        // The Outcome at the same Place still says where it stands.
        expect(
            find.byKey(const Key('place_marker_on_next')).evaluate().length +
                find.byKey(const Key('place_marker_elsewhere')).evaluate().length,
            1);
      } finally {
        await tearDownTree(tester);
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    testWidgets('a paused Habit says so', (tester) async {
      final pool = await _namedPlace(db, 'Pool');
      final habitId = await _insertHabit(db, 'Swim', placeId: pool);
      final now = DateTime.now();
      await db.habitDao.pause(
          habitId: habitId,
          userId: _userId,
          today: habitDayKey(now),
          now: now);
      await pumpPage(tester);
      try {
        expect(find.text('Paused Habit'), findsOneWidget);
      } finally {
        await tearDownTree(tester);
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    testWidgets('a tap opens the Habit', (tester) async {
      final pool = await _namedPlace(db, 'Pool');
      final habitId = await _insertHabit(db, 'Swim', placeId: pool);
      await pumpPage(tester);
      try {
        await tester.tap(find.byKey(Key('place_page_habit_row_$habitId')));
        await _settle(tester);
        // The detail is pushed, so it is the page on top.
        expect(find.text('habit detail'), findsOneWidget);
      } finally {
        await tearDownTree(tester);
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    testWidgets('a Habit cannot be selected; Select all takes Outcomes only',
        (tester) async {
      final pool = await _namedPlace(db, 'Pool');
      final action = await _insertOutcome(db, 'pool-outcome');
      await db.actionDao.setNamedPlace(action, pool);
      final habitId = await _insertHabit(db, 'Swim', placeId: pool);
      await pumpPage(tester);
      try {
        await tester.longPress(find.textContaining('pool-outcome').first);
        await _settle(tester);
        expect(find.byType(OutcomeSelectionBar), findsOneWidget);

        // While a selection is going the Habit row does nothing: it cannot be
        // selected and it does not open.
        await tester.tap(find.byKey(Key('place_page_habit_row_$habitId')));
        await _settle(tester);
        expect(find.text('habit detail'), findsNothing);
        expect(find.byType(OutcomeSelectionBar), findsOneWidget);

        // The one Outcome is everything that can be selected: the Habit is not
        // counted, so there is nothing left for Select all to add.
        expect(find.text('1 selected'), findsOneWidget);
        expect(find.text('Select all'), findsNothing);
        expect(find.byType(Checkbox), findsOneWidget);
      } finally {
        await tearDownTree(tester);
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    testWidgets('with nothing at a place, the empty state names both',
        (tester) async {
      await pumpPage(tester);
      try {
        expect(
            find.text('Outcomes and Habits you give a place to are listed here.'),
            findsOneWidget);
      } finally {
        await tearDownTree(tester);
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
