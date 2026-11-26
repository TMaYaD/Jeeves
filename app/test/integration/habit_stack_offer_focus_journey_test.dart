/// Journey: "Right ho" starts Focus Mode on a Habit with an estimate (#405).
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
import 'package:jeeves/screens/habits/habit_focus_screen.dart';
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

  Future<void> setEstimate(String id, String title, int? estimate) =>
      db.habitDao.updateHabitDetails(
        habitId: id,
        userId: _userId,
        title: title,
        notes: null,
        energyLevel: null,
        timeEstimateMinutes: estimate,
        now: now,
      );

  var seedCount = 0;
  Future<String> seed(
    String title, {
    HabitCommitmentDraft commitment = defaultNewHabitCommitment,
    String chosenOn = mon,
    int? estimate,
  }) async {
    final id = await db.habitDao.createHabit(
      userId: _userId,
      title: title,
      today: chosenOn,
      now: now.subtract(Duration(days: 5, milliseconds: seedCount++)),
      firstCommitment: commitment,
    );
    if (estimate != null) await setEstimate(id, title, estimate);
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
          path: '/habits/:id/focus',
          builder: (_, state) =>
              HabitFocusScreen(habitId: state.pathParameters['id']!),
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

  Finder doneInRow(String id) => find.descendant(
    of: find.byKey(Key('habit_row_$id')),
    matching: find.textContaining('Done 09:30'),
  );

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await _settle(tester);
  }

  Future<void> follow(String habitId, String anchorId) => db.habitDao.setAnchor(
        habitId: habitId,
        userId: _userId,
        today: wed,
        now: now,
        kind: HabitAnchorKind.afterHabit,
        anchorHabitId: anchorId,
      );

  Finder offerOn(String id) => find.byKey(Key('habit_offer_$id'));

  Future<List<HabitCheckIn>> checkInsOf(WidgetTester tester, String id) async =>
      (await tester.runAsync(() => (db.select(db.habitCheckIns)
                ..where((c) => c.habitId.equals(id)))
              .get()))!;

  const water = HabitCommitmentDraft(
    repeatKind: HabitRepeatKind.everyDay,
    unitLabel: 'glasses',
    dailyTargetAmount: 8,
  );
  const read = HabitCommitmentDraft(
    repeatKind: HabitRepeatKind.everyDay,
    unitLabel: 'pages',
    dailyTargetAmount: 20,
  );

  /// Stretch (binary) -> Meditate (binary, 10m) -> Journal (binary), and a
  /// second stack Water (measurable) -> Read (measurable, 30m).
  Future<({String stretch, String meditate, String journal, String water, String read})>
      seedStacks() async {
    final stretch = await seed('Stretch');
    final meditate = await seed('Meditate', estimate: 10);
    final journal = await seed('Journal');
    final waterId = await seed('Water', commitment: water);
    final readId = await seed('Read', commitment: read, estimate: 30);
    await follow(meditate, stretch);
    await follow(journal, meditate);
    await follow(readId, waterId);
    return (
      stretch: stretch,
      meditate: meditate,
      journal: journal,
      water: waterId,
      read: readId,
    );
  }

  Future<void> rightHoOnMeditate(
      WidgetTester tester, ({String stretch, String meditate, String journal, String water, String read}) ids) async {
    await tapKey(tester, 'habit_mark_${ids.stretch}');
    expect(offerOn(ids.meditate), findsOneWidget);
    await tapKey(tester, 'habit_offer_accept_${ids.meditate}');
  }

  testWidgets('"Right ho" on a Habit with an estimate opens its Focus and '
      'writes no Check-in', (tester) async {
    final ids = await seedStacks();
    await openApp(tester);
    try {
      await rightHoOnMeditate(tester, ids);
      expect(find.text('HABIT · FOCUS MODE'), findsOneWidget);
      expect(find.text('Meditate'), findsOneWidget);
      expect(await checkInsOf(tester, ids.meditate), isEmpty);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('Stop then Very good checks the Habit in and offers the next '
      'one (D10)', (tester) async {
    final ids = await seedStacks();
    await openApp(tester);
    try {
      await rightHoOnMeditate(tester, ids);
      await tapKey(tester, 'habit_focus_stop');
      await tapKey(tester, 'habit_focus_check_in_yes');

      expect(find.text('HABIT · FOCUS MODE'), findsNothing);
      expect(doneInRow(ids.meditate), findsOneWidget);
      expect(offerOn(ids.journal), findsOneWidget);
      expect(await checkInsOf(tester, ids.meditate), hasLength(1));
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('Stop then Not now writes no Check-in and offers nothing',
      (tester) async {
    final ids = await seedStacks();
    await openApp(tester);
    try {
      await rightHoOnMeditate(tester, ids);
      await tapKey(tester, 'habit_focus_stop');
      await tapKey(tester, 'habit_focus_check_in_not_now');

      expect(await checkInsOf(tester, ids.meditate), isEmpty);
      expect(find.text('Next in the order, sir.'), findsNothing);
      expect(offerOn(ids.journal), findsNothing);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a measurable Habit with an estimate opens Focus from the '
      'entry sheet and nothing is written for it (D9)', (tester) async {
    final ids = await seedStacks();
    await openApp(tester);
    try {
      await tapKey(tester, 'habit_mark_${ids.water}');
      await tapKey(tester, 'habit_sheet_chip_4');
      await tapKey(tester, 'habit_sheet_chip_4');
      expect(find.byKey(const Key('habit_entry_sheet')), findsOneWidget);
      await tapKey(tester, 'habit_offer_accept_${ids.read}_sheet');

      expect(find.byKey(const Key('habit_entry_sheet')), findsNothing);
      expect(find.text('HABIT · FOCUS MODE'), findsOneWidget);
      expect(find.text('Read'), findsOneWidget);
      expect(await checkInsOf(tester, ids.read), isEmpty);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('with the estimate removed, "Right ho" checks the Habit in at '
      'once and offers the next one', (tester) async {
    final ids = await seedStacks();
    await setEstimate(ids.meditate, 'Meditate', null);
    await openApp(tester);
    try {
      await rightHoOnMeditate(tester, ids);
      expect(find.text('HABIT · FOCUS MODE'), findsNothing);
      expect(doneInRow(ids.meditate), findsOneWidget);
      expect(offerOn(ids.journal), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });
}
