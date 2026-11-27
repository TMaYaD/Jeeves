/// Stopping an approach at its Timeboxed limit, end to end (issue #49).
///
/// The journey: an Outcome whose current Action is Timeboxed and past its
/// limit → the "Next sprint" gate → "Right ho" → the "Approach stopped" sheet
/// → a verdict. Every assertion is a statement about the rows the app reads —
/// the Action's role and its stopped-at-the-limit mark, the time it logged,
/// the Outcome's own row — and not about a stubbed status.
///
/// Driven through the real Task detail screen over a real in-memory database,
/// so the gate, the sheet and the landing are the ones the app runs.
@TestOn('!browser')
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/daos/action_dao.dart'
    show TerminatedAction;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/focus_settings.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/focus_settings_provider.dart';
import 'package:jeeves/screens/task_detail/task_detail_screen.dart';
import 'package:jeeves/widgets/next_action_dialog.dart';

import '../helpers/app_title_bar_test_helpers.dart';
import '../test_helpers.dart';

const _userId = 'local';
const _outcomeId = 'report';
const _otherOutcomeId = 'invoice';

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
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// Keeps the Plan loaded, the way the Now screen does.
///
/// The Plan providers are not auto-disposed: once the app has loaded them they
/// keep their value, so the landing that reads them resolves at once. A test
/// that never shows the Plan has to stand in for that, or the read never
/// resolves.
class _PlanKeeper extends ConsumerWidget {
  const _PlanKeeper({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(activeSessionTasksProvider);
    ref.watch(activeSessionSettlementsProvider);
    return child;
  }
}

/// Runs [body] over the real Task detail screen, with Focus Mode stubbed as a
/// plain screen: the Sprint never starts on the paths this journey walks.
Future<void> _withApp(
  WidgetTester tester,
  GtdDatabase db,
  Future<void> Function() body, {
  required List<Todo> sessionTasks,
}) async {
  final router = GoRouter(
    initialLocation: '/task/$_outcomeId',
    routes: [
      GoRoute(
        path: '/task/:id',
        builder: (context, state) =>
            TaskDetailScreen(todoId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/focus',
        builder: (_, _) => const Scaffold(body: Text('Focus list')),
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
        // The landing reads the Plan's members. A live Drift watch cannot be
        // advanced past by a fake-clock `pump`, so the Plan is fixed here.
        activeSessionTasksProvider.overrideWith((_) => Stream.value(sessionTasks)),
        activeSessionSettlementsProvider
            .overrideWith((_) => Stream.value(const {})),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => _PlanKeeper(child: child!),
      ),
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

/// An Outcome with a current Action, carrying the estimate and the switch,
/// plus another Outcome on the Plan.
Future<List<Todo>> _seed(GtdDatabase db) async {
  final now = DateTime.now().toUtc();
  await db.todoDao.insertOutcome(
    id: _outcomeId,
    title: 'Write the report',
    userId: _userId,
    now: now,
  );
  await db.todoDao.insertOutcome(
    id: _otherOutcomeId,
    title: 'Pay the invoice',
    userId: _userId,
    now: now,
  );
  await db.actionDao.setCurrentAction(
    _outcomeId,
    'Draft the report',
    timeEstimate: 30,
    now: now,
  );
  await db.todoDao.updateFields(_outcomeId, timeboxed: true, now: now);
  // Work already done: the limit is behind the user.
  await db.timeLogDao.openLog(
    taskId: _outcomeId,
    userId: _userId,
    now: now.subtract(const Duration(minutes: 50)),
  );
  await db.timeLogDao.closeLog(taskId: _outcomeId, now: now);
  return [
    (await db.todoDao.getTodo(_outcomeId))!,
    (await db.todoDao.getTodo(_otherOutcomeId))!,
  ];
}

/// The Action the Outcome was working on, read back from the rows.
Future<Action?> _current(GtdDatabase db) =>
    db.actionDao.getCurrentAction(_outcomeId);

/// The terminated Actions of the Outcome.
Future<List<TerminatedAction>> _history(GtdDatabase db) =>
    db.actionDao.getTerminatedActions(_outcomeId);

/// The minutes the Outcome logged, read the way the app reads them.
Future<int> _loggedMinutes(GtdDatabase db) =>
    db.timeLogDao.totalMinutesForTask(_outcomeId);

/// Walks the gate and stops the approach: Start → "Right ho".
Future<void> _rightHo(WidgetTester tester) async {
  await tapBarAction(tester, const Key('task_detail_start_focus'));
  await _settle(tester);
  expect(find.byKey(const Key('timeboxed_gate_stop')), findsOneWidget);
  await tester.tap(find.byKey(const Key('timeboxed_gate_stop')));
  await _settle(tester);
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = _openInMemory();
  });
  tearDown(() async => db.close());

  testWidgets('"Right ho" opens the "Approach stopped" sheet', (tester) async {
    final sessionTasks = (await tester.runAsync(() => _seed(db)))!;

    await _withApp(tester, db, () async {
      await _settle(tester);
      await _rightHo(tester);

      // The gate is gone and the sheet it opened is here: the same four
      // choices as the Done sheet, under the heading "Approach stopped".
      expect(find.byKey(const Key('timeboxed_gate_stop')), findsNothing);
      expect(find.text('Approach stopped'), findsOneWidget);
      expect(find.text('Outcome achieved'), findsOneWidget);
      expect(find.text('More to do…'), findsOneWidget);
      expect(find.text('Waiting on someone…'), findsOneWidget);
      expect(find.text('Defer to Someday'), findsOneWidget);

      // Nothing has been written yet: the Action is still current.
      expect(await tester.runAsync(() => _current(db)), isNotNull);
    }, sessionTasks: sessionTasks);
  });

  testWidgets('"Outcome achieved" closes the Action at its limit and lands '
      'on the focus list', (tester) async {
    final seeded = await tester.runAsync(() => _seed(db));
    // Nothing else is planned, so the landing says the day is done.
    final sessionTasks = <Todo>[seeded!.first];

    await _withApp(tester, db, () async {
      await _settle(tester);
      await _rightHo(tester);
      await tester.tap(find.text('Outcome achieved'));
      await _settle(tester);

      // The Action was stopped at its limit: not done, not abandoned.
      final history = await tester.runAsync(() => _history(db));
      expect(history, hasLength(1));
      expect(history!.single.action.role, 'superseded');
      expect(history.single.action.stoppedAtLimitAt, isNotNull);
      expect(history.single.action.doneAt, isNull);

      // The time it logged is still its own.
      expect(await tester.runAsync(() => _loggedMinutes(db)), 50);

      // The Outcome is achieved.
      final row = await tester.runAsync(() => db.todoDao.getTodo(_outcomeId));
      expect(row!.doneAt, isNotNull);

      // The landing: the focus list, and what it says.
      expect(find.text('Focus list'), findsOneWidget);
      expect(find.text('All done for today!'), findsOneWidget);
    }, sessionTasks: sessionTasks);
  });

  testWidgets('"Defer to Someday" closes the Action at its limit and says '
      'what is next', (tester) async {
    final sessionTasks = (await tester.runAsync(() => _seed(db)))!;

    await _withApp(tester, db, () async {
      await _settle(tester);
      await _rightHo(tester);
      await tester.tap(find.text('Defer to Someday'));
      await _settle(tester);

      final history = await tester.runAsync(() => _history(db));
      expect(history!.single.action.role, 'superseded');
      expect(history.single.action.stoppedAtLimitAt, isNotNull);

      // The Outcome is deferred, not achieved.
      final row = await tester.runAsync(() => db.todoDao.getTodo(_outcomeId));
      expect(row!.intent, 'maybe');
      expect(row.doneAt, isNull);

      // The landing names the next member of the Plan.
      expect(find.text('Focus list'), findsOneWidget);
      expect(find.text('Stopped there. Next up: Pay the invoice'), findsOneWidget);
    }, sessionTasks: sessionTasks);
  });

  testWidgets('"More to do…" promotes a planned Action without asking to '
      'replace anything', (tester) async {
    final sessionTasks = (await tester.runAsync(() async {
      final tasks = await _seed(db);
      await db.actionDao.addPlannedAction(
        _outcomeId,
        'Draft the outline',
        now: DateTime.now().toUtc(),
      );
      return tasks;
    }))!;

    await _withApp(tester, db, () async {
      await _settle(tester);
      await _rightHo(tester);
      await tester.tap(find.text('More to do…'));
      await _settle(tester);

      // The queue is offered, and picking one promotes it without a
      // "Replace current action" confirm — the Action is being closed, not
      // swapped.
      final offered = find.descendant(
        of: find.byType(NextActionDialog),
        matching: find.text('Draft the outline'),
      );
      expect(offered, findsOneWidget);
      await tester.tap(offered);
      await _settle(tester);

      final current = await tester.runAsync(() => _current(db));
      expect(current!.actionText, 'Draft the outline');
      expect(current.stoppedAtLimitAt, isNull);

      // The Action that was stopped is in the history, stopped at its limit.
      final history = await tester.runAsync(() => _history(db));
      expect(history!.single.action.role, 'superseded');
      expect(history.single.action.stoppedAtLimitAt, isNotNull);
    }, sessionTasks: sessionTasks);
  });

  testWidgets('dismissing the sheet writes nothing, and the gate asks again',
      (tester) async {
    final seeded = await tester.runAsync(() => _seed(db));
    final sessionTasks = seeded!;
    final stampBefore = seeded.first.lastClarifiedAt;

    await _withApp(tester, db, () async {
      await _settle(tester);
      await _rightHo(tester);

      // Tap the modal barrier above the sheet to dismiss it.
      await tester.tapAt(const Offset(400, 20));
      await _settle(tester);

      // Nothing was written: the Action is still current, still Timeboxed,
      // and the Outcome is untouched.
      final current = await tester.runAsync(() => _current(db));
      expect(current, isNotNull);
      expect(current!.stoppedAtLimitAt, isNull);
      final row = await tester.runAsync(() => db.todoDao.getTodo(_outcomeId));
      expect(row!.doneAt, isNull);
      expect(row.lastClarifiedAt, stampBefore,
          reason: 'the Outcome was not re-clarified');
      expect(await tester.runAsync(() => _history(db)), isEmpty);

      // The next Start asks again: the Action is still past its limit.
      await tapBarAction(tester, const Key('task_detail_start_focus'));
      await _settle(tester);
      expect(find.byKey(const Key('timeboxed_gate_stop')), findsOneWidget);
    }, sessionTasks: sessionTasks);
  });

  testWidgets('the time logged across two stints is kept when the approach '
      'stops', (tester) async {
    final sessionTasks = (await tester.runAsync(() async {
      final tasks = await _seed(db);
      // A second stint on the same Action: the limit is reached in pieces.
      // One instant for both ends, so the stint is exactly twenty minutes.
      final second = DateTime.now().toUtc();
      await db.timeLogDao.openLog(
        taskId: _outcomeId,
        userId: _userId,
        now: second.subtract(const Duration(minutes: 20)),
      );
      await db.timeLogDao.closeLog(taskId: _outcomeId, now: second);
      return tasks;
    }))!;

    await _withApp(tester, db, () async {
      await _settle(tester);
      await _rightHo(tester);
      await tester.tap(find.text('Defer to Someday'));
      await _settle(tester);

      // Both stints are still the Action's own time.
      expect(await tester.runAsync(() => _loggedMinutes(db)), 70);
      final history = await tester.runAsync(() => _history(db));
      expect(history!.single.loggedMinutes, 70);
    }, sessionTasks: sessionTasks);
  });
}
