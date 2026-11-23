/// Journey: the stats block and five-month strip on a Habit's detail (#404).
///
/// The real detail route over a real in-memory database, with a fixed clock
/// (Wednesday 18 November 2026). Streak numbers are worked out by hand; the
/// rate tiles are checked against `computeHabitProgress` on the same history.
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
import 'package:jeeves/models/habit_days.dart';
import 'package:jeeves/models/habit_progress.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/habit_progress_provider.dart';
import 'package:jeeves/screens/habits/habit_calendar_screen.dart';
import 'package:jeeves/screens/habits/habit_detail_pane.dart';

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

  DateTime clock() => DateTime(2026, 11, 18, 12);

  Future<String> createHabit(
    String title,
    String since,
    HabitCommitmentDraft commitment,
    List<String> checkInDays,
  ) async {
    final id = await db.habitDao.createHabit(
      userId: _userId,
      title: title,
      today: since,
      now: DateTime.utc(2026, 11, 1, 8),
      firstCommitment: commitment,
    );
    var minute = 0;
    for (final day in checkInDays) {
      await db.habitDao.addCheckIn(
        habitId: id,
        userId: _userId,
        countsForDay: day,
        now: DateTime.utc(2026, 11, 18, 8, minute++),
      );
    }
    return id;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    router.dispose();
    await db.close();
  });

  Future<void> openDetail(WidgetTester tester, String habitId) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(clock),
      ],
    );
    router = GoRouter(
      initialLocation: '/habits/$habitId',
      routes: [
        GoRoute(
          path: '/habits/:id',
          builder: (_, state) =>
              HabitDetailScreen(habitId: state.pathParameters['id']),
          routes: [
            GoRoute(
              path: 'calendar',
              builder: (_, state) =>
                  HabitCalendarScreen(habitId: state.pathParameters['id']!),
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

  String text(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(Key(key))).data!;

  /// The three tiles must read what the engine computes for the same history.
  void expectTilesMatchEngine(WidgetTester tester, String habitId) {
    final progress = computeHabitProgress(
      container.read(habitHistoryProvider(habitId))!,
      parseHabitDay('2026-11-18')!,
    );
    for (var i = 0; i < 3; i++) {
      final value = progress.rates[i].value;
      expect(
        text(tester, 'habit_stat_rate_$i'),
        value == null ? '—' : '${(value * 100).round()}%',
      );
    }
  }

  testWidgets('an every-day Habit shows day streak, best and 7/30/90 tiles', (
    tester,
  ) async {
    // 10-14 Nov done (5), 15 Nov missed, 16-18 Nov done (3, today counted).
    final id = await createHabit(
      'Read',
      '2026-11-10',
      const HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay),
      [
        '2026-11-10',
        '2026-11-11',
        '2026-11-12',
        '2026-11-13',
        '2026-11-14',
        '2026-11-16',
        '2026-11-17',
        '2026-11-18',
      ],
    );
    await openDetail(tester, id);

    expect(text(tester, 'habit_stat_streak'), '3');
    expect(text(tester, 'habit_stat_streak_label'), 'day streak');
    expect(text(tester, 'habit_stat_best'), '5');
    expect(find.byKey(const Key('habit_stat_period')), findsNothing);
    expect(text(tester, 'habit_stat_rate_label_0'), 'rate · 7 days');
    expect(text(tester, 'habit_stat_rate_label_1'), '30 days');
    expect(text(tester, 'habit_stat_rate_label_2'), '90 days');
    expectTilesMatchEngine(tester, id);
    await closeApp(tester);
  });

  testWidgets('a 3-a-week Habit shows week streak and this week so far', (
    tester,
  ) async {
    // Weeks of 2 and 9 Nov met 3 of 3; this week (from 16 Nov) has 1.
    final id = await createHabit(
      'Run',
      '2026-11-02',
      const HabitCommitmentDraft(
        repeatKind: HabitRepeatKind.timesPerWeek,
        timesPerPeriod: 3,
      ),
      [
        '2026-11-03',
        '2026-11-05',
        '2026-11-07',
        '2026-11-10',
        '2026-11-12',
        '2026-11-14',
        '2026-11-16',
      ],
    );
    await openDetail(tester, id);

    expect(text(tester, 'habit_stat_streak'), '2');
    expect(text(tester, 'habit_stat_streak_label'), 'week streak');
    expect(text(tester, 'habit_stat_best'), '2');
    expect(text(tester, 'habit_stat_period'), '1 of 3 this week');
    expect(text(tester, 'habit_stat_rate_label_0'), 'rate · 4 weeks');
    expect(text(tester, 'habit_stat_rate_label_1'), '12 weeks');
    expect(text(tester, 'habit_stat_rate_label_2'), '26 weeks');
    expectTilesMatchEngine(tester, id);
    await closeApp(tester);
  });

  testWidgets('a Habit with nothing to count shows a dash', (tester) async {
    final id = await createHabit(
      'Stretch',
      '2026-11-18',
      const HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay),
      const [],
    );
    await openDetail(tester, id);

    expect(text(tester, 'habit_stat_streak'), '0');
    for (var i = 0; i < 3; i++) {
      final shown = text(tester, 'habit_stat_rate_$i');
      expect(shown == '—' || shown.endsWith('%'), isTrue);
    }
    expectTilesMatchEngine(tester, id);
    await closeApp(tester);
  });

  testWidgets('tapping the strip opens the Check-in calendar', (tester) async {
    final id = await createHabit(
      'Read',
      '2026-11-10',
      const HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay),
      ['2026-11-17', '2026-11-18'],
    );
    await openDetail(tester, id);

    expect(find.byKey(const Key('habit_history_strip')), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Check-ins over the last five months')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('habit_history_strip')));
    await _settle(tester);

    expect(find.byType(HabitCalendarScreen), findsOneWidget);
    await closeApp(tester);
  });
}
