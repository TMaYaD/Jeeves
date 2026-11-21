/// Journey: the Habit list and detail (#402).
///
/// The real list and detail screens inside the real app shell, over a real
/// in-memory database. Live Drift streams run, so the test pumps bounded
/// frames instead of `pumpAndSettle`, and unmounts the tree inside the body
/// (TESTING.md).
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
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/app_shell.dart';
import 'package:jeeves/screens/habits/habit_detail_pane.dart';
import 'package:jeeves/screens/habits/habits_screen.dart';
import 'package:jeeves/widgets/tag_text.dart';

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
  final today = habitDayKey(DateTime.now());

  var seedCount = 0;
  Future<String> seed(String title,
      {HabitCommitmentDraft commitment = defaultNewHabitCommitment}) async {
    return db.habitDao.createHabit(
      userId: _userId,
      title: title,
      today: today,
      now: DateTime.now().add(Duration(milliseconds: seedCount++)),
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

  Future<void> openApp(WidgetTester tester, {Size? size}) async {
    tester.view.physicalSize = size ?? const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)]);
    router = GoRouter(initialLocation: '/habits', routes: [
      ShellRoute(
        builder: (_, _, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/habits', builder: (_, _) => const HabitsScreen()),
        ],
      ),
      GoRoute(
          path: '/habits/new',
          builder: (_, _) => const HabitDetailScreen(habitId: null)),
      GoRoute(
        path: '/habits/:id',
        builder: (_, state) => HabitDetailScreen(
          habitId: state.pathParameters['id']!,
          justCreated: state.uri.queryParameters['new'] == '1',
        ),
      ),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await _settle(tester);
  }

  Future<void> closeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => pumpEventQueue());
    container.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  Future<Habit?> habitTitled(WidgetTester tester, String title) async {
    final rows = await tester.runAsync(() => db.select(db.habits).get());
    return rows!.where((h) => h.title == title).firstOrNull;
  }

  testWidgets('an empty store shows the empty state and an Add button',
      (tester) async {
    await openApp(tester);
    try {
      expect(find.text('No Habits yet'), findsOneWidget);
      expect(find.byKey(const Key('habits_add')), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('the list shows stack order, then paused, then archived',
      (tester) async {
    final first = await seed('Wake up');
    final second = await seed('Stretch');
    await seed('Journal');
    final paused = await seed('Run');
    final archived = await seed('Guitar');
    await db.habitDao.setAnchor(
        habitId: second,
        userId: _userId,
        today: today,
        now: DateTime.now(),
        kind: HabitAnchorKind.afterHabit,
        anchorHabitId: first);
    await db.habitDao.pause(
        habitId: paused, userId: _userId, today: today, now: DateTime.now());
    await db.habitDao.archive(
        habitId: archived, userId: _userId, today: today, now: DateTime.now());
    await openApp(tester);
    try {
      double top(String title) => tester.getTopLeft(find.text(title)).dy;
      expect(top('Wake up'), lessThan(top('Stretch')));
      expect(top('Stretch'), lessThan(top('Run')));
      expect(top('Run'), lessThan(top('Guitar')));
      expect(find.text('PAUSED'), findsOneWidget);
      expect(find.text('ARCHIVED'), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a list of only paused or archived Habits says so',
      (tester) async {
    final id = await seed('Run');
    await db.habitDao.pause(
        habitId: id, userId: _userId, today: today, now: DateTime.now());
    await openApp(tester);
    try {
      expect(find.byKey(const Key('habits_only_inactive')), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('Habits is in the side menu', (tester) async {
    await openApp(tester);
    try {
      final scaffold = tester.firstState<ScaffoldState>(find.byType(Scaffold));
      scaffold.openDrawer();
      await _settle(tester);
      expect(find.text('Habits'), findsWidgets);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('going back from a new Habit with no title writes nothing',
      (tester) async {
    await openApp(tester);
    try {
      await tester.tap(find.byKey(const Key('habits_add')));
      await _settle(tester);
      expect(find.byKey(const Key('habit_title')), findsOneWidget);
      await tester.pageBack();
      await _settle(tester);
      final rows = await tester.runAsync(() => db.select(db.habits).get());
      expect(rows, isEmpty);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets(
      'a new Habit takes its title, Area and Label in one write, '
      'with the every-day binary commitment', (tester) async {
    await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('area-home'),
        name: const Value('Home'),
        type: const Value('area'),
        userId: const Value(_userId)));
    await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('ctx-errands'),
        name: const Value('Errands'),
        type: const Value('context'),
        userId: const Value(_userId)));
    await openApp(tester);
    try {
      await tester.tap(find.byKey(const Key('habits_add')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('habit_row_labels')));
      await _settle(tester);
      await tester.tap(find.byWidgetPredicate(
          (w) => w is TagText && w.tag.name == 'Errands'));
      await _settle(tester);
      await tester.tapAt(const Offset(5, 5));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('habit_title')), 'Drink water');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settle(tester, 10);

      final habit = await habitTitled(tester, 'Drink water');
      expect(habit, isNotNull);
      final commitments = await tester
          .runAsync(() => db.habitDao.commitmentsFor(habit!.id));
      expect(commitments, hasLength(1));
      expect(commitments!.single.repeatKind, HabitRepeatKind.everyDay);
      expect(commitments.single.isMeasurable, isFalse);
      final tags = await tester.runAsync(() => db.habitDao.tagsFor(habit!.id));
      expect(tags!.map((t) => t.name), ['Errands']);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('clearing an existing title is refused and the title stays',
      (tester) async {
    final id = await seed('Read');
    await openApp(tester);
    try {
      await tester.tap(find.byKey(Key('habit_row_$id')));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('habit_title')), '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settle(tester);
      final habit = await tester.runAsync(() => db.habitDao.habitById(id));
      expect(habit!.title, 'Read');
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('Repeat sheet: N = 40 times a month saves; Cancel changes nothing',
      (tester) async {
    final id = await seed('Read');
    await openApp(tester);
    try {
      await tester.tap(find.byKey(Key('habit_row_$id')));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('habit_row_repeat')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('repeat_times_per_month')));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('repeat_count')), '40');
      await tester.pump();
      await tester.tap(find.byKey(const Key('habit_sheet_cancel')));
      await _settle(tester);
      var commitments =
          await tester.runAsync(() => db.habitDao.commitmentsFor(id));
      expect(commitments, hasLength(1));

      await tester.tap(find.byKey(const Key('habit_row_repeat')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('repeat_times_per_month')));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('repeat_count')), '40');
      await tester.pump();
      await tester.tap(find.byKey(const Key('habit_sheet_done')));
      await _settle(tester);
      commitments = await tester.runAsync(() => db.habitDao.commitmentsFor(id));
      expect(commitments, hasLength(2));
      expect(commitments!.last.repeatKind, HabitRepeatKind.timesPerMonth);
      expect(commitments.last.timesPerPeriod, 40);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a measured Check-in without a unit cannot press Done',
      (tester) async {
    final id = await seed('Read');
    await openApp(tester);
    try {
      await tester.tap(find.byKey(Key('habit_row_$id')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('habit_row_checkin')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('checkin_kind_measurable')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('checkin_target')), '10');
      await tester.pump();
      final done = tester.widget<FilledButton>(
          find.byKey(const Key('habit_sheet_done')));
      expect(done.onPressed, isNull);
      await tester.enterText(find.byKey(const Key('checkin_unit')), 'pages');
      await tester.pump();
      await tester.tap(find.byKey(const Key('habit_sheet_done')));
      await _settle(tester);
      final commitments =
          await tester.runAsync(() => db.habitDao.commitmentsFor(id));
      expect(commitments!.last.unitLabel, 'pages');
      expect(commitments.last.dailyTargetAmount, 10);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('the Anchor sheet does not offer a Habit that would close a loop',
      (tester) async {
    final a = await seed('A');
    final b = await seed('B');
    await db.habitDao.setAnchor(
        habitId: b,
        userId: _userId,
        today: today,
        now: DateTime.now(),
        kind: HabitAnchorKind.afterHabit,
        anchorHabitId: a);
    await openApp(tester);
    try {
      await tester.tap(find.byKey(Key('habit_row_$a')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('habit_row_anchor')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('anchor_after_habit')));
      await _settle(tester);
      expect(find.byKey(Key('anchor_candidate_$b')), findsNothing);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets(
      'pause, resume, archive and restore keep everything and show banners',
      (tester) async {
    final id = await seed('Read');
    await db.habitDao.addCheckIn(
        habitId: id,
        userId: _userId,
        countsForDay: today,
        now: DateTime.now());
    await openApp(tester);
    try {
      await tester.tap(find.byKey(Key('habit_row_$id')));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('habit_pause')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('habit_sheet_done')));
      await _settle(tester);
      expect(find.byKey(const Key('habit_flash_banner')), findsOneWidget);
      expect(find.byKey(const Key('habit_resume')), findsOneWidget);

      await tester.tap(find.byKey(const Key('habit_resume')));
      await _settle(tester);
      expect(find.byKey(const Key('habit_pause')), findsOneWidget);

      await tester.tap(find.byKey(const Key('habit_archive')));
      await _settle(tester);
      expect(find.byKey(const Key('habit_restore')), findsOneWidget);
      expect(find.byKey(const Key('habit_flash_banner')), findsOneWidget);

      await tester.tap(find.byKey(const Key('habit_restore')));
      await _settle(tester);
      expect(find.byKey(const Key('habit_archive')), findsOneWidget);

      final checkIns = await tester.runAsync(() => db.select(db.habitCheckIns).get());
      expect(checkIns, hasLength(1));
      final rows = await tester.runAsync(() => db.select(db.habits).get());
      expect(rows, hasLength(1));
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('at 1440 wide the list and detail sit side by side',
      (tester) async {
    final a = await seed('Alpha');
    final b = await seed('Beta');
    await openApp(tester, size: const Size(1440, 900));
    try {
      await tester.tap(find.byKey(Key('habit_row_$a')));
      await _settle(tester);
      expect(find.byKey(const Key('habit_title')), findsOneWidget);
      expect(find.byKey(Key('habit_row_$b')), findsOneWidget);
      final titleField = tester.widget<TextField>(find.byKey(const Key('habit_title')));
      expect(titleField.controller!.text, 'Alpha');

      await tester.tap(find.byKey(Key('habit_row_$b')));
      await _settle(tester);
      final next = tester.widget<TextField>(find.byKey(const Key('habit_title')));
      expect(next.controller!.text, 'Beta');
      expect(router.state.uri.path, '/habits');
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('the list and detail render under a dark theme', (tester) async {
    final a = await seed('Alpha');
    await openApp(tester);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: ThemeData(brightness: Brightness.dark),
        ),
      ));
      await _settle(tester);
      await tester.tap(find.byKey(Key('habit_row_$a')));
      await _settle(tester);
      expect(find.byKey(const Key('habit_title')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await closeApp(tester);
    }
  });
}
