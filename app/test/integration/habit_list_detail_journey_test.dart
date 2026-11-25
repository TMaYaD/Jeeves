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
import 'package:jeeves/models/estimate.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/habit_progress_provider.dart';
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
  Future<String> seed(
    String title, {
    HabitCommitmentDraft commitment = defaultNewHabitCommitment,
  }) async {
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

  Future<void> openApp(
    WidgetTester tester, {
    Size? size,
    String initial = '/habits',
    DateTime Function()? clock,
  }) async {
    tester.view.physicalSize = size ?? const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        if (clock != null) clockProvider.overrideWithValue(clock),
      ],
    );
    router = GoRouter(
      initialLocation: initial,
      routes: [
        ShellRoute(
          builder: (_, _, child) => AppShell(child: child),
          routes: [
            GoRoute(path: '/habits', builder: (_, _) => const HabitsScreen()),
            GoRoute(
              path: '/next',
              builder: (_, _) => const Center(child: Text('Next list')),
            ),
          ],
        ),
        GoRoute(
          path: '/habits/new',
          builder: (_, _) => const HabitDetailScreen(habitId: null),
        ),
        GoRoute(
          path: '/habits/:id',
          builder: (_, state) => HabitDetailScreen(
            habitId: state.pathParameters['id']!,
            justCreated: state.uri.queryParameters['new'] == '1',
          ),
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

  Future<Habit?> habitTitled(WidgetTester tester, String title) async {
    final rows = await tester.runAsync(() => db.select(db.habits).get());
    return rows!.where((h) => h.title == title).firstOrNull;
  }

  testWidgets('an empty store shows the empty state and an Add button', (
    tester,
  ) async {
    await openApp(tester);
    try {
      expect(find.text('No Habits yet'), findsOneWidget);
      expect(find.byKey(const Key('habits_add')), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('the list shows stack order, then paused, then archived', (
    tester,
  ) async {
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
      anchorHabitId: first,
    );
    await db.habitDao.pause(
      habitId: paused,
      userId: _userId,
      today: today,
      now: DateTime.now(),
    );
    await db.habitDao.archive(
      habitId: archived,
      userId: _userId,
      today: today,
      now: DateTime.now(),
    );
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

  testWidgets('a list of only paused or archived Habits says so', (
    tester,
  ) async {
    final id = await seed('Run');
    await db.habitDao.pause(
      habitId: id,
      userId: _userId,
      today: today,
      now: DateTime.now(),
    );
    await openApp(tester);
    try {
      expect(find.byKey(const Key('habits_only_inactive')), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('Habits is in the side menu and is not an Outcome list', (
    tester,
  ) async {
    await seed('Floss');
    await openApp(tester, initial: '/next');
    try {
      expect(find.text('Next list'), findsOneWidget);
      expect(find.text('Floss'), findsNothing);
      expect(find.byKey(const Key('habits_add')), findsNothing);
      tester.firstState<ScaffoldState>(find.byType(Scaffold)).openDrawer();
      await _settle(tester);
      await tester.tap(
        find.descendant(of: find.byType(Drawer), matching: find.text('Habits')),
      );
      await _settle(tester);
      expect(find.byKey(const Key('habits_add')), findsOneWidget);
      expect(find.text('Floss'), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('going back from a new Habit with no title writes nothing', (
    tester,
  ) async {
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

  testWidgets('a new Habit takes its title, Area and Label in one write, '
      'with the every-day binary commitment', (tester) async {
    await db.tagDao.upsertTag(
      TagsCompanion(
        id: const Value('area-home'),
        name: const Value('Home'),
        type: const Value('area'),
        userId: const Value(_userId),
      ),
    );
    await db.tagDao.upsertTag(
      TagsCompanion(
        id: const Value('ctx-errands'),
        name: const Value('Errands'),
        type: const Value('context'),
        userId: const Value(_userId),
      ),
    );
    await openApp(tester);
    try {
      await tester.tap(find.byKey(const Key('habits_add')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('habit_area_picker')));
      await _settle(tester);
      await tester.tap(find.text('Home'));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('habit_row_labels')));
      await _settle(tester);
      await tester.tap(
        find.byWidgetPredicate((w) => w is TagText && w.tag.name == 'Errands'),
      );
      await _settle(tester);
      await tester.tapAt(const Offset(5, 5));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const Key('habit_title')),
        'Drink water',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settle(tester, 10);

      final habit = await habitTitled(tester, 'Drink water');
      expect(habit, isNotNull);
      final commitments = await tester.runAsync(
        () => db.habitDao.commitmentsFor(habit!.id),
      );
      expect(commitments, hasLength(1));
      expect(commitments!.single.repeatKind, HabitRepeatKind.everyDay);
      expect(commitments.single.isMeasurable, isFalse);
      final tags = await tester.runAsync(() => db.habitDao.tagsFor(habit!.id));
      expect(tags!.map((t) => t.name), unorderedEquals(['Errands', 'Home']));
      expect(tags.where((t) => t.type == 'area').map((t) => t.id), [
        'area-home',
      ]);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('clearing an existing title is refused and the title stays', (
    tester,
  ) async {
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

  testWidgets(
    'Repeat sheet: N = 40 times a month saves; Cancel changes nothing',
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
        var commitments = await tester.runAsync(
          () => db.habitDao.commitmentsFor(id),
        );
        expect(commitments, hasLength(1));

        await tester.tap(find.byKey(const Key('habit_row_repeat')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('repeat_times_per_month')));
        await _settle(tester);
        await tester.enterText(find.byKey(const Key('repeat_count')), '40');
        await tester.pump();
        await tester.tap(find.byKey(const Key('habit_sheet_done')));
        await _settle(tester);
        commitments = await tester.runAsync(
          () => db.habitDao.commitmentsFor(id),
        );
        expect(commitments, hasLength(2));
        expect(commitments!.last.repeatKind, HabitRepeatKind.timesPerMonth);
        expect(commitments.last.timesPerPeriod, 40);
      } finally {
        await closeApp(tester);
      }
    },
  );

  testWidgets('a measured Check-in without a unit cannot press Done', (
    tester,
  ) async {
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
        find.byKey(const Key('habit_sheet_done')),
      );
      expect(done.onPressed, isNull);
      await tester.enterText(find.byKey(const Key('checkin_unit')), 'pages');
      await tester.pump();
      await tester.tap(find.byKey(const Key('habit_sheet_done')));
      await _settle(tester);
      final commitments = await tester.runAsync(
        () => db.habitDao.commitmentsFor(id),
      );
      expect(commitments!.last.unitLabel, 'pages');
      expect(commitments.last.dailyTargetAmount, 10);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets(
    'the Anchor sheet does not offer a Habit that would close a loop',
    (tester) async {
      final a = await seed('A');
      final b = await seed('B');
      await db.habitDao.setAnchor(
        habitId: b,
        userId: _userId,
        today: today,
        now: DateTime.now(),
        kind: HabitAnchorKind.afterHabit,
        anchorHabitId: a,
      );
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
    },
  );

  testWidgets(
    'pause, resume, archive and restore keep everything and show banners',
    (tester) async {
      final id = await seed('Read');
      await db.habitDao.addCheckIn(
        habitId: id,
        userId: _userId,
        countsForDay: today,
        now: DateTime.now(),
      );
      await openApp(tester, size: const Size(420, 1500));
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

        final checkIns = await tester.runAsync(
          () => db.select(db.habitCheckIns).get(),
        );
        expect(checkIns, hasLength(1));
        final rows = await tester.runAsync(() => db.select(db.habits).get());
        expect(rows, hasLength(1));
      } finally {
        await closeApp(tester);
      }
    },
  );

  testWidgets('at 1440 wide the list and detail sit side by side', (
    tester,
  ) async {
    final a = await seed('Alpha');
    final b = await seed('Beta');
    await openApp(tester, size: const Size(1440, 900));
    try {
      await tester.tap(find.byKey(Key('habit_row_$a')));
      await _settle(tester);
      expect(find.byKey(const Key('habit_title')), findsOneWidget);
      expect(find.byKey(Key('habit_row_$b')), findsOneWidget);
      final titleField = tester.widget<TextField>(
        find.byKey(const Key('habit_title')),
      );
      expect(titleField.controller!.text, 'Alpha');

      await tester.tap(find.byKey(Key('habit_row_$b')));
      await _settle(tester);
      final next = tester.widget<TextField>(
        find.byKey(const Key('habit_title')),
      );
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
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: ThemeData(brightness: Brightness.dark),
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(Key('habit_row_$a')));
      await _settle(tester);
      expect(find.byKey(const Key('habit_title')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await closeApp(tester);
    }
  });

  String dayKeyAgo(int days) {
    final now = DateTime.now();
    return habitDayKey(DateTime(now.year, now.month, now.day - days));
  }

  Future<void> checkIn(String id, int daysAgo) => db.habitDao.addCheckIn(
    habitId: id,
    userId: _userId,
    countsForDay: dayKeyAgo(daysAgo),
    now: DateTime.now(),
  );

  testWidgets('a new Habit shows the "new" banner once, after its first save', (
    tester,
  ) async {
    await openApp(tester);
    try {
      await tester.tap(find.byKey(const Key('habits_add')));
      await _settle(tester);
      expect(find.byKey(const Key('habit_flash_banner')), findsNothing);
      await tester.enterText(find.byKey(const Key('habit_title')), 'Stretch');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settle(tester, 10);
      expect(find.byKey(const Key('habit_flash_banner')), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Text &&
              (w.data == 'A new Habit, noted. Do begin.' ||
                  w.data == 'Very good. One more thing to be steady at.'),
        ),
        findsOneWidget,
      );
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a new Habit also shows the "new" banner in the wide pane', (
    tester,
  ) async {
    await openApp(tester, size: const Size(1440, 900));
    try {
      await tester.tap(find.byKey(const Key('habits_add')));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('habit_title')), 'Stretch');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settle(tester, 10);
      expect(find.byKey(const Key('habit_flash_banner')), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets(
    'a pause with a "resumes on" date ends on that date',
    (tester) async {
      var now = DateTime.now();
      final id = await seed('Read');
      await openApp(tester, size: const Size(420, 1500), clock: () => now);
      try {
        await tester.tap(find.byKey(Key('habit_row_$id')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('habit_pause')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('pause_resumes_on')));
        await _settle(tester);
        await tester.tap(find.text('OK'));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('habit_sheet_done')));
        await _settle(tester);
        expect(find.byKey(const Key('habit_resume')), findsOneWidget);
        expect(find.byKey(const Key('habit_flash_banner')), findsOneWidget);

        now = now.add(const Duration(days: 1));
        container.invalidate(habitTodayProvider);
        await _settle(tester);
        expect(find.byKey(const Key('habit_pause')), findsOneWidget);
      } finally {
        await closeApp(tester);
      }
    },
  );

  testWidgets(
    'when the Habit it follows is archived, the note and a new anchor show',
    (tester) async {
      final a = await seed('A');
      final b = await seed('B');
      final c = await seed('C');
      await db.habitDao.setAnchor(
        habitId: b,
        userId: _userId,
        today: today,
        now: DateTime.now(),
        kind: HabitAnchorKind.afterHabit,
        anchorHabitId: a,
      );
      await db.habitDao.archive(
        habitId: a,
        userId: _userId,
        today: today,
        now: DateTime.now(),
      );
      await openApp(tester);
      try {
        await tester.tap(find.byKey(Key('habit_row_$b')));
        await _settle(tester);
        expect(
          find.byKey(const Key('habit_anchor_stopped_note')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('habit_flash_banner')), findsOneWidget);
        await tester.tap(find.byKey(const Key('habit_choose_new_anchor')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('anchor_after_habit')));
        await _settle(tester);
        expect(find.byKey(Key('anchor_candidate_$a')), findsNothing);
        await tester.tap(find.byKey(Key('anchor_candidate_$c')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('habit_sheet_done')));
        await _settle(tester);
        final habit = await tester.runAsync(() => db.habitDao.habitById(b));
        expect(habit!.anchorHabitId, c);
        expect(
          find.byKey(const Key('habit_anchor_stopped_note')),
          findsNothing,
        );
      } finally {
        await closeApp(tester);
      }
    },
  );

  testWidgets('every anchor kind saves', (tester) async {
    final a = await seed('A');
    final b = await seed('B');
    await openApp(tester);
    try {
      await tester.tap(find.byKey(Key('habit_row_$a')));
      await _settle(tester);
      for (final choice in ['after_habit', 'before_habit']) {
        await tester.tap(find.byKey(const Key('habit_row_anchor')));
        await _settle(tester);
        await tester.tap(find.byKey(Key('anchor_$choice')));
        await _settle(tester);
        await tester.tap(find.byKey(Key('anchor_candidate_$b')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('habit_sheet_done')));
        await _settle(tester);
        final habit = await tester.runAsync(() => db.habitDao.habitById(a));
        expect(habit!.anchorKind, choice);
        expect(habit.anchorHabitId, b);
      }
      await tester.tap(find.byKey(const Key('habit_row_anchor')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('anchor_none')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('habit_sheet_done')));
      await _settle(tester);
      final none = await tester.runAsync(() => db.habitDao.habitById(a));
      expect(none!.anchorKind, 'none');

      await tester.tap(find.byKey(const Key('habit_row_anchor')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('anchor_part_of_day')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('anchor_part_evening')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('habit_sheet_done')));
      await _settle(tester);
      final part = await tester.runAsync(() => db.habitDao.habitById(a));
      expect(part!.anchorKind, 'part_of_day');
      expect(part.anchorPartOfDay, 'evening');

      await tester.tap(find.byKey(const Key('habit_row_anchor')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('anchor_clock_time')));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('anchor_clock_time_field')), '07:30');
      await tester.pump();
      await tester.tap(find.byKey(const Key('habit_sheet_done')));
      await _settle(tester);
      final clock = await tester.runAsync(() => db.habitDao.habitById(a));
      expect(clock!.anchorKind, 'clock_time');
      expect(clock.anchorClockTime, '07:30');
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('every repeat rule saves, and a past day keeps its old rule', (
    tester,
  ) async {
    final id = await db.habitDao.createHabit(
      userId: _userId,
      title: 'Read',
      today: dayKeyAgo(90),
      now: DateTime.now().subtract(const Duration(days: 90)),
      firstCommitment: defaultNewHabitCommitment,
    );
    await openApp(tester);
    try {
      await tester.tap(find.byKey(Key('habit_row_$id')));
      await _settle(tester);
      Future<void> choose(String key, {String? count}) async {
        await tester.tap(find.byKey(const Key('habit_row_repeat')));
        await _settle(tester);
        await tester.tap(find.byKey(Key(key)));
        await _settle(tester);
        if (count != null) {
          await tester.enterText(find.byKey(const Key('repeat_count')), count);
          await tester.pump();
        }
        await tester.tap(find.byKey(const Key('habit_sheet_done')));
        await _settle(tester);
      }

      await choose('repeat_times_per_week', count: '3');
      await choose('repeat_every_n_days', count: '2');
      await choose('repeat_times_per_month', count: '12');
      await tester.tap(find.byKey(const Key('habit_row_repeat')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('repeat_chosen_weekdays')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('weekday_1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('habit_sheet_done')));
      await _settle(tester);
      await choose('repeat_every_day');

      final commitments = await tester.runAsync(
        () => db.habitDao.commitmentsFor(id),
      );
      expect(commitments!.map((c) => c.repeatKind), [
        HabitRepeatKind.everyDay,
        HabitRepeatKind.timesPerWeek,
        HabitRepeatKind.everyNDays,
        HabitRepeatKind.timesPerMonth,
        HabitRepeatKind.chosenWeekdays,
        HabitRepeatKind.everyDay,
      ]);
      expect(commitmentInForceOn(commitments, today)!.id, commitments.last.id);
      // A day long before every change still reads the first, every-day rule.
      expect(
        commitmentInForceOn(commitments, dayKeyAgo(80))!.id,
        commitments.first.id,
      );
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('Area, energy and estimate are stored on an existing Habit', (
    tester,
  ) async {
    await db.tagDao.upsertTag(
      TagsCompanion(
        id: const Value('area-home'),
        name: const Value('Home'),
        type: const Value('area'),
        userId: const Value(_userId),
      ),
    );
    final id = await seed('Read');
    await openApp(tester);
    try {
      await tester.tap(find.byKey(Key('habit_row_$id')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('habit_area_picker')));
      await _settle(tester);
      await tester.tap(find.text('Home'));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('habit_row_energy')));
      await _settle(tester);
      await tester.tap(find.text('High'));
      await _settle(tester);
      // The Place row sits above Energy, so the estimate row is now below the
      // fold on a phone. A tap on a row below the fold silently does nothing
      // (docs/TESTING.md): scroll it into view first.
      await tester.ensureVisible(find.byKey(const Key('habit_row_estimate')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('habit_row_estimate')));
      await _settle(tester);
      // The Outcome estimate sheet, without its Timeboxed switch.
      expect(find.byKey(const Key('estimate_sheet_timeboxed')), findsNothing);
      await tester.tap(find.byKey(const Key('estimate_sheet_more')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('estimate_sheet_save')));
      await _settle(tester);
      final tags = await tester.runAsync(() => db.habitDao.tagsFor(id));
      expect(tags!.map((t) => t.id), ['area-home']);
      final habit = await tester.runAsync(() => db.habitDao.habitById(id));
      expect(habit!.timeEstimateMinutes, stepEstimateUp(null));
      expect(habit.energyLevel, 'high');
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a list longer than the screen scrolls to its last Habit', (
    tester,
  ) async {
    for (var i = 0; i < 24; i++) {
      await seed('Habit ${i.toString().padLeft(2, '0')}');
    }
    await openApp(tester);
    try {
      expect(find.text('Habit 23'), findsNothing);
      await tester.dragUntilVisible(
        find.text('Habit 23'),
        find.byType(ListView).first,
        const Offset(0, -300),
      );
      expect(find.text('Habit 23'), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('"all done" shows when every Habit due today has a Check-in', (
    tester,
  ) async {
    final id = await seed('Read');
    await checkIn(id, 0);
    await openApp(tester);
    try {
      expect(find.text('All done for today.'), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('"nothing due" shows when no active Habit is for today', (
    tester,
  ) async {
    final tomorrowIso = DateTime.now().add(const Duration(days: 1)).weekday;
    final id = await seed(
      'Read',
      commitment: HabitCommitmentDraft(
        repeatKind: HabitRepeatKind.chosenWeekdays,
        chosenWeekdays: [tomorrowIso],
      ),
    );
    expect(id, isNotEmpty);
    await openApp(tester);
    try {
      expect(find.text('Nothing is due today.'), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a broken streak shows the banner when the detail opens', (
    tester,
  ) async {
    final id = await db.habitDao.createHabit(
      userId: _userId,
      title: 'Read',
      today: dayKeyAgo(6),
      now: DateTime.now().subtract(const Duration(days: 6)),
      firstCommitment: defaultNewHabitCommitment,
    );
    for (final ago in [4, 3, 2]) {
      await checkIn(id, ago);
    }
    await openApp(tester);
    try {
      await tester.tap(find.byKey(Key('habit_row_$id')));
      await _settle(tester);
      expect(find.byKey(const Key('habit_flash_banner')), findsOneWidget);
      expect(find.textContaining('streak of 3 ended'), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a measured target of Infinity cannot press Done', (
    tester,
  ) async {
    final id = await seed('Read');
    await openApp(tester);
    try {
      await tester.tap(find.byKey(Key('habit_row_$id')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('habit_row_checkin')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('checkin_kind_measurable')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('checkin_unit')), 'pages');
      await tester.enterText(
        find.byKey(const Key('checkin_target')),
        'Infinity',
      );
      await tester.pump();
      final done = tester.widget<FilledButton>(
        find.byKey(const Key('habit_sheet_done')),
      );
      expect(done.onPressed, isNull);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('notes typed in a focused field are saved when Back is pressed', (
    tester,
  ) async {
    final id = await seed('Read');
    await openApp(tester);
    try {
      await tester.tap(find.byKey(Key('habit_row_$id')));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('habit_notes')), 'Ten pages');
      await tester.pump();
      await tester.pageBack();
      await _settle(tester, 10);
      final habit = await tester.runAsync(() => db.habitDao.habitById(id));
      expect(habit!.notes, 'Ten pages');
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a titled draft in the wide pane is kept when another Habit is '
      'selected', (tester) async {
    final a = await seed('Alpha');
    await openApp(tester, size: const Size(1440, 900));
    try {
      await tester.tap(find.byKey(const Key('habits_add')));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('habit_title')), 'Stretch');
      await tester.pump();
      await tester.tap(find.byKey(Key('habit_row_$a')));
      await _settle(tester, 10);
      expect(await habitTitled(tester, 'Stretch'), isNotNull);
      final rows = await tester.runAsync(() => db.select(db.habits).get());
      expect(rows!.where((h) => h.title == 'Stretch'), hasLength(1));
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a new Habit can be anchored after an existing one', (
    tester,
  ) async {
    final a = await seed('Alpha');
    await openApp(tester);
    try {
      await tester.tap(find.byKey(const Key('habits_add')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('habit_row_anchor')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('anchor_after_habit')));
      await _settle(tester);
      await tester.tap(find.byKey(Key('anchor_candidate_$a')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('habit_sheet_done')));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('habit_title')), 'Floss');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settle(tester, 10);
      final habit = await habitTitled(tester, 'Floss');
      expect(habit!.anchorKind, 'after_habit');
      expect(habit.anchorHabitId, a);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('closing an untouched detail does not overwrite a newer stored '
      'title and notes', (tester) async {
    final id = await seed('Read');
    await openApp(tester);
    try {
      await tester.tap(find.byKey(Key('habit_row_$id')));
      await _settle(tester);
      await tester.runAsync(
        () => db.habitDao.updateHabitDetails(
          habitId: id,
          userId: _userId,
          title: 'Read more',
          notes: 'From elsewhere',
          energyLevel: null,
          timeEstimateMinutes: null,
          now: DateTime.now().toUtc(),
        ),
      );
      await tester.pageBack();
      await _settle(tester, 10);
      final habit = await tester.runAsync(() => db.habitDao.habitById(id));
      expect(habit!.title, 'Read more');
      expect(habit.notes, 'From elsewhere');
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('an edit restored to its old text while an earlier save is still '
      'pending is stored last', (tester) async {
    final id = await seed('Read');
    await openApp(tester);
    try {
      await tester.tap(find.byKey(Key('habit_row_$id')));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('habit_notes')), 'Ten pages');
      await tester.pump();
      // Leaving the field issues a save; no real async runs before the pane
      // closes, so that save is still pending at teardown.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.enterText(find.byKey(const Key('habit_notes')), '');
      await tester.pump();
      await tester.pageBack();
      await _settle(tester, 10);
      final habit = await tester.runAsync(() => db.habitDao.habitById(id));
      expect(habit!.notes ?? '', '');
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a rejected empty title does not erase newer typing', (
    tester,
  ) async {
    final id = await seed('Read');
    await openApp(tester);
    try {
      await tester.tap(find.byKey(Key('habit_row_$id')));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('habit_title')), 'B');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.enterText(find.byKey(const Key('habit_title')), '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.enterText(find.byKey(const Key('habit_title')), 'C');
      await _settle(tester, 10);
      final field = tester.widget<TextField>(find.byKey(const Key('habit_title')));
      expect(field.controller!.text, 'C');
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('notes typed on a draft are stored when the title is submitted', (
    tester,
  ) async {
    await openApp(tester);
    try {
      await tester.tap(find.byKey(const Key('habits_add')));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('habit_notes')), 'Slowly');
      await tester.enterText(find.byKey(const Key('habit_title')), 'Walk');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settle(tester, 10);
      final habit = await habitTitled(tester, 'Walk');
      expect(habit!.notes, 'Slowly');
    } finally {
      await closeApp(tester);
    }
  });
}
