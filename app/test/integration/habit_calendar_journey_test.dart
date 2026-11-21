/// Journey: the Check-in calendar's month view (#404).
///
/// The real route over a real in-memory database, seeded in `setUp` through
/// `HabitDao`: a measurable Habit with done, missed, paused and part days, two
/// Check-ins on one day and a target change. Live Drift streams run, so the
/// test pumps bounded frames and unmounts the tree inside the body
/// (TESTING.md).
library;

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
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/habits/habit_calendar_screen.dart';

import '../test_helpers.dart';

const _userId = 'local';

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
  late GoRouter router;
  late String habitId;

  // "Now" for the app: Wednesday 18 November 2026, midday.
  DateTime clock() => DateTime(2026, 11, 18, 12);

  Future<void> checkIn(String day, double amount, int minute) =>
      db.habitDao.addCheckIn(
        habitId: habitId,
        userId: _userId,
        countsForDay: day,
        now: DateTime.utc(2026, 11, 18, 8, minute),
        measuredAmount: amount,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    habitId = await db.habitDao.createHabit(
      userId: _userId,
      title: 'Water',
      today: '2026-09-20',
      now: DateTime.utc(2026, 9, 20, 8),
      firstCommitment: const HabitCommitmentDraft(
        repeatKind: HabitRepeatKind.everyDay,
        unitLabel: 'glasses',
        dailyTargetAmount: 6,
      ),
    );
    // The target rises to 8 glasses from 9 November.
    await db.habitDao.setCommitment(
      habitId: habitId,
      userId: _userId,
      today: '2026-11-09',
      now: DateTime.utc(2026, 11, 9, 8),
      commitment: const HabitCommitmentDraft(
        repeatKind: HabitRepeatKind.everyDay,
        unitLabel: 'glasses',
        dailyTargetAmount: 8,
      ),
    );
    await checkIn('2026-11-03', 6, 0); // done at the old target
    await checkIn('2026-11-05', 3, 1); // two Check-ins, 3 + 3
    await checkIn('2026-11-05', 3, 2);
    await checkIn('2026-11-12', 5, 3); // part of the new target
    await db.habitDao.pause(
      habitId: habitId,
      userId: _userId,
      today: '2026-11-14',
      now: DateTime.utc(2026, 11, 14, 8),
      resumesOn: '2026-11-16',
    );
  });

  tearDown(() async {
    router.dispose();
    await db.close();
  });

  Future<void> openCalendar(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(clock),
      ],
    );
    router = GoRouter(
      initialLocation: '/habits/$habitId/calendar',
      routes: [
        GoRoute(
          path: '/habits/:id/calendar',
          builder: (_, state) =>
              HabitCalendarScreen(habitId: state.pathParameters['id']!),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await _settle(tester);
  }

  Future<void> closeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => pumpEventQueue());
    container.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  IconButton arrow(WidgetTester tester, String tooltip) =>
      tester.widget<IconButton>(
        find.widgetWithIcon(
          IconButton,
          tooltip == 'Previous month'
              ? Icons.chevron_left
              : Icons.chevron_right,
        ),
      );

  testWidgets('every day of the month carries a label that says what it was', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await openCalendar(tester);
    try {
      expect(find.text('November 2026'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          RegExp(r'^3 November, done, 6 of 6 glasses, 1 Check-in'),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          RegExp(r'^5 November, done, 6 of 6 glasses, 2 Check-ins'),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^6 November, missed')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          RegExp(r'^12 November, partly done, 5 of 8 glasses'),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^14 November, paused')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^15 November, paused')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^18 November, not done yet.*today')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RegExp(r'repeat changed')), findsOneWidget);
    } finally {
      await closeApp(tester);
      semantics.dispose();
    }
  });

  testWidgets('a day with two Check-ins shows 2×, and a part day 5 of 8', (
    tester,
  ) async {
    await openCalendar(tester);
    try {
      expect(find.text('2×'), findsOneWidget);
      expect(find.text('5 of 8'), findsOneWidget);
      expect(find.text('Repeat changed'), findsOneWidget); // the legend
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('the arrows stop at the current month and at the first month', (
    tester,
  ) async {
    await openCalendar(tester);
    try {
      expect(arrow(tester, 'Next month').onPressed, isNull);
      expect(arrow(tester, 'Previous month').onPressed, isNotNull);

      // November -> October -> September, where the Habit began on 20 Sept.
      await tester.tap(find.byTooltip('Previous month'));
      await _settle(tester, 2);
      expect(find.text('October 2026'), findsOneWidget);
      await tester.tap(find.byTooltip('Previous month'));
      await _settle(tester, 2);
      expect(find.text('September 2026'), findsOneWidget);
      expect(arrow(tester, 'Previous month').onPressed, isNull);
      expect(arrow(tester, 'Next month').onPressed, isNotNull);

      await tester.tap(find.byTooltip('Next month'));
      await _settle(tester, 2);
      await tester.tap(find.byTooltip('Next month'));
      await _settle(tester, 2);
      expect(find.text('November 2026'), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });
}
