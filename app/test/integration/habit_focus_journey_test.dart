/// Journey: Focus Mode on a Habit (#405).
///
/// The real Habit detail and the real Focus screen, over a real in-memory
/// database. Live Drift streams and a ticking timer run, so the test pumps
/// bounded frames instead of `pumpAndSettle`, and unmounts the tree inside
/// the body (TESTING.md).
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
import 'package:jeeves/screens/habits/habit_detail_pane.dart';
import 'package:jeeves/screens/habits/habit_focus_screen.dart';
import 'package:jeeves/widgets/sprint_ring.dart';

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
  late DateTime clockNow;
  // Wednesday 18 Nov 2026, 09:30 local.
  final now = DateTime(2026, 11, 18, 9, 30);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    router.dispose();
    await db.close();
  });

  Future<String> seed(
    String title, {
    int? estimate,
    HabitCommitmentDraft commitment = defaultNewHabitCommitment,
  }) async {
    final id = await db.habitDao.createHabit(
      userId: _userId,
      title: title,
      today: '2026-11-16',
      now: now.subtract(const Duration(days: 2)),
      firstCommitment: commitment,
    );
    if (estimate != null) {
      await db.habitDao.updateHabitDetails(
        habitId: id,
        userId: _userId,
        title: title,
        notes: null,
        energyLevel: null,
        timeEstimateMinutes: estimate,
        now: now,
      );
    }
    return id;
  }

  Future<void> openDetail(WidgetTester tester, String habitId) async {
    clockNow = now;
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(() => clockNow),
      ],
    );
    router = GoRouter(
      initialLocation: '/habits/$habitId',
      routes: [
        GoRoute(
          path: '/habits/:id',
          builder: (_, state) =>
              HabitDetailScreen(habitId: state.pathParameters['id']!),
          routes: [
            GoRoute(
              path: 'focus',
              builder: (_, state) =>
                  HabitFocusScreen(habitId: state.pathParameters['id']!),
            ),
          ],
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

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await _settle(tester);
  }

  testWidgets('a Habit with a 20 minute estimate runs in Focus Mode and logs '
      'time against the Habit only (AC 5)', (tester) async {
    final id = await seed('Meditate', estimate: 20);
    await openDetail(tester, id);
    try {
      expect(find.text('Focus · 20m'), findsOneWidget);
      await tapKey(tester, 'habit_focus_start');

      expect(find.text('HABIT · FOCUS MODE'), findsOneWidget);
      expect(find.text('Meditate'), findsOneWidget);
      expect(find.text("Habit · not in Today's Plan"), findsOneWidget);
      expect(find.text('20m'), findsOneWidget);
      expect(find.byType(SprintRing), findsOneWidget);
      expect(find.text('Start a break'), findsOneWidget);

      clockNow = now.add(const Duration(minutes: 10));
      await tapKey(tester, 'habit_focus_primary');
      expect(find.text('Start next sprint'), findsOneWidget);
      clockNow = now.add(const Duration(minutes: 20));
      await tapKey(tester, 'habit_focus_primary');
      expect(find.text('Start a break'), findsOneWidget);

      await tapKey(tester, 'habit_focus_stop');
      expect(find.text('Add a check-in, sir?'), findsOneWidget);
      await tapKey(tester, 'habit_focus_check_in_not_now');
      expect(find.text('HABIT · FOCUS MODE'), findsNothing);

      final rows = await tester.runAsync(() async => (
            habitLogs: await db.select(db.habitTimeLogs).get(),
            habitSprints: await db.select(db.habitSprints).get(),
            timeLogs: await db.select(db.timeLogs).get(),
            sprints: await db.select(db.sprints).get(),
          ));
      expect(rows!.habitLogs, hasLength(1));
      expect(rows.habitLogs.single.habitId, id);
      expect(rows.habitLogs.single.endedAt, isNotNull);
      expect(rows.habitSprints, hasLength(2));
      expect(rows.timeLogs, isEmpty);
      expect(rows.sprints, isEmpty);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('there is no Start Focus without an estimate', (tester) async {
    final id = await seed('Water');
    await openDetail(tester, id);
    try {
      expect(find.byKey(const Key('habit_focus_start')), findsNothing);
      expect(find.byKey(const Key('habit_focus_entry')), findsNothing);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('there is no Start Focus on a paused Habit', (tester) async {
    final id = await seed('Stretch', estimate: 10);
    await db.habitDao.pause(
        habitId: id, userId: _userId, today: '2026-11-18', now: now);
    await openDetail(tester, id);
    try {
      expect(find.byKey(const Key('habit_focus_start')), findsNothing);
      expect(find.byKey(const Key('habit_focus_entry')), findsNothing);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('an open Focus left behind reads Resume Focus and reopens the '
      'running Focus', (tester) async {
    final id = await seed('Meditate', estimate: 20);
    await db.habitFocusDao.openHabitFocus(
        habitId: id, userId: _userId, plannedSprintMinutes: 20, now: now);
    await openDetail(tester, id);
    try {
      expect(find.text('Resume Focus · 20m'), findsOneWidget);
      expect(find.byTooltip('Resume Focus Mode on this Habit'), findsOneWidget);
      await tapKey(tester, 'habit_focus_start');

      expect(find.text('HABIT · FOCUS MODE'), findsOneWidget);
      final logs = await tester
          .runAsync(() => db.select(db.habitTimeLogs).get());
      expect(logs, hasLength(1), reason: 'the open Focus is adopted');
      expect(logs!.single.endedAt, isNull);
      expect(find.text('Start a break'), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  Future<List<HabitCheckIn>> checkIns(WidgetTester tester) async =>
      (await tester.runAsync(() => db.select(db.habitCheckIns).get()))!;

  Future<void> startFocus(WidgetTester tester) async {
    await tapKey(tester, 'habit_focus_start');
    expect(find.text('HABIT · FOCUS MODE'), findsOneWidget);
  }

  testWidgets('binary: Stop then Very good gives one Check-in today',
      (tester) async {
    final id = await seed('Meditate', estimate: 20);
    await openDetail(tester, id);
    try {
      await startFocus(tester);
      await tapKey(tester, 'habit_focus_stop');
      expect(find.text('Add a check-in, sir?'), findsOneWidget);
      expect(find.textContaining('Nothing is added unless you say so.'),
          findsOneWidget);
      expect(await checkIns(tester), isEmpty,
          reason: 'the sheet asks; it adds nothing by itself');

      await tapKey(tester, 'habit_focus_check_in_yes');
      final rows = await checkIns(tester);
      expect(rows, hasLength(1));
      expect(rows.single.habitId, id);
      expect(rows.single.countsForDay, '2026-11-18');
      expect(rows.single.measuredAmount, isNull);
      expect(find.text('HABIT · FOCUS MODE'), findsNothing);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('binary: Stop then Not now gives no Check-in', (tester) async {
    final id = await seed('Meditate', estimate: 20);
    await openDetail(tester, id);
    try {
      await startFocus(tester);
      await tapKey(tester, 'habit_focus_stop');
      await tapKey(tester, 'habit_focus_check_in_not_now');
      expect(await checkIns(tester), isEmpty);
      expect(find.text('HABIT · FOCUS MODE'), findsNothing);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('measurable: More once, then Very good gives a Check-in of 2; '
      'Less at 1 stays at 1', (tester) async {
    final id = await seed(
      'Read',
      estimate: 30,
      commitment: const HabitCommitmentDraft(
        repeatKind: HabitRepeatKind.everyDay,
        unitLabel: 'pages',
        dailyTargetAmount: 20,
      ),
    );
    await openDetail(tester, id);
    try {
      await startFocus(tester);
      await tapKey(tester, 'habit_focus_stop');
      expect(find.textContaining('Say how far you got.'), findsOneWidget);
      expect(find.text('pages to add'), findsOneWidget);
      expect(find.text('0 of 20 so far today'), findsOneWidget);

      Finder stepper() => find.byKey(const Key('habit_focus_check_in_stepper'));
      expect(tester.widget<Text>(stepper()).data, '1');
      await tester.tap(find.byTooltip('Less'), warnIfMissed: false);
      await _settle(tester);
      expect(tester.widget<Text>(stepper()).data, '1');
      await tester.tap(find.byTooltip('More'));
      await _settle(tester);
      expect(tester.widget<Text>(stepper()).data, '2');

      await tapKey(tester, 'habit_focus_check_in_yes');
      final rows = await checkIns(tester);
      expect(rows, hasLength(1));
      expect(rows.single.measuredAmount, 2);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('system back behaves as Stop and shows the sheet (AC 5)',
      (tester) async {
    final id = await seed('Meditate', estimate: 20);
    await openDetail(tester, id);
    try {
      await startFocus(tester);
      await tester.runAsync(() => tester.binding.handlePopRoute());
      await _settle(tester);
      expect(find.text('Add a check-in, sir?'), findsOneWidget);
      final logs = await tester.runAsync(() => db.select(db.habitTimeLogs).get());
      expect(logs!.single.endedAt, isNotNull);
      await tapKey(tester, 'habit_focus_check_in_not_now');
      expect(find.text('HABIT · FOCUS MODE'), findsNothing);
    } finally {
      await closeApp(tester);
    }
  });
}
