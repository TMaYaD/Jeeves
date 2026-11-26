/// The Timeboxed limit, end to end (issue #923).
///
/// The estimate dialog, the switch, the limit and the gate, driven through the
/// real Task detail screen over a real in-memory database: every assertion is
/// a statement about the rows the app reads — the Action's estimate, its
/// switch, its TimeLogs, the recorded Sprints — and not about a stubbed
/// status.
///
/// The Focus Mode side of the story — the strip and the red dots — is pinned
/// in `test/screens/active_focus_timeboxed_test.dart`, and the gate's own
/// tiers in `test/widgets/timeboxed_gate_test.dart`.
@TestOn('!browser')
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/focus_settings.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_settings_provider.dart';
import 'package:jeeves/screens/task_detail/task_detail_screen.dart';
import 'package:jeeves/widgets/timeboxed_glyph.dart';

import '../helpers/app_title_bar_test_helpers.dart';
import '../test_helpers.dart';

const _userId = 'local';
const _outcomeId = 'report';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

/// Fixed settings: the real sprint timer reads them once there is an
/// engagement, and the live notifier would open a synced-preferences watch
/// whose close timer outlives the test.
class _FixedFocusSettings extends FocusSettingsNotifier {
  @override
  FocusSettings build() => const FocusSettings();
}

