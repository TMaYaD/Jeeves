/// Journey: checking in a Habit from its row and from the detail's Today card (#403).
///
/// The real list and detail screens inside the real app shell, over a real
/// in-memory database. Live Drift streams run, so the test pumps bounded
/// frames instead of `pumpAndSettle`, and unmounts the tree inside the body
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
import 'package:jeeves/providers/habit_check_ins_provider.dart';
import 'package:jeeves/screens/app_shell.dart';
import 'package:jeeves/screens/habits/habit_detail_pane.dart';
import 'package:jeeves/screens/habits/habits_screen.dart';

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
  // Wednesday 18 Nov 2026, 09:30 local.
  final now = DateTime(2026, 11, 18, 9, 30);
  const mon = '2026-11-16';
  const tue = '2026-11-17';
  const wed = '2026-11-18';

  var seedCount = 0;
  Future<String> seed(
    String title, {
    HabitCommitmentDraft commitment = defaultNewHabitCommitment,
    String chosenOn = mon,
  }) {
    return db.habitDao.createHabit(
      userId: _userId,
      title: title,
      today: chosenOn,
      now: now.subtract(Duration(days: 5, milliseconds: seedCount++)),
      firstCommitment: commitment,
    );
  }

  Future<void> checkInOn(WidgetTester tester, String id, String day) async {
    await tester.runAsync(
      () => db.habitDao.addCheckIn(
        habitId: id,
        userId: _userId,
        countsForDay: day,
        now: DateTime.parse('${day}T08:00:00'),
      ),
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    router.dispose();
    await db.close();
  });

  Future<void> openApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(() => now),
      ],
    );
    router = GoRouter(
      initialLocation: '/habits',
      routes: [
        ShellRoute(
          builder: (_, _, child) => AppShell(child: child),
          routes: [
            GoRoute(path: '/habits', builder: (_, _) => const HabitsScreen()),
          ],
        ),
        GoRoute(
          path: '/habits/:id',
          builder: (_, state) =>
              HabitDetailScreen(habitId: state.pathParameters['id']!),
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

  Finder inRow(String id, String text) => find.descendant(
    of: find.byKey(Key('habit_row_$id')),
    matching: find.text(text),
  );

  Future<void> tapMark(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(Key('habit_mark_$id')));
    await _settle(tester);
  }

  testWidgets('an every-day Habit is checked in and taken back from its row', (
    tester,
  ) async {
    final id = await seed('Floss');
    await checkInOn(tester, id, tue);
    await openApp(tester);
    try {
      expect(inRow(id, 'Not yet'), findsOneWidget);
      expect(inRow(id, '1'), findsOneWidget);
      expect(inRow(id, 'day streak'), findsOneWidget);
      expect(find.bySemanticsLabel('Check in: Floss'), findsOneWidget);

      await tapMark(tester, id);
      expect(inRow(id, 'Done 09:30'), findsOneWidget);
      expect(inRow(id, '2'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Floss: checked in. Tap to undo'),
        findsOneWidget,
      );

      await tapMark(tester, id);
      expect(inRow(id, 'Not yet'), findsOneWidget);
      expect(inRow(id, '1'), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a 3-a-week Habit counts the week and never adds a second', (
    tester,
  ) async {
    final id = await seed(
      'Run',
      commitment: const HabitCommitmentDraft(
        repeatKind: HabitRepeatKind.timesPerWeek,
        timesPerPeriod: 3,
      ),
    );
    await checkInOn(tester, id, mon);
    await openApp(tester);
    try {
      expect(inRow(id, '1 of 3 this week'), findsOneWidget);
      expect(inRow(id, 'week streak'), findsOneWidget);
      await tapMark(tester, id);
      expect(inRow(id, '2 of 3 this week'), findsOneWidget);
      await tapMark(tester, id);
      expect(inRow(id, '1 of 3 this week'), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('with two Check-ins today one tap on the mark removes one', (
    tester,
  ) async {
    final id = await seed(
      'Run',
      commitment: const HabitCommitmentDraft(
        repeatKind: HabitRepeatKind.timesPerWeek,
        timesPerPeriod: 3,
      ),
    );
    await openApp(tester);
    try {
      await tester.runAsync(() async {
        final actions = container.read(habitCheckInsProvider.notifier);
        await actions.checkIn(id);
        await actions.checkIn(id);
      });
      await _settle(tester);
      expect(inRow(id, '2 of 3 this week'), findsOneWidget);
      await tapMark(tester, id);
      expect(inRow(id, '1 of 3 this week'), findsOneWidget);
      expect(inRow(id, 'Done 09:30'), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a met 3-a-week Habit reads complete and ignores taps', (
    tester,
  ) async {
    final id = await seed(
      'Run',
      commitment: const HabitCommitmentDraft(
        repeatKind: HabitRepeatKind.timesPerWeek,
        timesPerPeriod: 3,
      ),
    );
    await checkInOn(tester, id, mon);
    await checkInOn(tester, id, tue);
    await checkInOn(tester, id, tue);
    await openApp(tester);
    try {
      expect(inRow(id, 'Complete for this week'), findsOneWidget);
      await tapMark(tester, id);
      expect(inRow(id, 'Complete for this week'), findsOneWidget);
      final rows = await tester.runAsync(
        () => db.habitDao.checkInsFor(id, mon, wed),
      );
      expect(rows, hasLength(3));
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('the detail\'s Today card shows the state and its mark undoes', (
    tester,
  ) async {
    final id = await seed('Floss');
    await openApp(tester);
    try {
      await tester.tap(find.text('Floss'));
      await _settle(tester);
      expect(find.text('Today · Wed 18 Nov'), findsOneWidget);
      expect(find.text('Not yet'), findsWidgets);
      await tester.tap(find.byKey(Key('habit_mark_${id}_today')));
      await _settle(tester);
      expect(
        find.text('Done 09:30 · tap the mark to undo'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Checked in today. Tap to undo'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(Key('habit_mark_${id}_today')));
      await _settle(tester);
      expect(find.text('Done 09:30 · tap the mark to undo'), findsNothing);
    } finally {
      await closeApp(tester);
    }
  });

  group('the measurable entry sheet', () {
    Future<String> seedWater() => seed(
      'Water',
      commitment: const HabitCommitmentDraft(
        repeatKind: HabitRepeatKind.everyDay,
        unitLabel: 'glasses',
        dailyTargetAmount: 8,
      ),
    );

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(Key(key)));
      await _settle(tester);
    }

    String sheetTotal(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('habit_sheet_total'))).data!;

    testWidgets('entries add up to the target and past it', (tester) async {
      final id = await seedWater();
      await openApp(tester);
      try {
        expect(inRow(id, '0 of 8 glasses'), findsOneWidget);
        await tapMark(tester, id);
        expect(find.text('HABIT · CHECK-IN'), findsOneWidget);
        expect(find.text('Today · Wed 18 Nov · each entry adds to the day'),
            findsOneWidget);

        await tester.tap(find.byTooltip('More'));
        await tester.tap(find.byTooltip('More'));
        await tester.pump();
        expect(find.byKey(const Key('habit_sheet_stepper')), findsOneWidget);
        await tapKey(tester, 'habit_sheet_add');
        expect(sheetTotal(tester), '3');
        expect(find.text('5 to go'), findsOneWidget);
        expect(inRow(id, '3 of 8 glasses'), findsOneWidget);

        await tapKey(tester, 'habit_sheet_chip_4');
        expect(sheetTotal(tester), '7');
        await tapKey(tester, 'habit_sheet_add');
        expect(sheetTotal(tester), '8');
        expect(find.text('Target reached'), findsOneWidget);
        expect(inRow(id, '8 of 8 glasses'), findsOneWidget);

        await tapKey(tester, 'habit_sheet_chip_2');
        expect(find.text('2 over. It all counts.'), findsOneWidget);
        expect(find.text('+2'), findsWidgets);
        await tapKey(tester, 'habit_sheet_done');
        expect(find.byKey(const Key('habit_entry_sheet')), findsNothing);
        expect(inRow(id, '10 of 8 glasses'), findsOneWidget);
      } finally {
        await closeApp(tester);
      }
    });

    testWidgets('removing and changing an entry lower the total', (
      tester,
    ) async {
      final id = await seedWater();
      await openApp(tester);
      try {
        // Inserted out of order: the sheet lists them oldest first.
        for (final (time, amount) in [('08:20', 2.0), ('08:10', 4.0)]) {
          await tester.runAsync(
            () => db.habitDao.addCheckIn(
              habitId: id,
              userId: _userId,
              countsForDay: wed,
              now: DateTime.parse('${wed}T$time:00'),
              measuredAmount: amount,
            ),
          );
        }
        await tapMark(tester, id);
        expect(sheetTotal(tester), '6');
        expect(
          tester.getTopLeft(find.text('4 glasses')).dy,
          lessThan(tester.getTopLeft(find.text('2 glasses')).dy),
        );

        await tester.tap(find.byTooltip('Remove this Check-in').first);
        await _settle(tester);
        expect(sheetTotal(tester), '2');

        await tester.tap(find.byTooltip('Change this value'));
        await _settle(tester);
        await tester.tap(find.byTooltip('Less').last);
        await _settle(tester);
        expect(sheetTotal(tester), '1');
        expect(inRow(id, '1 of 8 glasses'), findsOneWidget);
      } finally {
        await closeApp(tester);
      }
    });

    testWidgets('Less is disabled at 1 and pips are absent for a target of 20', (
      tester,
    ) async {
      final id = await seed(
        'Read',
        commitment: const HabitCommitmentDraft(
          repeatKind: HabitRepeatKind.everyDay,
          unitLabel: 'pages',
          dailyTargetAmount: 20,
        ),
      );
      await openApp(tester);
      try {
        await tapMark(tester, id);
        final less = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.remove),
        );
        expect(less.onPressed, isNull);
        expect(find.byKey(const Key('habit_sheet_pips')), findsNothing);
      } finally {
        await closeApp(tester);
      }
    });
  });
}
