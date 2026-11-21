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
import 'package:jeeves/providers/habit_progress_provider.dart';
import 'package:jeeves/screens/habits/habit_calendar_screen.dart';
import 'package:jeeves/widgets/habit_day_mark_grid.dart';

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

  IconButton yearArrow(WidgetTester tester, {required bool previous}) =>
      tester.widget<IconButton>(
        find.widgetWithIcon(
          IconButton,
          previous ? Icons.chevron_left : Icons.chevron_right,
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

  testWidgets('the month title opens the year, a month opens that month', (
    tester,
  ) async {
    await openCalendar(tester);
    try {
      await tester.tap(find.text('November 2026'));
      await _settle(tester, 2);
      expect(find.text('2026'), findsOneWidget);
      expect(find.text('September'), findsOneWidget);
      expect(find.byType(Tab), findsNothing);
      expect(find.byType(TabBar), findsNothing);

      // The Habit began in 2026 and today is in 2026: no other year.
      expect(yearArrow(tester, previous: true).onPressed, isNull);
      expect(yearArrow(tester, previous: false).onPressed, isNull);

      await tester.tap(find.text('October'));
      await _settle(tester, 2);
      expect(find.text('October 2026'), findsOneWidget);
      expect(find.byType(Tab), findsNothing);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a year of 400 days is 12 painters, not a widget per day', (
    tester,
  ) async {
    final start = DateTime.utc(2025, 10, 14);
    habitId = await db.habitDao.createHabit(
      userId: _userId,
      title: 'Walk',
      today: habitDayKey(start),
      now: start.add(const Duration(hours: 8)),
      firstCommitment: const HabitCommitmentDraft(
        repeatKind: HabitRepeatKind.everyDay,
      ),
    );
    for (var i = 0; i < 400; i++) {
      final day = start.add(Duration(days: i));
      await db.habitDao.addCheckIn(
        habitId: habitId,
        userId: _userId,
        countsForDay: habitDayKey(day),
        now: day.add(const Duration(hours: 9)),
      );
    }
    await openCalendar(tester);
    try {
      await tester.tap(find.text('November 2026'));
      await _settle(tester, 2);
      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is HabitDayMarkPainter,
        ),
        findsNWidgets(12),
      );

      // The Habit began in 2025: the year arrows now have somewhere to go.
      await tester.tap(find.byTooltip('Previous year'));
      await _settle(tester, 2);
      expect(find.text('2025'), findsOneWidget);
      expect(yearArrow(tester, previous: true).onPressed, isNull);
    } finally {
      await closeApp(tester);
    }
  });

  // ---- The past-day sheet (step 5) ----

  Finder cell(String label) => find.bySemanticsLabel(RegExp('^$label'));

  Future<void> tapCell(WidgetTester tester, String label) async {
    await tester.tap(cell(label));
    await _settle(tester, 3);
  }

  Future<String> createBinaryHabit(String title, String startDay) =>
      db.habitDao.createHabit(
        userId: _userId,
        title: title,
        today: startDay,
        now: DateTime.parse('${startDay}T08:00:00Z'),
        firstCommitment: const HabitCommitmentDraft(
          repeatKind: HabitRepeatKind.everyDay,
        ),
      );

  testWidgets('a missed day takes a Check-in: the cell is done and the best '
      'streak is the engine\'s new value', (tester) async {
    final semantics = tester.ensureSemantics();
    await openCalendar(tester);
    try {
      final before = container.read(habitProgressProvider(habitId))!;
      await tapCell(tester, '6 November, missed');
      expect(find.text('Friday 6 November'), findsOneWidget);
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byTooltip('More'));
        await tester.pump();
      }
      await tester.tap(find.byKey(const Key('habit_day_add')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('habit_day_close')));
      await _settle(tester, 3);

      expect(cell('6 November, done, 6 of 6 glasses'), findsOneWidget);
      final after = container.read(habitProgressProvider(habitId))!;
      expect(after.bestStreak, before.bestStreak + 1);
    } finally {
      await closeApp(tester);
      semantics.dispose();
    }
  });

  testWidgets('a measurable day: change one entry, then remove one', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await openCalendar(tester);
    try {
      await tapCell(tester, '5 November, done');
      expect(find.byTooltip('Remove this Check-in'), findsNWidgets(2));

      await tester.tap(find.byTooltip('Change this value').first);
      await _settle(tester, 2);
      await tester.enterText(find.byKey(const Key('habit_day_change_field')), '1');
      await tester.tap(find.byKey(const Key('habit_day_change_save')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('habit_day_close')));
      await _settle(tester, 3);
      expect(
        cell('5 November, partly done, 4 of 6 glasses, 2 Check-ins'),
        findsOneWidget,
      );

      await tapCell(tester, '5 November');
      await tester.tap(find.byTooltip('Remove this Check-in').first);
      await _settle(tester);
      await tester.tap(find.byKey(const Key('habit_day_close')));
      await _settle(tester, 3);
      expect(
        cell('5 November, partly done, 3 of 6 glasses, 1 Check-in'),
        findsOneWidget,
      );
    } finally {
      await closeApp(tester);
      semantics.dispose();
    }
  });

  testWidgets('a binary day is one tap to add; after the change to a '
      'measurable Habit, Add asks for an amount', (tester) async {
    habitId = await createBinaryHabit('Read', '2026-10-01');
    await db.habitDao.setCommitment(
      habitId: habitId,
      userId: _userId,
      today: '2026-11-10',
      now: DateTime.utc(2026, 11, 10, 8),
      commitment: const HabitCommitmentDraft(
        repeatKind: HabitRepeatKind.everyDay,
        unitLabel: 'pages',
        dailyTargetAmount: 10,
      ),
    );
    final semantics = tester.ensureSemantics();
    await openCalendar(tester);
    try {
      await tapCell(tester, '12 November');
      expect(find.byKey(const Key('habit_day_new_amount')), findsOneWidget);
      await tester.tap(find.byKey(const Key('habit_day_close')));
      await _settle(tester, 3);

      await tester.tap(find.byTooltip('Previous month'));
      await _settle(tester, 2);
      await tapCell(tester, '20 October');
      expect(find.byKey(const Key('habit_day_new_amount')), findsNothing);
      expect(find.text('A Check-in here counts for 20 October.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('habit_day_add')));
      await _settle(tester);
      expect(find.byTooltip('Remove this Check-in'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
    } finally {
      await closeApp(tester);
      semantics.dispose();
    }
  });

  testWidgets('today with one Check-in takes a second from the sheet', (
    tester,
  ) async {
    habitId = await createBinaryHabit('Journal', '2026-11-01');
    await db.habitDao.addCheckIn(
      habitId: habitId,
      userId: _userId,
      countsForDay: '2026-11-18',
      now: DateTime.utc(2026, 11, 18, 7),
    );
    final semantics = tester.ensureSemantics();
    await openCalendar(tester);
    try {
      await tapCell(tester, '18 November, done');
      expect(find.byTooltip('Remove this Check-in'), findsOneWidget);
      await tester.tap(find.byKey(const Key('habit_day_add')));
      await _settle(tester);
      expect(find.byTooltip('Remove this Check-in'), findsNWidgets(2));
      await tester.tap(find.byKey(const Key('habit_day_close')));
      await _settle(tester, 3);
      expect(cell('18 November, done, 2 Check-ins'), findsOneWidget);
    } finally {
      await closeApp(tester);
      semantics.dispose();
    }
  });

  testWidgets('a paused day says it does not change the streak and still '
      'takes a Check-in', (tester) async {
    final semantics = tester.ensureSemantics();
    await openCalendar(tester);
    try {
      await tapCell(tester, '14 November, paused');
      expect(
        find.text("This day's Check-ins do not change the streak."),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('habit_day_add')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('habit_day_close')));
      await _settle(tester, 3);
      expect(
        cell('14 November, paused, 1 of 8 glasses, 1 Check-in'),
        findsOneWidget,
      );
    } finally {
      await closeApp(tester);
      semantics.dispose();
    }
  });

  testWidgets('future days and days before the Habit open no sheet', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await openCalendar(tester);
    try {
      await tapCell(tester, '19 November, not yet');
      expect(find.byKey(const Key('habit_day_add')), findsNothing);

      await tester.tap(find.byTooltip('Previous month'));
      await _settle(tester, 2);
      await tester.tap(find.byTooltip('Previous month'));
      await _settle(tester, 2);
      await tapCell(tester, '5 September, before the Habit');
      expect(find.byKey(const Key('habit_day_add')), findsNothing);
    } finally {
      await closeApp(tester);
      semantics.dispose();
    }
  });

  testWidgets('a Habit archived today is read-only: no day opens a sheet', (
    tester,
  ) async {
    habitId = await createBinaryHabit('Old', '2026-11-01');
    await db.habitDao.archive(
      habitId: habitId,
      userId: _userId,
      today: '2026-11-18',
      now: DateTime.utc(2026, 11, 18, 8),
    );
    final semantics = tester.ensureSemantics();
    await openCalendar(tester);
    try {
      await tapCell(tester, '10 November');
      expect(find.byKey(const Key('habit_day_add')), findsNothing);
      await tapCell(tester, '18 November');
      expect(find.byKey(const Key('habit_day_add')), findsNothing);
    } finally {
      await closeApp(tester);
      semantics.dispose();
    }
  });
}