/// Lets the screen's real database reads and writes finish, then settles the
/// sheets' animations.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// Runs [body] over the real Task detail screen, with Focus Mode stubbed as a
/// plain screen: what this journey is about happens before Focus Mode opens.
///
/// The screen is taken down and the router disposed afterwards, so the live
/// Drift watches' close timers do not outlive the test.
Future<void> _withApp(
  WidgetTester tester,
  GtdDatabase db,
  Future<void> Function() body,
) async {
  final router = GoRouter(
    initialLocation: '/task/$_outcomeId',
    routes: [
      GoRoute(
        path: '/task/:id',
        builder: (context, state) =>
            TaskDetailScreen(todoId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/focus/active',
        builder: (_, _) => const Scaffold(body: Text('Active focus')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        focusSettingsProvider.overrideWith(_FixedFocusSettings.new),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  try {
    await body();
  } finally {
    await tester.pumpWidget(const SizedBox());
    await _settle(tester);
    router.dispose();
  }
}

/// An Outcome with a current Action, carrying the estimate and the switch.
Future<void> _seed(
  GtdDatabase db, {
  int? timeEstimate,
  bool timeboxed = false,
}) async {
  final now = DateTime.now().toUtc();
  await db.todoDao.insertOutcome(
    id: _outcomeId,
    title: 'Write the report',
    userId: _userId,
    now: now,
  );
  await db.actionDao.setCurrentAction(
    _outcomeId,
    'Draft the report',
    timeEstimate: timeEstimate,
    now: now,
  );
  if (timeboxed) {
    await db.todoDao.updateFields(_outcomeId, timeboxed: true, now: now);
  }
}

/// Logs [logged] minutes on the Action, ending now — work already done, so
/// the limit is behind the user.
Future<void> _logTime(GtdDatabase db, Duration logged) async {
  final now = DateTime.now().toUtc();
  await db.timeLogDao.openLog(
    taskId: _outcomeId,
    userId: _userId,
    now: now.subtract(logged),
  );
  await db.timeLogDao.closeLog(taskId: _outcomeId, now: now);
}

/// The TimeLogs still running.
Future<int> _openLogCount(GtdDatabase db) async {
  final rows = await db.customSelect(
    'SELECT COUNT(*) AS c FROM time_logs WHERE ended_at IS NULL',
  ).get();
  return rows.first.read<int>('c');
}

/// The Sprints recorded.
Future<int> _sprintCount(GtdDatabase db) async {
  final rows = await db.customSelect('SELECT COUNT(*) AS c FROM sprints').get();
  return rows.first.read<int>('c');
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = _openInMemory();
  });
  tearDown(() async => db.close());

  testWidgets('the estimate sheet makes the Action Timeboxed', (tester) async {
    await tester.runAsync(() => _seed(db));

    await _withApp(tester, db, () async {
      await _settle(tester);

      // No estimate: the tag reads "Set" — a quiet prompt, not a number.
      final chip = find.byKey(const Key('outcome_attribute_time'));
      expect(chip, findsOneWidget);
      expect(
        find.descendant(of: chip, matching: find.text('Set')),
        findsOneWidget,
      );

      await tester.tap(chip);
      await _settle(tester);

      // With no estimate there is nothing to limit, so the switch says so and
      // cannot be pressed.
      final toggle = find.byKey(const Key('estimate_sheet_timeboxed'));
      expect(tester.widget<InkWell>(toggle).onTap, isNull);

      // The ladder: 5, 10, 15, 30.
      for (var step = 0; step < 4; step++) {
        await tester.tap(find.byKey(const Key('estimate_sheet_more')));
        await tester.pump();
      }
      expect(
        tester.widget<Text>(find.byKey(const Key('estimate_sheet_value'))).data,
        '30m',
      );

      // With an estimate, the switch is there to press.
      expect(tester.widget<InkWell>(toggle).onTap, isNotNull);
      await tester.tap(toggle);
      await tester.pump();
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: toggle,
                matching: find.byIcon(Icons.timer_outlined),
              ),
            )
            .color,
        const Color(0xFF2563EB),
        reason: 'the mark takes the estimate\'s own ink once the switch is on',
      );

      await tester.tap(find.byKey(const Key('estimate_sheet_save')));
      await _settle(tester);

      // The Action holds the estimate and the switch; the Outcome mirrors the
      // estimate.
      final action = (await tester.runAsync(
        () => db.actionDao.getCurrentAction(_outcomeId),
      ))!;
      expect(action.timeEstimate, 30);
      expect(action.timeboxed, isTrue);
      final todo =
          (await tester.runAsync(() => db.todoDao.getTodo(_outcomeId)))!;
      expect(todo.timeEstimate, 30);

      // The tag shows the estimate and carries the mark.
      expect(
        find.descendant(of: chip, matching: find.text('30m')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: chip, matching: find.byType(TimeboxedGlyph)),
        findsOneWidget,
      );
    });
  });

  testWidgets('a limit passed with the switch off starts without asking', (
    tester,
  ) async {
    await tester.runAsync(() => _seed(db, timeEstimate: 30));
    await tester.runAsync(
      () => _logTime(db, const Duration(minutes: 50)),
    );

    await _withApp(tester, db, () async {
      await _settle(tester);

      await tapBarAction(tester, const Key('task_detail_start_focus'));
      await _settle(tester);

      // Nothing is asked: an estimate that is a guess warns about nothing.
      expect(find.byKey(const Key('timeboxed_gate_stop')), findsNothing);
      expect(find.text('Active focus'), findsOneWidget);
      expect(await tester.runAsync(() => _openLogCount(db)), 1);
    });
  });

  testWidgets('a limit passed with the switch on asks before the Sprint', (
    tester,
  ) async {
    await tester.runAsync(
      () => _seed(db, timeEstimate: 30, timeboxed: true),
    );
    await tester.runAsync(
      () => _logTime(db, const Duration(minutes: 50)),
    );

    await _withApp(tester, db, () async {
      await _settle(tester);

      await tapBarAction(tester, const Key('task_detail_start_focus'));
      await _settle(tester);

      // The gate asks, with the figures and the ways on.
      expect(find.byKey(const Key('timeboxed_gate_stop')), findsOneWidget);
      expect(find.text('The limit has run its course, sir.'), findsOneWidget);
      expect(find.text('Sprints past the limit so far: 0'), findsOneWidget);

      // "Right ho" starts nothing: no TimeLog, no Sprint, no Focus Mode.
      await tester.tap(find.byKey(const Key('timeboxed_gate_stop')));
      await _settle(tester);
      expect(find.byKey(const Key('timeboxed_gate_stop')), findsNothing);
      expect(find.text('Active focus'), findsNothing);
      expect(await tester.runAsync(() => _openLogCount(db)), 0);
      expect(await tester.runAsync(() => _sprintCount(db)), 0);

      // Start again: "regardless" asks once more before it starts anything.
      await tapBarAction(tester, const Key('task_detail_start_focus'));
      await _settle(tester);
      expect(find.byKey(const Key('timeboxed_gate_regardless')), findsOneWidget);
      await tester.tap(find.byKey(const Key('timeboxed_gate_regardless')));
      await _settle(tester);
      expect(find.byKey(const Key('timeboxed_gate_confirm')), findsOneWidget);
      expect(find.text('Once more, sir, to be certain.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('timeboxed_gate_confirm')));
      await _settle(tester);

      // The engagement starts, and the estimate is exactly as it was.
      expect(find.text('Active focus'), findsOneWidget);
      expect(await tester.runAsync(() => _openLogCount(db)), 1);
      final action = (await tester.runAsync(
        () => db.actionDao.getCurrentAction(_outcomeId),
      ))!;
      expect(action.timeEstimate, 30);
      expect(action.timeboxed, isTrue);
    });
  });

  testWidgets('a Sprint already past the limit asks again, in a firmer tone', (
    tester,
  ) async {
    await tester.runAsync(
      () => _seed(db, timeEstimate: 30, timeboxed: true),
    );
    await tester.runAsync(
      () => _logTime(db, const Duration(minutes: 50)),
    );
    // One Sprint has already been started past the limit, and has finished:
    // this is the second one past the limit.
    await tester.runAsync(
      () => db.sprintDao.startSprint(
        taskId: _outcomeId,
        userId: _userId,
        plannedDurationMinutes: 25,
        now: DateTime.now().toUtc().subtract(const Duration(minutes: 10)),
      ),
    );
    await tester.runAsync(
      () => db.sprintDao.endRunningSprint(
        userId: _userId,
        now: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
      ),
    );

    await _withApp(tester, db, () async {
      await _settle(tester);

      await tapBarAction(tester, const Key('task_detail_start_focus'));
      await _settle(tester);

      // The gate asks again, and says how many Sprints have gone past.
      expect(find.byKey(const Key('timeboxed_gate_stop')), findsOneWidget);
      expect(find.text('Sprints past the limit so far: 1'), findsOneWidget);

      // The tone is firmer than the first time: the second past the limit is
      // not the first, and the advice says so.
      expect(
        find.text('That would be the second past the limit, sir.'),
        findsOneWidget,
      );
      expect(find.text('The limit has run its course, sir.'), findsNothing);

      // Carrying on leaves the estimate exactly as it was.
      await tester.tap(find.byKey(const Key('timeboxed_gate_regardless')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('timeboxed_gate_confirm')));
      await _settle(tester);
      final action = (await tester.runAsync(
        () => db.actionDao.getCurrentAction(_outcomeId),
      ))!;
      expect(action.timeEstimate, 30);
    });
  });

  testWidgets('a limit of nothing is not a limit: the mark goes', (
    tester,
  ) async {
    await tester.runAsync(
      () => _seed(db, timeEstimate: 30, timeboxed: true),
    );
    // A merge left the Outcome's mirror holding the estimate while the
    // Action's own copy was cleared. The limit is the Action's estimate, so
    // there is no limit — and the mark does not say there is.
    await tester.runAsync(() async {
      await db.customStatement('UPDATE actions SET time_estimate = NULL');
      await db.customStatement('UPDATE todos SET time_estimate = 30');
    });

    await _withApp(tester, db, () async {
      await _settle(tester);

      final chip = find.byKey(const Key('outcome_attribute_time'));
      // The estimate is still on show — it is the Outcome's.
      expect(
        find.descendant(of: chip, matching: find.text('30m')),
        findsOneWidget,
      );
      // But the mark is gone: there is nothing to limit.
      expect(
        find.descendant(of: chip, matching: find.byType(TimeboxedGlyph)),
        findsNothing,
      );
    });
  });

  testWidgets('"Raise the estimate…" above the logged time starts the Sprint', (
    tester,
  ) async {
    await tester.runAsync(
      () => _seed(db, timeEstimate: 30, timeboxed: true),
    );
    await tester.runAsync(
      () => _logTime(db, const Duration(minutes: 50)),
    );

    await _withApp(tester, db, () async {
      await _settle(tester);

      await tapBarAction(tester, const Key('task_detail_start_focus'));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('timeboxed_gate_raise')));
      await _settle(tester);

      // The sheet opens one step up: 30 becomes 45.
      expect(
        tester.widget<Text>(find.byKey(const Key('estimate_sheet_value'))).data,
        '45m',
      );

      // One step further: 60, above the 50 minutes logged.
      await tester.tap(find.byKey(const Key('estimate_sheet_more')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('estimate_sheet_save')));
      await _settle(tester);

      // The limit moved with the estimate, so the Sprint starts with no
      // further ask — and the change is permanent.
      expect(find.byKey(const Key('timeboxed_gate_stop')), findsNothing);
      expect(find.text('Active focus'), findsOneWidget);
      expect(await tester.runAsync(() => _openLogCount(db)), 1);
      final action = (await tester.runAsync(
        () => db.actionDao.getCurrentAction(_outcomeId),
      ))!;
      expect(action.timeEstimate, 60);
      expect(action.timeboxed, isTrue);
    });
  });
}
