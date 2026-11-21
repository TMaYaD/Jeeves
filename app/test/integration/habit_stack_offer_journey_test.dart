/// Journey: the next-in-stack offer after a Check-in (#403).
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

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await _settle(tester);
  }

  Future<void> tapMark(WidgetTester tester, String id) =>
      tapKey(tester, 'habit_mark_$id');

  Future<void> follow(String habitId, String anchorId, HabitAnchorKind kind) =>
      db.habitDao.setAnchor(
        habitId: habitId,
        userId: _userId,
        today: wed,
        now: now,
        kind: kind,
        anchorHabitId: anchorId,
      );

  const water = HabitCommitmentDraft(
    repeatKind: HabitRepeatKind.everyDay,
    unitLabel: 'glasses',
    dailyTargetAmount: 8,
  );

  /// Stretch -> Water -> Journal.
  Future<({String stretch, String water, String journal})> seedStack({
    HabitCommitmentDraft waterCommitment = water,
  }) async {
    final stretch = await seed('Stretch');
    final waterId = await seed('Water', commitment: waterCommitment);
    final journal = await seed('Journal');
    await follow(waterId, stretch, HabitAnchorKind.afterHabit);
    await follow(journal, waterId, HabitAnchorKind.afterHabit);
    return (stretch: stretch, water: waterId, journal: journal);
  }

  Finder offerOn(String id) => find.byKey(Key('habit_offer_$id'));

  testWidgets('a Check-in offers the next Habit; Not now withdraws it and '
      'time does not', (tester) async {
    final ids = await seedStack();
    await openApp(tester);
    try {
      expect(offerOn(ids.water), findsNothing);
      await tapMark(tester, ids.stretch);
      expect(offerOn(ids.water), findsOneWidget);
      expect(find.text('Next in the order, sir.'), findsOneWidget);
      expect(
        find.text('Stretch is attended to. Shall I take the glasses?'),
        findsOneWidget,
      );
      expect(offerOn(ids.journal), findsNothing);

      await tester.pump(const Duration(minutes: 10));
      await _settle(tester);
      expect(offerOn(ids.water), findsOneWidget);

      await tapKey(tester, 'habit_offer_dismiss_${ids.water}');
      expect(offerOn(ids.water), findsNothing);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('undoing the source Check-in withdraws the offer', (tester) async {
    final ids = await seedStack();
    await openApp(tester);
    try {
      await tapMark(tester, ids.stretch);
      expect(offerOn(ids.water), findsOneWidget);
      await tapMark(tester, ids.stretch);
      expect(offerOn(ids.water), findsNothing);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a Habit not due today is skipped (AC 9)', (tester) async {
    // 2026-11-18 is a Wednesday (3); Water is due on Mondays only.
    final ids = await seedStack(
      waterCommitment: const HabitCommitmentDraft(
        repeatKind: HabitRepeatKind.chosenWeekdays,
        chosenWeekdays: [1],
      ),
    );
    await openApp(tester);
    try {
      await tapMark(tester, ids.stretch);
      expect(offerOn(ids.water), findsNothing);
      expect(offerOn(ids.journal), findsOneWidget);
      expect(find.text('Stretch is attended to.'), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a Habit anchored before Journal is offered ahead of it', (
    tester,
  ) async {
    final ids = await seedStack();
    final floss = await seed('Floss');
    await follow(floss, ids.journal, HabitAnchorKind.beforeHabit);
    await openApp(tester);
    try {
      await tapMark(tester, ids.water);
      // Water is measurable: its mark opens the sheet; reach the target.
      await tapKey(tester, 'habit_sheet_chip_4');
      await tapKey(tester, 'habit_sheet_chip_4');
      await tapKey(tester, 'habit_sheet_done');
      expect(offerOn(floss), findsOneWidget);
      expect(offerOn(ids.journal), findsNothing);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('"Right ho" checks in a binary Habit and offers the next one; '
      'the last in the stack offers nothing', (tester) async {
    final stretch = await seed('Stretch');
    final journal = await seed('Journal');
    final read = await seed('Read');
    await follow(journal, stretch, HabitAnchorKind.afterHabit);
    await follow(read, journal, HabitAnchorKind.afterHabit);
    await openApp(tester);
    try {
      await tapMark(tester, stretch);
      expect(offerOn(journal), findsOneWidget);
      await tapKey(tester, 'habit_offer_accept_$journal');
      expect(offerOn(journal), findsNothing);
      expect(inRow(journal, 'Done 09:30'), findsOneWidget);
      expect(offerOn(read), findsOneWidget);
      await tapKey(tester, 'habit_offer_accept_$read');
      expect(find.text('Next in the order, sir.'), findsNothing);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('"Right ho" on a measurable Habit opens its sheet, and reaching '
      'the target there offers the next Habit', (tester) async {
    final ids = await seedStack();
    await openApp(tester);
    try {
      await tapMark(tester, ids.stretch);
      await tapKey(tester, 'habit_offer_accept_${ids.water}');
      expect(find.byKey(const Key('habit_entry_sheet')), findsOneWidget);
      expect(find.text('Water'), findsWidgets);
      expect(find.byKey(const Key('habit_sheet_offer')), findsNothing);

      await tapKey(tester, 'habit_sheet_chip_4');
      await tapKey(tester, 'habit_sheet_chip_4');
      expect(find.text('Journal follows, sir.'), findsOneWidget);
      expect(find.text('Next in this stack \u00b7 not yet today'),
          findsOneWidget);

      await tapKey(tester, 'habit_offer_accept_${ids.journal}');
      expect(inRow(ids.journal, 'Done 09:30'), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });
}
