/// Journey: Evening Shutdown asks about the Habits still open for the day being
/// closed, after Resolve Unfinished (#405). Real screen, real in-memory store;
/// only the database and the clock are overridden.
///
/// Per docs/TESTING.md the store is staged in `setUp` and read inside a test
/// body only through `tester.runAsync`.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
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
import 'package:jeeves/screens/shutdown/shutdown_ritual_screen.dart';

import '../helpers/settle.dart';
import '../test_helpers.dart';

const _userId = 'local';
const _nextStep = Key('shutdown_next_step');
const _skip = Key('shutdown_skip');

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;
  late String stretchId;
  late String waterId;

  Future<void> insertOutcome(DateTime at) async {
    await db.into(db.todos).insert(TodosCompanion(
          id: const Value('t1'),
          title: const Value('Outcome t1'),
          intent: const Value('next'),
          userId: const Value(_userId),
          createdAt: Value(at),
          updatedAt: Value(at),
        ));
    await seedCurrentAction(db,
        outcomeId: 't1', text: 'work on t1', userId: _userId);
  }

  Future<String> createHabit(String title, HabitCommitmentDraft draft) =>
      db.habitDao.createHabit(
        userId: _userId,
        title: title,
        today: '2026-11-10',
        now: DateTime.utc(2026, 11, 10, 8),
        firstCommitment: draft,
      );

  /// Stages a session started at [sessionStart] with one unfinished Outcome
  /// and the Habits [withHabits] asks for.
  void scenario(
    String name, {
    required DateTime sessionStart,
    required DateTime clock,
    bool withHabits = true,
    required void Function(DateTime clock) body,
  }) {
    group(name, () {
      setUp(() async {
        SharedPreferences.setMockInitialValues({});
        db = GtdDatabase(NativeDatabase.memory());
        await insertOutcome(sessionStart);
        await db.focusSessionDao.openSession(
            userId: _userId, taskIds: ['t1'], now: sessionStart);
        if (withHabits) {
          stretchId = await createHabit('Stretch',
              const HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay));
          waterId = await createHabit(
              'Water',
              const HabitCommitmentDraft(
                repeatKind: HabitRepeatKind.everyDay,
                unitLabel: 'glasses',
                dailyTargetAmount: 8,
              ));
        }
      });
      tearDown(() async => db.close());
      body(clock);
    });
  }

  Future<void> mount(WidgetTester tester, DateTime clock) async {
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => clock),
    ]);
    final router = GoRouter(
      initialLocation: '/shutdown',
      routes: [
        GoRoute(
          path: '/focus',
          builder: (_, _) => const Scaffold(body: Text('execution home')),
        ),
        GoRoute(
          path: '/shutdown',
          builder: (_, _) => const ShutdownRitualScreen(),
        ),
      ],
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await settleWithRealAsync(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.runAsync(() async => container.dispose());
  }

  /// Review → Resolve Unfinished → (roll the Outcome over) → what comes next.
  Future<void> throughResolveUnfinished(WidgetTester tester) async {
    await tester.tap(find.byKey(_nextStep));
    await settleWithRealAsync(tester);
    await tester.tap(find.text('Roll Over to Tomorrow'));
    await settleWithRealAsync(tester, rounds: 2);
  }

  Future<List<HabitCheckIn>> checkIns(
      WidgetTester tester, String habitId) async {
    final rows = await tester.runAsync(
        () => db.habitDao.checkInsFor(habitId, '2026-11-01', '2026-11-30'));
    return rows!;
  }

  Future<void> tapAddOnWater(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(Key('shutdown_habit_add_$waterId')));
    await tester.tap(find.byKey(Key('shutdown_habit_add_$waterId')));
    await settleWithRealAsync(tester, rounds: 2);
  }

  final evening = DateTime(2026, 11, 18, 21);

  scenario('open Habits after Resolve Unfinished',
      sessionStart: evening, clock: evening, body: (clock) {
    testWidgets('the step lists both, and toggling a binary Habit writes and '
        'takes back one Check-in for the closing day', (tester) async {
      await mount(tester, clock);
      await throughResolveUnfinished(tester);

      expect(find.byKey(Key('shutdown_habit_row_$stretchId')), findsOneWidget);
      expect(find.byKey(Key('shutdown_habit_row_$waterId')), findsOneWidget);
      expect(find.text('Step 3 of 3'), findsOneWidget);

      await tester.tap(find.byKey(Key('shutdown_habit_toggle_$stretchId')));
      await settleWithRealAsync(tester, rounds: 2);
      final on = await checkIns(tester, stretchId);
      expect(on.map((c) => c.countsForDay), ['2026-11-18']);
      // The row stays in place after its Check-in.
      expect(find.byKey(Key('shutdown_habit_row_$stretchId')), findsOneWidget);

      await tester.tap(find.byKey(Key('shutdown_habit_toggle_$stretchId')));
      await settleWithRealAsync(tester, rounds: 2);
      expect(await checkIns(tester, stretchId), isEmpty);

      await unmount(tester);
    });

    testWidgets('entering 3 on the measurable Habit writes one Check-in of 3',
        (tester) async {
      await mount(tester, clock);
      await throughResolveUnfinished(tester);

      await tester.ensureVisible(find.byIcon(Icons.add).first);
      // Two taps on More: 1 → 3.
      await tester.tap(find.descendant(
          of: find.byKey(Key('shutdown_habit_row_$waterId')),
          matching: find.byIcon(Icons.add)));
      await tester.tap(find.descendant(
          of: find.byKey(Key('shutdown_habit_row_$waterId')),
          matching: find.byIcon(Icons.add)));
      await tester.pump();
      await tapAddOnWater(tester);

      final entries = await checkIns(tester, waterId);
      expect(entries.map((c) => c.measuredAmount), [3.0]);
      expect(entries.map((c) => c.countsForDay), ['2026-11-18']);
      expect(find.text('3 of 8 glasses'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a Habit left alone gets no Check-in, and the footer shows '
        'Skip, then Next step once both have one, never both', (tester) async {
      await mount(tester, clock);
      await throughResolveUnfinished(tester);

      expect(find.byKey(_skip), findsOneWidget);
      expect(find.byKey(_nextStep), findsNothing);

      await tester.tap(find.byKey(Key('shutdown_habit_toggle_$stretchId')));
      await settleWithRealAsync(tester, rounds: 2);
      expect(find.byKey(_skip), findsOneWidget);
      expect(find.byKey(_nextStep), findsNothing);

      await tapAddOnWater(tester);
      expect(find.byKey(_nextStep), findsOneWidget);
      expect(find.byKey(_skip), findsNothing);

      await unmount(tester);
    });

    testWidgets('skipping leaves a Habit with no Check-in (AC 2) and goes '
        'to Close Day', (tester) async {
      await mount(tester, clock);
      await throughResolveUnfinished(tester);

      await tester.tap(find.byKey(Key('shutdown_habit_toggle_$stretchId')));
      await settleWithRealAsync(tester, rounds: 2);
      await tester.tap(find.byKey(_skip));
      await settleWithRealAsync(tester, rounds: 2);
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('Close Day'), findsWidgets);
      await tester.tap(find.text('Close Day'));
      await settleWithRealAsync(tester);
      expect(await checkIns(tester, waterId), isEmpty);
      expect(await checkIns(tester, stretchId), hasLength(1));

      await unmount(tester);
    });
  });

  scenario('every Habit already done',
      sessionStart: evening, clock: evening, body: (clock) {
    testWidgets('the flow goes from Resolve Unfinished to Close Day, "of 2"',
        (tester) async {
      await tester.runAsync(() async {
        await db.habitDao.addCheckIn(
            habitId: stretchId,
            userId: _userId,
            countsForDay: '2026-11-18',
            now: evening.toUtc());
        await db.habitDao.addCheckIn(
            habitId: waterId,
            userId: _userId,
            countsForDay: '2026-11-18',
            measuredAmount: 8,
            now: evening.toUtc());
      });
      await mount(tester, clock);
      expect(find.text('Step 1 of 2'), findsOneWidget);

      await throughResolveUnfinished(tester);
      await tester.pump(const Duration(seconds: 2));

      expect(find.byKey(Key('shutdown_habit_row_$stretchId')), findsNothing);
      expect(find.text('Close Day'), findsWidgets);

      await unmount(tester);
    });
  });

  scenario('no Habits at all',
      sessionStart: evening,
      clock: evening,
      withHabits: false,
      body: (clock) {
    testWidgets('Resolve Unfinished goes straight to Close Day, "of 2"',
        (tester) async {
      await mount(tester, clock);
      expect(find.text('Step 1 of 2'), findsOneWidget);

      await throughResolveUnfinished(tester);
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('Close Day'), findsWidgets);

      await unmount(tester);
    });
  });

  scenario('after midnight',
      sessionStart: evening, clock: DateTime(2026, 11, 19, 0, 20),
      body: (clock) {
    testWidgets('the Check-in counts for yesterday and the header names it',
        (tester) async {
      await mount(tester, clock);
      await throughResolveUnfinished(tester);

      expect(find.text('Closing Wednesday, 18 November'), findsOneWidget);
      await tester.tap(find.byKey(Key('shutdown_habit_toggle_$stretchId')));
      await settleWithRealAsync(tester, rounds: 2);

      final entries = await checkIns(tester, stretchId);
      expect(entries.map((c) => c.countsForDay), ['2026-11-18']);

      await unmount(tester);
    });
  });
}
