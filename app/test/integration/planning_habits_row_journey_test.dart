/// Journey: the read-only habits card on Build Today's Plan (#405).
///
/// The real Daily Planning screen on its last step, over a real in-memory
/// database. Live Drift streams run, so the test pumps bounded frames instead
/// of `pumpAndSettle` (docs/TESTING.md).
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/current_location_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/screens/planning/focus_session_planning_screen.dart';
import 'package:jeeves/services/notification_service.dart';

import '../helpers/fake_location_source.dart';
import '../helpers/settle.dart';
import '../test_helpers.dart';

const _userId = 'local';

/// The user is somewhere else: far outside every Place in this test.
const _elsewhere = (latitudeDegrees: 52.0, longitudeDegrees: 4.0);

Future<void> _settle(WidgetTester tester, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;
  late FakeLocationSource location;
  // Wednesday 18 Nov 2026, 09:30 local.
  final now = DateTime(2026, 11, 18, 9, 30);
  const mon = '2026-11-16';
  const tue = '2026-11-17';
  const wed = '2026-11-18';

  var seedCount = 0;
  Future<String> seed(
    WidgetTester tester,
    String title, {
    HabitCommitmentDraft commitment = defaultNewHabitCommitment,
    int? estimateMinutes,
  }) async {
    final id = await tester.runAsync(() => db.habitDao.createHabit(
          userId: _userId,
          title: title,
          today: mon,
          now: now
              .subtract(const Duration(days: 5))
              .add(Duration(milliseconds: seedCount++)),
          firstCommitment: commitment,
        ));
    if (estimateMinutes != null) {
      await tester.runAsync(() => db.habitDao.updateHabitDetails(
            habitId: id!,
            userId: _userId,
            title: title,
            notes: null,
            energyLevel: null,
            timeEstimateMinutes: estimateMinutes,
            now: now,
          ));
    }
    return id!;
  }

  Future<void> checkInOn(WidgetTester tester, String id, String day) =>
      tester.runAsync(() => db.habitDao.addCheckIn(
            habitId: id,
            userId: _userId,
            countsForDay: day,
            now: DateTime.parse('${day}T08:00:00'),
          ));

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    location = FakeLocationSource()..freshPoint = _elsewhere;
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
      activeSessionProvider.overrideWith((_) => Stream.value(null)),
      locationSourceProvider.overrideWithValue(location),
      // The phone knows the user is elsewhere. A Place never hides a Habit.
      currentLocationProvider.overrideWith(
        () => FixedLocationNotifier(const LocationKnown(_elsewhere)),
      ),
    ]);
  });

  tearDown(() async {
    await location.dispose();
    await db.close();
  });

  Future<void> openBuildPlan(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const FocusSessionPlanningScreen()),
      GoRoute(path: '/focus', builder: (_, _) => const SizedBox()),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    container.read(focusSessionPlanningProvider.notifier).goToStep(5);
    await _settle(tester);
  }

  Future<void> closeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    // The midnight timer must be gone before the test body ends.
    await tester.runAsync(() async => container.dispose());
    await tester.pump();
  }

  Future<void> insertOutcome(WidgetTester tester, String id) async {
    await tester.runAsync(() async {
      final t = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
            id: Value(id),
            title: Value('Outcome $id'),
            intent: const Value('next'),
            userId: const Value(_userId),
            createdAt: Value(t),
            updatedAt: Value(t),
          ));
      await seedCurrentAction(db,
          outcomeId: id, text: 'work on $id', userId: _userId);
    });
  }

  String capacityText(WidgetTester tester) => tester
      .widgetList<Text>(find.textContaining('planned of'))
      .single
      .data!;

  testWidgets('shows today\'s Habits in stack order, not the others',
      (tester) async {
    final first = await seed(tester, 'Stretch');
    await seed(tester, 'Read');
    final notDue = await seed(
      tester,
      'Gym',
      commitment: const HabitCommitmentDraft(
        repeatKind: HabitRepeatKind.timesPerWeek,
        timesPerPeriod: 1,
      ),
    );
    await checkInOn(tester, notDue, mon); // week target reached: not due
    final paused = await seed(tester, 'Paused one');
    await tester.runAsync(() => db.habitDao
        .pause(habitId: paused, userId: _userId, today: wed, now: now));
    await checkInOn(tester, first, mon);
    await checkInOn(tester, first, tue);

    await openBuildPlan(tester);
    try {
      expect(find.byKey(const Key('plan_habits_card')), findsOneWidget);
      expect(find.text('HABITS TODAY'), findsOneWidget);
      expect(find.text('Stretch'), findsOneWidget);
      expect(find.text('Read'), findsOneWidget);
      expect(find.text('2 days'), findsOneWidget); // Stretch
      expect(find.text('0 days'), findsOneWidget); // Read: a 0 streak shows
      expect(find.text('Gym'), findsNothing);
      expect(find.text('Paused one'), findsNothing);
      // Two-column grid: stack order reads left to right, then down.
      expect(
        tester.getTopLeft(find.text('Stretch')).dx,
        lessThan(tester.getTopLeft(find.text('Read')).dx),
      );
      expect(find.text('0 of 2 done'), findsOneWidget);
      expect(find.text('Not part of the plan and not counted in capacity.'),
          findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a Habit at a Place shows the Place\'s name, and is not hidden '
      'by it', (tester) async {
    final placeId = await tester.runAsync(() => db.placeDao.createNamedPlace(
          name: 'Home',
          latitudeDegrees: 52.3702,
          longitudeDegrees: 4.8952,
          radiusMeters: 150,
          userId: _userId,
        ));
    final atHome = await seed(tester, 'Stretch');
    await tester.runAsync(() => db.habitDao.setNamedPlace(
          atHome,
          placeId!,
          now: now,
        ));
    final noPlace = await seed(tester, 'Read');
    await checkInOn(tester, noPlace, mon);
    await checkInOn(tester, noPlace, tue);

    await openBuildPlan(tester);
    try {
      // The user is elsewhere, and the Habit is still listed.
      expect(find.text('Stretch'), findsOneWidget);
      // Its Place is said, on the line beside the streak number. The Place
      // list is a live Drift stream, so it needs a turn of its own.
      await pumpUntilFound(tester, find.text('Home · 0 days'));
      expect(find.text('Home · 0 days'), findsOneWidget);
      // A Habit with no Place says nothing about one.
      expect(find.text('2 days'), findsOneWidget);
      expect(find.text('Home'), findsNothing);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a Habit with an estimate does not change the capacity',
      (tester) async {
    await insertOutcome(tester, 'o1');
    await openBuildPlan(tester);
    try {
      container.read(focusSessionPlanningProvider.notifier).selectTask('o1');
      await _settle(tester);
      final without = capacityText(tester);

      await seed(tester, 'Stretch', estimateMinutes: 60);
      await _settle(tester);
      expect(find.text('Stretch'), findsOneWidget);
      expect(capacityText(tester), without);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('tapping an entry writes no Check-in', (tester) async {
    final id = await seed(tester, 'Stretch');
    await openBuildPlan(tester);
    try {
      await tester.tap(find.text('Stretch'));
      await tester.tap(find.byIcon(Icons.radio_button_unchecked).first);
      await _settle(tester);
      final checkIns =
          await tester.runAsync(() => db.select(db.habitCheckIns).get());
      expect(checkIns!.where((c) => c.habitId == id), isEmpty);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('every Habit done shows the all-done line', (tester) async {
    final a = await seed(tester, 'Stretch');
    final b = await seed(tester, 'Read');
    await checkInOn(tester, a, wed);
    await checkInOn(tester, b, wed);
    await openBuildPlan(tester);
    try {
      expect(find.textContaining('All 2 have their Check-in'), findsOneWidget);
      expect(find.text('2 of 2 done'), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('many Habits: eight in the grid, then "and n more"',
      (tester) async {
    for (var i = 0; i < 10; i++) {
      await seed(tester, 'Habit $i');
    }
    await openBuildPlan(tester);
    try {
      expect(find.textContaining('Habit '), findsNWidgets(8));
      expect(find.text('and 2 more · shown in Habits'), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('no Habit for today: no card', (tester) async {
    await openBuildPlan(tester);
    try {
      expect(find.byKey(const Key('plan_habits_card')), findsNothing);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a Habit title never appears in the plan list', (tester) async {
    await insertOutcome(tester, 'o1');
    await seed(tester, 'Stretch');
    await openBuildPlan(tester);
    try {
      // Once in the card, never as an Outcome row.
      expect(find.text('Stretch'), findsOneWidget);
      expect(find.text('Outcome o1'), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });
}
