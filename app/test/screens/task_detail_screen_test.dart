import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
// Hide Material's `Intent` (clashes with the domain Intent) and `Action`
// (clashes with the Drift Action row type, issue #475).
import 'package:flutter/material.dart' hide Intent, Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/daos/action_dao.dart' show TerminatedAction;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show Intent;
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/providers/sprint_timer_provider.dart'
    show sprintTimerProvider;
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/screens/task_detail/task_detail_screen.dart';
import 'package:jeeves/sync/collection_codecs.dart' show todosCollection;
import 'package:jeeves/sync/domain_op_capture.dart'
    show RecordingDomainOpCapture;
import 'package:jeeves/widgets/app_title_bar/app_title_bar.dart';
import 'package:jeeves/widgets/state_surfaces.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/app_title_bar_test_helpers.dart';
import '../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<Todo> _insertAt(
  GtdDatabase db, {
  required String id,
  String title = 'Test task',
  String intent = 'next',
  String? notes,
}) async {
  final now = DateTime.now();
  await db.customInsert(
    'INSERT INTO todos (id, title, user_id, created_at, intent, notes) '
    'VALUES (?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString(id),
      Variable.withString(title),
      Variable.withString(_userId),
      Variable.withDateTime(now),
      Variable.withString(intent),
      Variable<String>(notes),
    ],
  );
  return (await db.todoDao.getTodo(id))!;
}

(Widget, GoRouter) _buildScreen(
  GtdDatabase db,
  String todoId, {
  Todo? initialTodo,
  List<Tag> initialTags = const [],
  List<Capture> capturedFrom = const [],
  // Stream feeding `taskDetailTodoProvider` — the screen's live subject
  // binding. Tests that delete the row (or fail the query) underneath an open
  // screen own a controller here, exactly as a live Drift watch would emit,
  // without leaving a pending timer behind on dispose.
  Stream<Todo?>? todoStream,
  // Plan-section feeds (issue #475). Stubbed like the other row streams so a
  // live Drift watch's zero-duration close timer never outlives the test; the
  // journey test owns controllers here and drives them off real DAO reads.
  Stream<Action?>? currentActionStream,
  Stream<List<Action>>? plannedActionsStream,
  // History feed (issue #478) — same stubbing rule as the two above. Render-only
  // tests pass `terminatedActions` (a fresh `Stream.value` is built per provider
  // build, so a re-subscribe cannot hit "already listened to"); the journey
  // tests own a broadcast controller and pass `terminatedActionsStream`.
  List<TerminatedAction> terminatedActions = const [],
  Stream<List<TerminatedAction>>? terminatedActionsStream,
}) {
  final router = GoRouter(
    initialLocation: '/inbox',
    routes: [
      GoRoute(
        path: '/inbox',
        builder: (_, _) => const Scaffold(body: Text('Inbox')),
      ),
      GoRoute(
        path: '/task/:id',
        builder: (context, state) => TaskDetailScreen(
          todoId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/focus/active',
        builder: (_, _) => const Scaffold(body: Text('Active focus')),
      ),
    ],
  );

  final widget = ProviderScope(
    overrides: [
      inboxItemsProvider.overrideWith((_) => Stream.value([])),
      databaseProvider.overrideWithValue(db),
      taskDetailTodoProvider(todoId)
          .overrideWith((_) => todoStream ?? Stream.value(initialTodo)),
      taskTagsProvider(todoId)
          .overrideWith((_) => Stream.value(initialTags)),
      // Stubbed like the other row streams above: a live Drift query stream
      // here would schedule a zero-duration close timer on dispose that
      // outlives the test ("A Timer is still pending…"). The DAO query itself
      // is covered by capture_dao_test; this file covers the rendering.
      capturesForOutcomeProvider(todoId)
          .overrideWith((_) => Stream.value(capturedFrom)),
      currentActionProvider(todoId)
          .overrideWith((_) => currentActionStream ?? Stream.value(null)),
      plannedActionsProvider(todoId)
          .overrideWith((_) => plannedActionsStream ?? Stream.value([])),
      terminatedActionsProvider(todoId).overrideWith(
          (_) => terminatedActionsStream ?? Stream.value(terminatedActions)),
      projectTagsProvider.overrideWith((_) => Stream.value([])),
      contextTagsProvider.overrideWith((_) => Stream.value([])),
    ],
    child: MaterialApp.router(routerConfig: router),
  );

  return (widget, router);
}

Future<void> _showTaskDetail(
  WidgetTester tester,
  Widget widget,
  GoRouter router,
  String todoId,
) async {
  await tester.pumpWidget(widget);
  await tester.pump();
  router.push('/task/$todoId');
  await tester.pump();
  // Past the end of the push transition: mid-transition the page is still
  // transformed, so a tap on a title-bar action lands off the surface.
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(configureSqliteForTests);

  group('TaskDetailScreen', () {
    late GtdDatabase db;

    setUp(() {
      // The Start focus affordance reads sprintTimerProvider, whose build
      // restores state from SharedPreferences.
      SharedPreferences.setMockInitialValues({});
      db = _openInMemory();
    });
    tearDown(() async => db.close());

    testWidgets('shows title field with current title', (tester) async {
      final todo = await _insertAt(db, id: 'task1', title: 'Fix the bug');
      final (widget, router) = _buildScreen(db, 'task1', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'task1');

      // Twice over: the title bar carries the Outcome's read-only identity
      // and the body keeps the editable field.
      expect(find.text('Fix the bug'), findsNWidgets(2));
    });

    testWidgets('hides the Captured from section when there are no links',
        (tester) async {
      final todo = await _insertAt(db, id: 'prov0', title: 'Lone outcome');
      final (widget, router) = _buildScreen(db, 'prov0', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'prov0');

      expect(find.byKey(const Key('captured_from_section')), findsNothing);
      expect(find.textContaining('Captured from'), findsNothing);
    });

    testWidgets('shows Captured from with the source Capture when linked',
        (tester) async {
      final todo = await _insertAt(db, id: 'prov1', title: 'Draft outline');
      final (widget, router) = _buildScreen(
        db,
        'prov1',
        initialTodo: todo,
        capturedFrom: [
          Capture(
            id: 'cap1',
            title: 'Project X',
            createdAt: DateTime.utc(2026, 7, 1),
            userId: _userId,
          ),
        ],
      );
      await _showTaskDetail(tester, widget, router, 'prov1');
      // Let the provenance stream emit.
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Captured from 1 capture'), findsOneWidget);

      // Expanding reveals the raw captured fragment as provenance. The section
      // sits below the fold, so scroll it into view before tapping.
      final tile = find.byKey(const Key('captured_from_section'));
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.text('Project X'), findsOneWidget);
    });

    testWidgets('status pill shows Next Actions when no person tags assigned', (tester) async {
      final todo = await _insertAt(db, id: 'task5', title: 'Task without tags');
      final (widget, router) = _buildScreen(db, 'task5', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'task5');

      expect(find.text('Next Actions'), findsOneWidget);
    });

    testWidgets('status pill shows Waiting For when person tags assigned', (tester) async {
      final todo = await _insertAt(db, id: 'task8', title: 'Task with person tag');
      final personTag = Tag(
        id: 'ptag1',
        name: 'Alice',
        type: 'person',
        color: null,
        userId: _userId,
      );
      final (widget, router) = _buildScreen(
        db,
        'task8',
        initialTodo: todo,
        initialTags: [personTag],
      );
      await _showTaskDetail(tester, widget, router, 'task8');

      expect(find.text('Waiting For Alice'), findsOneWidget);
    });

    testWidgets('energy level segmented button shows after tap',
        (tester) async {
      final todo = await _insertAt(db, id: 'task6', title: 'Energy task');
      final (widget, router) = _buildScreen(db, 'task6', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'task6');

      await tester.tap(find.text('Energy'));
      await tester.pumpAndSettle();

      expect(find.text('Low'), findsOneWidget);
      expect(find.text('Medium'), findsOneWidget);
      expect(find.text('High'), findsOneWidget);
    });

    testWidgets('status sheet shows Next Actions tile for Maybe todo', (tester) async {
      final todo = await _insertAt(db, id: 'maybe1', title: 'Maybe task', intent: 'maybe');
      final (widget, router) = _buildScreen(db, 'maybe1', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'maybe1');

      await tester.tap(find.byKey(const Key('status_pill')));
      await tester.pumpAndSettle();

      expect(find.text('Next Actions'), findsOneWidget);

      await tester.tap(find.widgetWithText(ListTile, 'Next Actions'));
      await tester.pumpAndSettle();
      final updated = await db.todoDao.getTodo('maybe1');
      expect(updated!.intent, 'next');
    });

    testWidgets('status sheet does not show Next Actions tile for a Next todo', (tester) async {
      final todo = await _insertAt(db, id: 'next1', title: 'Next task', intent: 'next');
      final (widget, router) = _buildScreen(db, 'next1', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'next1');

      await tester.tap(find.byKey(const Key('status_pill')));
      await tester.pumpAndSettle();

      expect(find.descendant(of: find.byType(ListTile), matching: find.text('Next Actions')), findsNothing);
    });

    // -------------------------------------------------------------------------
    // Ad-hoc engagement (issue #180, D1): the task detail screen carries a
    // "Start focus" affordance that works without an open FocusSession —
    // engagement is independent of FocusSession (ADR-0005); the TimeLog is
    // ad hoc with a null session FK.
    // -------------------------------------------------------------------------

    testWidgets('renders a Start focus affordance', (tester) async {
      final todo = await _insertAt(db, id: 'engage1', title: 'Engageable');
      final (widget, router) = _buildScreen(db, 'engage1', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'engage1');

      // Overflow-aware helper: finds the action wherever the breakpoint put it.
      expect(await findBarAction(tester, const Key('task_detail_start_focus')),
          findsOneWidget);
    });

    testWidgets('pins the global capture action in the bar (#458)',
        (tester) async {
      final todo = await _insertAt(db, id: 'cap1', title: 'Anything');
      final (widget, router) = _buildScreen(db, 'cap1', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'cap1');

      // Capture is reachable from this pushed route — the pinned slot, never
      // overflowed (task detail has at most Start focus + capture = 2).
      // Direct find.byKey, not findBarAction: proves capture is in the bar
      // itself, not merely discoverable via the ⋮ overflow menu.
      expect(find.byKey(const Key('capture_action')), findsOneWidget);
    });

    testWidgets(
        'Start focus is an icon action in the title bar, keeping the primary '
        'blue', (tester) async {
      final todo = await _insertAt(db, id: 'engage0', title: 'Engageable');
      final (widget, router) = _buildScreen(db, 'engage0', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'engage0');

      // This test asserts the *in-bar* rendering specifically — Start focus was
      // demoted from a labelled FilledButton to an icon that stays in the bar —
      // so it scopes the finder to the AppTitleBar directly rather than going
      // through the overflow helper, which would also match an overflowed copy.
      final action = find.descendant(
        of: find.byType(AppTitleBar),
        matching: find.byKey(const Key('task_detail_start_focus')),
      );
      final button = tester.widget<IconButton>(action);
      expect(button.tooltip, 'Start focus',
          reason: 'the label survives as the tooltip');
      expect((button.icon as Icon).color, const Color(0xFF2667B7),
          reason: 'demoted to an icon, but it keeps its call-to-action colour');
      expect(find.byType(FilledButton), findsNothing,
          reason: 'no labelled button left in the chrome');
    });

    testWidgets('the title bar shows the project as the overline',
        (tester) async {
      final todo = await _insertAt(db, id: 'proj1', title: 'Draft the spec');
      final (widget, router) = _buildScreen(
        db,
        'proj1',
        initialTodo: todo,
        initialTags: [
          Tag(
            id: 'tag1',
            name: 'Kitchen remodel',
            type: 'project',
            userId: _userId,
          ),
        ],
      );
      await _showTaskDetail(tester, widget, router, 'proj1');

      final bar = tester.widget<AppTitleBar>(find.byType(AppTitleBar));
      expect(bar.title, 'Draft the spec');
      expect(bar.overline?.label, 'Kitchen remodel');
      expect(bar.overline?.icon, Icons.folder_outlined);
    });

    testWidgets('no project means no overline', (tester) async {
      final todo = await _insertAt(db, id: 'proj0', title: 'Unfiled');
      final (widget, router) = _buildScreen(db, 'proj0', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'proj0');

      final bar = tester.widget<AppTitleBar>(find.byType(AppTitleBar));
      expect(bar.overline, isNull);
    });

    testWidgets('does not render Start focus on a completed task',
        (tester) async {
      final todo = await _insertAt(db, id: 'done1', title: 'Done task');
      final done = todo.copyWith(
        doneAt: Value(DateTime.now().toUtc().toIso8601String()),
      );
      final (widget, router) = _buildScreen(db, 'done1', initialTodo: done);
      await _showTaskDetail(tester, widget, router, 'done1');

      // Absence: findBarAction can only assert presence (it fails when the
      // action is nowhere), so a direct find.byKey is the right tool here, plus
      // an assertion that nothing overflowed into a ⋮ menu either.
      expect(find.byKey(const Key('task_detail_start_focus')), findsNothing);
      expect(find.byKey(appTitleBarOverflowKey), findsNothing);
    });

    testWidgets(
        'Start focus with no open FocusSession opens an ad-hoc TimeLog and '
        'navigates to /focus/active', (tester) async {
      final todo = await _insertAt(db, id: 'engage2', title: 'Engageable');
      final (widget, router) = _buildScreen(db, 'engage2', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'engage2');

      // No FocusSession is open — the affordance must still engage.
      expect(await db.focusSessionDao.getActiveSession(), isNull);

      await tapBarAction(tester, const Key('task_detail_start_focus'));
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpAndSettle();

      expect(find.text('Active focus'), findsOneWidget);

      // Drift watch-streams only emit inside the real async zone.
      final log =
          await tester.runAsync(() => db.timeLogDao.watchActiveLog().first);
      expect(log, isNotNull, reason: 'engagement opens a TimeLog');
      expect(log!.taskId, 'engage2');
      expect(log.focusSessionId, isNull,
          reason: 'no session open → the TimeLog is ad hoc (ADR-0005)');
    });

    testWidgets(
        'Start focus while a different task is in focus surfaces the '
        'conflict and preserves the existing engagement', (tester) async {
      await _insertAt(db, id: 'other', title: 'Other task');
      final todo = await _insertAt(db, id: 'engage3', title: 'Engageable');
      final (widget, router) = _buildScreen(db, 'engage3', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'engage3');

      // Engage the other task first (ad hoc — engagement is sequential).
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TaskDetailScreen)),
      );
      await tester.runAsync(
        () => container.read(focusModeProvider.notifier).startFocus('other'),
      );

      await tapBarAction(tester, const Key('task_detail_start_focus'));
      await tester.pumpAndSettle();

      expect(find.text('Active focus'), findsNothing,
          reason: 'no navigation while another engagement is live');
      expect(
        find.text(
            'Another task is already in focus — finish or stop it first.'),
        findsOneWidget,
      );
      final log =
          await tester.runAsync(() => db.timeLogDao.watchActiveLog().first);
      expect(log!.taskId, 'other',
          reason: 'the existing engagement is untouched');
    });

    testWidgets(
        'Start focus while a sprint persists for a different task (post-'
        'restart) surfaces the conflict and opens no TimeLog', (tester) async {
      // A maxed focus-overtime sprint restores as active without arming a
      // ticker — the persisted-sprint-survives-restart scenario where the
      // in-memory focus state is empty but the sprint is still attached.
      SharedPreferences.setMockInitialValues({
        'sprint_active_task_id': 'other',
        'sprint_active_task_title': 'Other task',
        'sprint_phase': 'focus_overtime',
        'sprint_end_time': DateTime.now().toUtc().toIso8601String(),
      });

      await _insertAt(db, id: 'other', title: 'Other task');
      final todo = await _insertAt(db, id: 'engage4', title: 'Engageable');
      final (widget, router) = _buildScreen(db, 'engage4', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'engage4');

      // Instantiate the provider (in production the shell watches it long
      // before a task-detail tap) and let its async prefs restore complete.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TaskDetailScreen)),
      );
      container.read(sprintTimerProvider);
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpAndSettle();

      await tapBarAction(tester, const Key('task_detail_start_focus'));
      await tester.pumpAndSettle();

      expect(find.text('Active focus'), findsNothing);
      expect(
        find.text(
            'Another task is already in focus — finish or stop it first.'),
        findsOneWidget,
      );
      final log =
          await tester.runAsync(() => db.timeLogDao.watchActiveLog().first);
      expect(log, isNull,
          reason: 'no TimeLog may open while a sprint is attached elsewhere');
    });

    testWidgets(
        'Start focus with a matching sprint does not mask a Focus owned by '
        'a different task — the conflict is surfaced', (tester) async {
      // Sprint belongs to the tapped task; the in-memory Focus belongs to
      // another. A match on one tracker must not short-circuit past the
      // conflict on the other.
      SharedPreferences.setMockInitialValues({
        'sprint_active_task_id': 'engage5',
        'sprint_active_task_title': 'Engageable',
        'sprint_phase': 'focus_overtime',
        'sprint_end_time': DateTime.now().toUtc().toIso8601String(),
      });

      await _insertAt(db, id: 'other', title: 'Other task');
      final todo = await _insertAt(db, id: 'engage5', title: 'Engageable');
      final (widget, router) = _buildScreen(db, 'engage5', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'engage5');

      final container = ProviderScope.containerOf(
        tester.element(find.byType(TaskDetailScreen)),
      );
      container.read(sprintTimerProvider);
      await tester.runAsync(() => pumpEventQueue());
      await tester.runAsync(
        () => container.read(focusModeProvider.notifier).startFocus('other'),
      );

      await tapBarAction(tester, const Key('task_detail_start_focus'));
      await tester.pumpAndSettle();

      expect(find.text('Active focus'), findsNothing,
          reason: 'a matching sprint must not mask the conflicting Focus');
      expect(
        find.text(
            'Another task is already in focus — finish or stop it first.'),
        findsOneWidget,
      );
    });

    testWidgets(
        'Start focus with a matching Focus does not mask a sprint owned by '
        'a different task — the conflict is surfaced', (tester) async {
      // The inverse divergence: Focus belongs to the tapped task; a
      // persisted sprint belongs to another.
      SharedPreferences.setMockInitialValues({
        'sprint_active_task_id': 'other',
        'sprint_active_task_title': 'Other task',
        'sprint_phase': 'focus_overtime',
        'sprint_end_time': DateTime.now().toUtc().toIso8601String(),
      });

      await _insertAt(db, id: 'other', title: 'Other task');
      final todo = await _insertAt(db, id: 'engage6', title: 'Engageable');
      final (widget, router) = _buildScreen(db, 'engage6', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'engage6');

      final container = ProviderScope.containerOf(
        tester.element(find.byType(TaskDetailScreen)),
      );
      container.read(sprintTimerProvider);
      await tester.runAsync(() => pumpEventQueue());
      await tester.runAsync(
        () =>
            container.read(focusModeProvider.notifier).startFocus('engage6'),
      );

      await tapBarAction(tester, const Key('task_detail_start_focus'));
      await tester.pumpAndSettle();

      expect(find.text('Active focus'), findsNothing,
          reason: 'a matching Focus must not mask the conflicting sprint');
      expect(
        find.text(
            'Another task is already in focus — finish or stop it first.'),
        findsOneWidget,
      );
    });
  });

  group('TaskDetailScreen — restore (issue #408)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    Future<void> openStatusSheet(
      WidgetTester tester,
      String todoId,
      Todo todo,
    ) async {
      final (widget, router) = _buildScreen(db, todoId, initialTodo: todo);
      await _showTaskDetail(tester, widget, router, todoId);
      await tester.tap(find.byKey(const Key('status_pill')));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'trashed Outcome: sheet offers Restore to Next and Restore to '
        'Someday/Maybe, no single Restore', (tester) async {
      final todo =
          await _insertAt(db, id: 'rt1', title: 'Trashed', intent: 'trash');
      await openStatusSheet(tester, 'rt1', todo);

      expect(find.widgetWithText(ListTile, 'Restore to Next'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Restore to Someday/Maybe'),
          findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Restore'), findsNothing);
    });

    testWidgets(
        'Restore to Next: intent=next, done_at cleared, last_clarified_at '
        'stamped; reappears on Next, gone from Trash; row persists',
        (tester) async {
      // Completed-then-trashed via the production transitions, in that order.
      await _insertAt(db, id: 'rt2', title: 'Trashed');
      await db.todoDao.markDone('rt2');
      await db.todoDao.setIntent('rt2', Intent.trash);
      // Wipe the stamp so the restore's own stamp is observable.
      await (db.update(db.todos)..where((t) => t.id.equals('rt2')))
          .write(const TodosCompanion(lastClarifiedAt: Value(null)));
      final todo = (await db.todoDao.getTodo('rt2'))!;

      await openStatusSheet(tester, 'rt2', todo);
      await tester.tap(find.widgetWithText(ListTile, 'Restore to Next'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('rt2');
      expect(row, isNotNull, reason: 'restore never deletes the row (AC 4)');
      expect(row!.intent, 'next');
      expect(row.doneAt, isNull,
          reason: 'cleanup invariant: restore clears done_at');
      expect(row.lastClarifiedAt, isNotNull,
          reason: 'restore stamps last_clarified_at (AC 3)');
      // Drift watch-streams only emit inside the real async zone, so take
      // their snapshots under runAsync (see periodic_review_footer_test).
      final next =
          (await tester.runAsync(() => db.todoDao.watchNext().first))!;
      expect(next.map((t) => t.id), contains('rt2'),
          reason: 'restored Outcome reappears on the Next List (AC 2)');
      final trash =
          (await tester.runAsync(() => db.todoDao.watchTrash().first))!;
      expect(trash.any((t) => t.id == 'rt2'), isFalse);
    });

    testWidgets(
        'Restore to Someday/Maybe on a completed-then-trashed Outcome '
        'reappears on the Maybe List', (tester) async {
      // Completed-then-trashed via the production transitions, in that order.
      await _insertAt(db, id: 'rt3', title: 'Trashed');
      await db.todoDao.markDone('rt3');
      await db.todoDao.setIntent('rt3', Intent.trash);
      final todo = (await db.todoDao.getTodo('rt3'))!;

      await openStatusSheet(tester, 'rt3', todo);
      await tester
          .tap(find.widgetWithText(ListTile, 'Restore to Someday/Maybe'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('rt3');
      expect(row, isNotNull, reason: 'restore never deletes the row (AC 4)');
      expect(row!.intent, 'maybe');
      expect(row.doneAt, isNull);
      final maybe =
          (await tester.runAsync(() => db.todoDao.watchMaybe().first))!;
      expect(maybe.map((t) => t.id), contains('rt3'),
          reason: 'restored Outcome reappears on the Maybe List (AC 2)');
    });

    testWidgets(
        'done-only Outcome keeps the single Restore tile and restores to '
        'Next (regression guard for the applyRouting rewire)',
        (tester) async {
      await _insertAt(db, id: 'rt4', title: 'Completed');
      await db.todoDao.markDone('rt4');
      await (db.update(db.todos)..where((t) => t.id.equals('rt4')))
          .write(const TodosCompanion(lastClarifiedAt: Value(null)));
      final todo = (await db.todoDao.getTodo('rt4'))!;

      await openStatusSheet(tester, 'rt4', todo);

      expect(find.widgetWithText(ListTile, 'Restore'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Restore to Next'), findsNothing);
      expect(find.widgetWithText(ListTile, 'Restore to Someday/Maybe'),
          findsNothing);

      await tester.tap(find.widgetWithText(ListTile, 'Restore'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('rt4');
      expect(row!.intent, 'next');
      expect(row.doneAt, isNull);
      expect(row.lastClarifiedAt, isNotNull);
    });

    testWidgets(
        'status pill shows Trashed for a completed-then-trashed Outcome '
        '(Trash stance wins over the Completion fact)', (tester) async {
      // Completed-then-trashed via the production transitions, in that order.
      await _insertAt(db, id: 'rt5', title: 'Discarded idea');
      await db.todoDao.markDone('rt5');
      await db.todoDao.setIntent('rt5', Intent.trash);
      final todo = (await db.todoDao.getTodo('rt5'))!;

      final (widget, router) = _buildScreen(db, 'rt5', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'rt5');

      expect(find.text('Trashed'), findsOneWidget);
      expect(find.text('Done'), findsNothing);
    });

    testWidgets('an Outcome deleted while open reaches the missing state',
        (tester) async {
      await _insertAt(db, id: 'gone', title: 'Buy milk');
      final todo = (await db.todoDao.getTodo('gone'))!;
      final feed = StreamController<Todo?>.broadcast();
      addTearDown(feed.close);

      final (widget, router) =
          _buildScreen(db, 'gone', todoStream: feed.stream);
      await _showTaskDetail(tester, widget, router, 'gone');
      feed.add(todo);
      await tester.pumpAndSettle();
      // Title bar and editable field both carry the title.
      expect(find.text('Buy milk'), findsNWidgets(2));

      // The row leaves local storage. That is the whole signal the screen has.
      await db.todoDao.deleteOutcome('gone');
      feed.add(null);
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('This item is no longer here'), findsOneWidget);

      // And the missing state is not a dead end.
      await tester.tap(find.text('Go back'));
      await tester.pumpAndSettle();
      expect(find.text('Inbox'), findsOneWidget);
    });

    testWidgets('a failed Outcome query renders an error without leaking it',
        (tester) async {
      final feed = StreamController<Todo?>.broadcast();
      addTearDown(feed.close);

      final (widget, router) =
          _buildScreen(db, 'boom', todoStream: feed.stream);
      await _showTaskDetail(tester, widget, router, 'boom');
      feed.addError(Exception('watch failed'));
      await tester.pumpAndSettle();

      expect(find.byKey(ErrorSurface.surfaceKey), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // Raw exception text is not user-facing copy.
      expect(find.textContaining('watch failed'), findsNothing);
      expect(find.text('This item is no longer here'), findsNothing);
    });

    testWidgets(
        'the non-data surfaces keep the loaded screen\'s back affordance',
        (tester) async {
      await _insertAt(db, id: 'chrome', title: 'Buy milk');
      final todo = (await db.todoDao.getTodo('chrome'))!;
      final feed = StreamController<Todo?>.broadcast();
      addTearDown(feed.close);

      final (widget, router) =
          _buildScreen(db, 'chrome', todoStream: feed.stream);
      await _showTaskDetail(tester, widget, router, 'chrome');
      feed.add(todo);
      await tester.pumpAndSettle();

      // The affordance the loaded screen offers.
      expect(find.byIcon(Icons.arrow_back_ios_new), findsOneWidget);

      // The row leaves local storage underneath the open screen. The chrome
      // the user is looking at must not change shape just because the body
      // did — an implicit leading would swap in the platform default back
      // icon and route the tap through Navigator.maybePop instead.
      feed.add(null);
      await tester.pumpAndSettle();

      expect(find.text('This item is no longer here'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_ios_new), findsOneWidget);

      // And it still goes back where the loaded screen's does.
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
      await tester.pumpAndSettle();
      expect(find.text('Inbox'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // The Plan section (planned queue, issue #475). The UI drives the real
  // TaskDetailNotifier → real ActionDao against the in-memory db; the two
  // plan-section streams are hand-cranked off real DAO reads after each gesture
  // (the same pattern the other row streams use, so no live Drift close-timer
  // outlives the test).
  // ---------------------------------------------------------------------------
  group('TaskDetailScreen — Plan section (issue #475)', () {
    late GtdDatabase db;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      db = _openInMemory();
    });
    tearDown(() async => db.close());

    testWidgets(
        'journey: add → reorder → edit → promote (Actionless) → demote → '
        'replace via confirm sheet → remove', (tester) async {
      final todo =
          await _insertAt(db, id: 'plan1', title: 'Plan outcome');
      final curCtrl = StreamController<Action?>.broadcast();
      final plnCtrl = StreamController<List<Action>>.broadcast();
      addTearDown(curCtrl.close);
      addTearDown(plnCtrl.close);

      Future<List<Action>> plannedRows() async =>
          (await tester.runAsync(() => db.actionDao.getPlannedActions('plan1')))!;
      Future<Action?> currentRow() async => await tester
          .runAsync<Action?>(() => db.actionDao.getCurrentAction('plan1'));
      Future<DateTime?> stamp() async =>
          (await tester.runAsync(() => db.todoDao.getTodo('plan1')))!
              .lastClarifiedAt;

      Future<void> refresh() async {
        curCtrl.add(await currentRow());
        plnCtrl.add(await plannedRows());
        await tester.pump();
        await tester.pump();
      }

      Future<void> settleWrite() =>
          tester.runAsync(() => Future<void>.delayed(
                const Duration(milliseconds: 20),
              ));

      final (widget, router) = _buildScreen(
        db,
        'plan1',
        initialTodo: todo,
        currentActionStream: curCtrl.stream,
        plannedActionsStream: plnCtrl.stream,
      );
      await _showTaskDetail(tester, widget, router, 'plan1');
      await refresh();

      // Planless: the anchor placeholder and the empty-plan copy render.
      expect(find.byKey(const Key('plan_section')), findsOneWidget);
      expect(find.text('No current action'), findsOneWidget);
      expect(
        find.text("No plan yet — add the actions you're thinking of."),
        findsOneWidget,
      );

      Future<void> addPlanned(String text) async {
        await tester.tap(find.byKey(const Key('plan_add_trigger')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('plan_action_text')), text);
        await tester.pump();
        await tester.tap(find.byKey(const Key('plan_action_confirm')));
        await tester.pumpAndSettle();
        await settleWrite();
        await refresh();
      }

      // --- Add two planned actions ---
      await addPlanned('first');
      await addPlanned('second');
      var rows = await plannedRows();
      expect(rows.map((a) => a.actionText), ['first', 'second']);
      expect(find.text('first'), findsOneWidget);
      expect(find.text('second'), findsOneWidget);

      // --- Reorder (invoke the ReorderableListView callback: drag is flaky in
      // widget tests; the DAO reorder is covered deterministically in
      // action_dao_test) ---
      final rlv =
          tester.widget<ReorderableListView>(find.byType(ReorderableListView));
      rlv.onReorderItem!(1, 0); // move 'second' to the front
      await settleWrite();
      await refresh();
      rows = await plannedRows();
      expect(rows.map((a) => a.actionText), ['second', 'first']);

      // --- Edit the front row through the sheet ---
      await tester.tap(find.text('second'));
      await tester.pumpAndSettle();
      expect(find.text('Edit planned action'), findsOneWidget);
      await tester.enterText(
          find.byKey(const Key('plan_action_text')), 'second (edited)');
      await tester.pump();
      await tester.tap(find.byKey(const Key('plan_action_confirm')));
      await tester.pumpAndSettle();
      await settleWrite();
      await refresh();
      rows = await plannedRows();
      expect(rows.first.actionText, 'second (edited)');

      final beforePromote = await stamp();

      // --- Promote the front row while Actionless (direct promote) ---
      await tester.tap(find.byKey(Key('plan_promote_${rows.first.id}')));
      await settleWrite();
      await refresh();
      final promoted = await currentRow();
      expect(promoted, isNotNull);
      expect(promoted!.actionText, 'second (edited)');
      expect(find.byKey(const Key('plan_current_action')), findsOneWidget);
      expect((await stamp())!.isAfter(beforePromote!), isTrue,
          reason: 'promote stamps');

      // --- Demote it back to the plan ---
      await tester.tap(find.byKey(const Key('plan_demote_button')));
      await settleWrite();
      await refresh();
      expect(await currentRow(), isNull);

      // Promote 'first' directly so a current exists for the replace path.
      rows = await plannedRows();
      final firstRow = rows.firstWhere((a) => a.actionText == 'first');
      await tester.tap(find.byKey(Key('plan_promote_${firstRow.id}')));
      await settleWrite();
      await refresh();
      expect((await currentRow())!.actionText, 'first');

      // --- Replace the current via the confirm sheet (supersede-and-promote) ---
      rows = await plannedRows();
      final replacement = rows.firstWhere(
          (a) => a.actionText == 'second (edited)');
      await tester.tap(find.byKey(Key('plan_promote_${replacement.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Replace current action?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('plan_replace_confirm')));
      await tester.pumpAndSettle();
      await settleWrite();
      await refresh();
      expect((await currentRow())!.actionText, 'second (edited)');
      // The replaced Action is superseded (retired), not hard-deleted. Watching
      // the planned queue can't tell the two apart — it omits the old current
      // either way — so read the row directly and assert its role flipped to
      // 'superseded'.
      final firstAfterReplace = await tester.runAsync(() => (db.select(db.actions)
            ..where((a) =>
                a.outcomeId.equals('plan1') & a.actionText.equals('first')))
          .getSingleOrNull());
      expect(firstAfterReplace, isNotNull,
          reason: 'supersede retires the old current row, it is not deleted');
      expect(firstAfterReplace!.role, 'superseded',
          reason: 'replacing the current supersedes the old current Action');
      expect((await plannedRows()).map((a) => a.actionText),
          isNot(contains('first')),
          reason: 'a superseded row never leaks back into the planned queue');

      // --- Remove the remaining planned row ---
      // After the replace, 'first' is superseded and nothing is planned; add a
      // throwaway planned row and remove it to exercise the remove affordance.
      await addPlanned('scratch');
      rows = await plannedRows();
      final scratch = rows.firstWhere((a) => a.actionText == 'scratch');
      await tester.tap(find.byKey(Key('plan_remove_${scratch.id}')));
      await settleWrite();
      await refresh();
      expect((await plannedRows()).map((a) => a.actionText),
          isNot(contains('scratch')));
    });
  });

  // ---------------------------------------------------------------------------
  // Planned-row effort pickers (issue #477). Same hand-cranked harness as the
  // journey above.
  //
  // The Outcome-column assertions read `db.todos` **raw**, never `getTodo`:
  // that one carries the D2 projection, which COALESCEs the current Action's
  // value over the column, so a missing mirror would still satisfy it.
  // ---------------------------------------------------------------------------
  group('TaskDetailScreen — planned-row effort (issue #477)', () {
    late GtdDatabase db;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      db = _openInMemory();
    });
    tearDown(() async => db.close());

    /// Everything a plan-section test needs: the mounted screen plus the
    /// hand-cranked stream refresh and the DAO reads behind it.
    Future<
        ({
          Future<void> Function() refresh,
          Future<void> Function() settleWrite,
          Future<List<Action>> Function() plannedRows,
          Future<Action?> Function() currentRow,
          Future<({String? energy, int? time})> Function() todoColumns,
        })> mountPlan(WidgetTester tester, String id) async {
      final todo = await _insertAt(db, id: id, title: 'Plan outcome');
      final curCtrl = StreamController<Action?>.broadcast();
      final plnCtrl = StreamController<List<Action>>.broadcast();
      addTearDown(curCtrl.close);
      addTearDown(plnCtrl.close);

      Future<List<Action>> plannedRows() async =>
          (await tester.runAsync(() => db.actionDao.getPlannedActions(id)))!;
      Future<Action?> currentRow() async => await tester
          .runAsync<Action?>(() => db.actionDao.getCurrentAction(id));
      Future<({String? energy, int? time})> todoColumns() async {
        final row = await tester.runAsync(
            () => (db.select(db.todos)..where((t) => t.id.equals(id)))
                .getSingle());
        return (energy: row!.energyLevel, time: row.timeEstimate);
      }

      Future<void> refresh() async {
        curCtrl.add(await currentRow());
        plnCtrl.add(await plannedRows());
        await tester.pump();
        await tester.pump();
      }

      Future<void> settleWrite() => tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));

      final (widget, router) = _buildScreen(
        db,
        id,
        initialTodo: todo,
        currentActionStream: curCtrl.stream,
        plannedActionsStream: plnCtrl.stream,
      );
      await _showTaskDetail(tester, widget, router, id);
      await refresh();
      return (
        refresh: refresh,
        settleWrite: settleWrite,
        plannedRows: plannedRows,
        currentRow: currentRow,
        todoColumns: todoColumns,
      );
    }

    /// Taps an energy chip *inside the sheet* — scoped, because a planned row
    /// behind the modal renders the same label.
    Future<void> pickEnergy(WidgetTester tester, String label) async {
      await tester.tap(find.descendant(
        of: find.byKey(const Key('plan_action_energy')),
        matching: find.text(label),
      ));
      await tester.pump();
    }

    Future<void> pickEstimate(WidgetTester tester, String label) async {
      await tester.tap(find.descendant(
        of: find.byKey(const Key('plan_action_estimate')),
        matching: find.text(label),
      ));
      await tester.pump();
    }

    testWidgets(
        'journey: add with effort → chips render → edit via sheet → promote '
        'mirrors onto the Outcome columns', (tester) async {
      final h = await mountPlan(tester, 'eff1');

      // --- Add, setting both effort attributes in the sheet ---
      await tester.tap(find.byKey(const Key('plan_add_trigger')));
      await tester.pumpAndSettle();
      expect(find.text('Add planned action'), findsWidgets);
      await tester.enterText(
          find.byKey(const Key('plan_action_text')), 'draft the brief');
      await tester.pump();
      await pickEnergy(tester, 'High');
      await pickEstimate(tester, '45m');
      await tester.tap(find.byKey(const Key('plan_action_confirm')));
      await tester.pumpAndSettle();
      await h.settleWrite();
      await h.refresh();

      var rows = await h.plannedRows();
      expect(rows.single.actionText, 'draft the brief');
      expect(rows.single.energyLevel, 'high');
      expect(rows.single.timeEstimate, 45);

      // The row renders both chips.
      final rowId = rows.single.id;
      expect(find.byKey(Key('planned_energy_$rowId')), findsOneWidget);
      expect(find.byKey(Key('planned_time_$rowId')), findsOneWidget);
      expect(find.byKey(Key('planned_effort_unset_$rowId')), findsNothing);

      // A planned row must not touch the Outcome columns: D2 would read its
      // value back as the *current* Action's.
      expect((await h.todoColumns()).energy, isNull);
      expect((await h.todoColumns()).time, isNull);

      // --- Edit through the sheet: the pickers open prefilled ---
      await tester.tap(find.text('draft the brief'));
      await tester.pumpAndSettle();
      expect(find.text('Edit planned action'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('plan_action_text')))
            .controller!
            .text,
        'draft the brief',
        reason: 'the sheet prefills from the row it was opened on',
      );
      await pickEnergy(tester, 'Low');
      await pickEstimate(tester, '15m');
      await tester.tap(find.byKey(const Key('plan_action_confirm')));
      await tester.pumpAndSettle();
      await h.settleWrite();
      await h.refresh();

      rows = await h.plannedRows();
      expect(rows.single.energyLevel, 'low');
      expect(rows.single.timeEstimate, 15);
      // Chips refresh with the edit.
      expect(find.text('Low'), findsOneWidget);
      expect(find.text('15m'), findsOneWidget);

      // --- Promote: the effort travels, and the mirror is re-established ---
      await tester.tap(find.byKey(Key('plan_promote_$rowId')));
      await h.settleWrite();
      await h.refresh();

      final promoted = await h.currentRow();
      expect(promoted!.energyLevel, 'low');
      expect(promoted.timeEstimate, 15);
      final cols = await h.todoColumns();
      expect(cols.energy, 'low',
          reason: 'promotion re-establishes the D1 mirror');
      expect(cols.time, 15);
    });

    testWidgets('the edit sheet clears both values when the chips are '
        'deselected', (tester) async {
      final h = await mountPlan(tester, 'eff2');
      await tester.runAsync(() => db.actionDao.addPlannedAction(
          'eff2', 'has effort',
          energyLevel: 'high', timeEstimate: 45));
      await h.refresh();
      final rowId = (await h.plannedRows()).single.id;

      await tester.tap(find.text('has effort'));
      await tester.pumpAndSettle();
      // Tapping the selected chip deselects it.
      await pickEnergy(tester, 'High');
      await pickEstimate(tester, '45m');
      await tester.tap(find.byKey(const Key('plan_action_confirm')));
      await tester.pumpAndSettle();
      await h.settleWrite();
      await h.refresh();

      final row = (await h.plannedRows()).single;
      expect(row.energyLevel, isNull,
          reason: 'a null on the draft must map to clearEnergyLevel: true — '
              'ActionDao.editAction reads a bare null as "no change"');
      expect(row.timeEstimate, isNull);
      expect(find.byKey(Key('planned_effort_unset_$rowId')), findsOneWidget);
      expect(find.byKey(Key('planned_energy_$rowId')), findsNothing);
    });

    testWidgets('a planned row with no effort shows the Set affordance and no '
        'chips', (tester) async {
      final h = await mountPlan(tester, 'eff3');
      await tester.runAsync(
          () => db.actionDao.addPlannedAction('eff3', 'no effort yet'));
      await h.refresh();
      final rowId = (await h.plannedRows()).single.id;

      expect(find.byKey(Key('planned_effort_unset_$rowId')), findsOneWidget);
      expect(find.text('Set'), findsOneWidget);
      expect(find.byKey(Key('planned_meta_$rowId')), findsNothing);
    });

    testWidgets('planned row meta chips are read-only', (tester) async {
      final h = await mountPlan(tester, 'eff4');
      await tester.runAsync(() => db.actionDao.addPlannedAction(
          'eff4', 'has effort',
          energyLevel: 'high', timeEstimate: 45));
      await h.refresh();
      final rowId = (await h.plannedRows()).single.id;

      // Scoped to the meta line: the row's own tap GestureDetector is an
      // *ancestor* of it, so it cannot pollute the result.
      final meta = find.byKey(Key('planned_meta_$rowId'));
      expect(meta, findsOneWidget);
      for (final type in [IconButton, TextField, InkWell, GestureDetector]) {
        expect(
          find.descendant(of: meta, matching: find.byType(type)),
          findsNothing,
          reason: 'a chip is a label, not a control — the row is the target',
        );
      }
    });

    testWidgets('the add sheet refuses an empty title', (tester) async {
      final h = await mountPlan(tester, 'eff5');

      await tester.tap(find.byKey(const Key('plan_add_trigger')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('plan_action_confirm')))
            .onPressed,
        isNull,
        reason: 'a blank phrase names no Action',
      );

      // Effort alone does not enable it either.
      await pickEnergy(tester, 'High');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('plan_action_confirm')))
            .onPressed,
        isNull,
      );

      // Dismiss: nothing was written.
      Navigator.of(tester.element(find.byKey(const Key('plan_action_text'))))
          .pop();
      await tester.pumpAndSettle();
      await h.settleWrite();
      await h.refresh();
      expect(await h.plannedRows(), isEmpty);
    });

    testWidgets('the sheet follows the row, not the index, after a reorder',
        (tester) async {
      final h = await mountPlan(tester, 'eff6');
      await tester.runAsync(() async {
        await db.actionDao.addPlannedAction('eff6', 'alpha');
        await db.actionDao.addPlannedAction('eff6', 'beta');
      });
      await h.refresh();
      final before = await h.plannedRows();
      expect(before.map((a) => a.actionText), ['alpha', 'beta']);
      final alphaId = before[0].id;
      final betaId = before[1].id;

      final rlv =
          tester.widget<ReorderableListView>(find.byType(ReorderableListView));
      rlv.onReorderItem!(1, 0); // 'beta' to the front
      await h.settleWrite();
      expect((await h.plannedRows()).map((a) => a.actionText),
          ['beta', 'alpha'],
          reason: 'the reorder landed in the db');

      // Deliberately **not** refreshed here. The tree still holds the
      // pre-reorder list, so 'beta' is at tree index 1 while the db has it at
      // position 0 — and that disagreement is the whole point. Refreshing
      // first would realign index and row, and the test could not fail for its
      // stated reason.
      await tester.tap(find.text('beta'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('plan_action_text')))
            .controller!
            .text,
        'beta',
      );

      // The Save lands on 'beta' itself, not on whatever occupies the slot it
      // was tapped in: a handler resolving a captured `index` against the
      // reordered queue would rewrite 'alpha'.
      await tester.enterText(
          find.byKey(const Key('plan_action_text')), 'beta, revised');
      await tester.pump();
      await tester.tap(find.byKey(const Key('plan_action_confirm')));
      await tester.pumpAndSettle();
      await h.settleWrite();

      final after = await h.plannedRows();
      expect(after.firstWhere((a) => a.id == betaId).actionText,
          'beta, revised');
      expect(after.firstWhere((a) => a.id == alphaId).actionText, 'alpha');
    });

    testWidgets('the planned row and its sheet lay out at 320dp',
        (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final h = await mountPlan(tester, 'eff7');
      // The screen chrome lays out clean at 320dp with no planned row mounted,
      // so every `isNull` below carries real signal about the Plan section's
      // own content rather than inheriting a swallowed baseline overflow. The
      // test font (Ahem renders every glyph as a full em square) makes this
      // the pathological width for the Plan section's fixed-width labels.
      expect(tester.takeException(), isNull,
          reason: 'the screen chrome itself lays out clean at 320dp');

      await tester.runAsync(() => db.actionDao.addPlannedAction(
          'eff7', 'a deliberately long planned action phrase that wraps',
          energyLevel: 'medium', timeEstimate: 90));
      await h.refresh();
      final rowId = (await h.plannedRows()).single.id;

      final row = tester.getRect(find.byKey(Key('planned_action_$rowId')));
      final remove = tester.getRect(find.byKey(Key('plan_remove_$rowId')));
      expect(remove.right, lessThanOrEqualTo(row.right),
          reason: 'the trailing controls stay inside the row at 320dp');
      expect(remove.width, greaterThan(0.0));

      // Both chips fit on the meta line at this width (the Wrap wraps them
      // onto a second line rather than overflowing if a locale pushes past).
      final energy = tester.getRect(find.byKey(Key('planned_energy_$rowId')));
      final time = tester.getRect(find.byKey(Key('planned_time_$rowId')));
      expect(energy.left, greaterThanOrEqualTo(row.left));
      expect(time.right, lessThanOrEqualTo(row.right));
      expect(tester.takeException(), isNull,
          reason: 'the planned row itself adds no overflow at 320dp');

      // The add affordance's label is Flexible, so a phrase wider than the
      // leftover width gives somewhere — but the absence of an overflow
      // exception above cannot tell us where: a label that wraps onto extra
      // lines is exactly as exception-free as one that ellipsises. Pin the
      // truncation configuration itself, since that is the difference. This
      // stays a config assertion on purpose: the English phrase happens to fit
      // one line at 320dp, so no measurable layout distinguishes the two, and
      // it is a longer localisation that would silently start wrapping.
      // Located via the InkWell's key because the same phrase is also the
      // sheet title elsewhere in this file.
      final addLabel = tester.widget<Text>(find.descendant(
        of: find.byKey(const Key('plan_add_trigger')),
        matching: find.byType(Text),
      ));
      expect(addLabel.maxLines, 1);
      expect(addLabel.overflow, TextOverflow.ellipsis);

      // The sheet itself at the same width.
      await tester.tap(find.text('a deliberately long planned action phrase '
          'that wraps'));
      await tester.pumpAndSettle();
      final confirm =
          tester.getRect(find.byKey(const Key('plan_action_confirm')));
      expect(confirm.left, greaterThanOrEqualTo(0.0));
      expect(confirm.right, lessThanOrEqualTo(320.0));
      expect(confirm.width, greaterThan(0.0));
      expect(tester.takeException(), isNull,
          reason: 'no RenderFlex overflow laying out the sheet at 320dp');
    });
  });

  // ---------------------------------------------------------------------------
  // Action history + Abandon (ADR-0001 story 8, issue #478). Same hand-cranked
  // pattern as the Plan-section journey above: the UI drives the real
  // TaskDetailNotifier → real ActionDao against the in-memory db, and the three
  // Action streams are re-read from the DAO after each gesture.
  // ---------------------------------------------------------------------------
  group('TaskDetailScreen — Action history (issue #478)', () {
    late GtdDatabase db;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      db = _openInMemory();
    });
    tearDown(() async => db.close());

    testWidgets('no terminated Actions renders no history section',
        (tester) async {
      final todo = await _insertAt(db, id: 'hist0', title: 'Fresh outcome');
      final (widget, router) = _buildScreen(db, 'hist0', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'hist0');

      expect(find.byKey(const Key('action_history_section')), findsNothing);
      expect(find.byKey(const Key('plan_section')), findsOneWidget,
          reason: 'the Plan section still renders — only history is hidden');
    });

    testWidgets(
        'journey: abandon → history row → complete → history newest-first',
        (tester) async {
      final todo =
          await _insertAt(db, id: 'hist1', title: 'History outcome');
      final curCtrl = StreamController<Action?>.broadcast();
      final plnCtrl = StreamController<List<Action>>.broadcast();
      final hisCtrl = StreamController<List<TerminatedAction>>.broadcast();
      addTearDown(curCtrl.close);
      addTearDown(plnCtrl.close);
      addTearDown(hisCtrl.close);

      Future<Action?> currentRow() async => await tester
          .runAsync<Action?>(() => db.actionDao.getCurrentAction('hist1'));
      Future<List<TerminatedAction>> historyRows() async =>
          (await tester.runAsync(
              () => db.actionDao.getTerminatedActions('hist1')))!;
      Future<DateTime?> stamp() async =>
          (await tester.runAsync(() => db.todoDao.getTodo('hist1')))!
              .lastClarifiedAt;

      Future<void> refresh() async {
        curCtrl.add(await currentRow());
        plnCtrl.add(
            (await tester.runAsync(() => db.actionDao.getPlannedActions('hist1')))!);
        hisCtrl.add(await historyRows());
        await tester.pump();
        await tester.pump();
      }

      Future<void> settleWrite() =>
          tester.runAsync(() => Future<void>.delayed(
                const Duration(milliseconds: 20),
              ));

      final (widget, router) = _buildScreen(
        db,
        'hist1',
        initialTodo: todo,
        currentActionStream: curCtrl.stream,
        plannedActionsStream: plnCtrl.stream,
        terminatedActionsStream: hisCtrl.stream,
      );
      await _showTaskDetail(tester, widget, router, 'hist1');
      await refresh();

      // No current Action → no Abandon affordance to fire.
      expect(find.byKey(const Key('plan_abandon_button')), findsNothing);
      expect(find.byKey(const Key('action_history_section')), findsNothing);

      // --- Give the Outcome a current Action ---
      await tester.runAsync(
          () => db.actionDao.setCurrentAction('hist1', 'write the draft'));
      await refresh();
      expect(find.byKey(const Key('plan_abandon_button')), findsOneWidget);
      final beforeAbandon = await stamp();

      // --- Abandon it through the confirm sheet ---
      await tester.tap(find.byKey(const Key('plan_abandon_button')));
      await tester.pumpAndSettle();
      expect(find.text('Abandon this action?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('plan_abandon_confirm')));
      await tester.pumpAndSettle();
      await settleWrite();
      await refresh();

      expect(await currentRow(), isNull,
          reason: 'abandon mints no replacement current row');
      expect(find.text('No current action'), findsOneWidget);
      final afterAbandon = await historyRows();
      expect(afterAbandon.length, 1);
      expect(afterAbandon.single.action.role, 'superseded');
      expect(afterAbandon.single.action.actionText, 'write the draft');
      expect((await stamp())!.isAfter(beforeAbandon ?? DateTime(2000)), isTrue,
          reason: 'abandon is a clarifying act and stamps');

      // The history section is now visible; expand it and read the row.
      expect(find.byKey(const Key('action_history_section')), findsOneWidget);
      await tester.tap(find.byKey(const Key('action_history_section')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(Key('history_action_${afterAbandon.single.action.id}')),
        findsOneWidget,
      );
      expect(find.text('write the draft'), findsOneWidget);
      expect(find.textContaining('Abandoned '), findsOneWidget);

      // --- A second Action, completed — the newer terminal row sorts first ---
      await tester.runAsync(() => db.actionDao
          .setCurrentAction('hist1', 'send the draft',
              now: DateTime.now().add(const Duration(seconds: 10))));
      await refresh();
      await tester.runAsync(() => db.actionDao.completeCurrentAction('hist1',
          now: DateTime.now().add(const Duration(seconds: 20))));
      await refresh();
      await tester.pumpAndSettle();

      final both = await historyRows();
      expect(both.map((h) => h.action.actionText),
          ['send the draft', 'write the draft'],
          reason: 'newest terminal timestamp first');
      expect(both.first.action.role, 'done');
      expect(find.textContaining('Done '), findsOneWidget);
    });

    testWidgets('history rows are read-only', (tester) async {
      final todo = await _insertAt(db, id: 'hist2', title: 'Read-only outcome');
      final terminated = <TerminatedAction>[
        (
          action: _historyAction(id: 'h-done', text: 'shipped it', role: 'done'),
          loggedMinutes: 25,
        ),
        (
          action: _historyAction(
              id: 'h-super', text: 'dropped it', role: 'superseded'),
          loggedMinutes: 0,
        ),
      ];
      final (widget, router) = _buildScreen(
        db,
        'hist2',
        initialTodo: todo,
        terminatedActions: terminated,
      );
      await _showTaskDetail(tester, widget, router, 'hist2');
      // One more frame: the stubbed stream's first value lands after the push
      // pumps, and Riverpod schedules the dependent rebuild for the next frame.
      await tester.pump();
      await tester.tap(find.byKey(const Key('action_history_section')));
      await tester.pumpAndSettle();

      final section = find.byKey(const Key('action_history_section'));
      final rows = find.byKey(const Key('action_history_rows'));
      expect(find.byKey(const Key('history_action_h-done')), findsOneWidget);
      expect(find.byKey(const Key('history_action_h-super')), findsOneWidget);

      // The invariant a future refactor would silently break: reusing
      // `_buildPlannedRow` for history would inherit promote / remove / inline
      // edit. History is read-only *by construction* — Text and icons only.
      //
      // GestureDetector is scoped to the rows container because the
      // ExpansionTile header legitimately owns exactly one tap target (the
      // expander, which navigates rather than mutates); IconButton and
      // TextField must be absent from the *whole* section — the expander needs
      // neither, so either one appearing means an affordance crept in.
      for (final interactive in <Type>[IconButton, TextField]) {
        expect(
          find.descendant(of: section, matching: find.byType(interactive)),
          findsNothing,
          reason: 'the history section must expose no $interactive',
        );
      }
      for (final interactive in <Type>[
        IconButton,
        TextField,
        GestureDetector,
      ]) {
        expect(
          find.descendant(of: rows, matching: find.byType(interactive)),
          findsNothing,
          reason: 'a history row must expose no $interactive',
        );
      }
    });

    testWidgets('rows show the terminal label and logged minutes',
        (tester) async {
      final todo = await _insertAt(db, id: 'hist3', title: 'Labels outcome');
      final done = _historyAction(
        id: 'h-done',
        text: 'shipped it',
        role: 'done',
        doneAt: DateTime.utc(2026, 3, 4, 12),
      );
      final abandoned = _historyAction(
        id: 'h-super',
        text: 'dropped it',
        role: 'superseded',
        updatedAt: DateTime.utc(2026, 3, 2, 12),
      );
      final (widget, router) = _buildScreen(
        db,
        'hist3',
        initialTodo: todo,
        terminatedActions: <TerminatedAction>[
          (action: done, loggedMinutes: 25),
          (action: abandoned, loggedMinutes: 0),
        ],
      );
      await _showTaskDetail(tester, widget, router, 'hist3');
      await tester.pump();
      await tester.tap(find.byKey(const Key('action_history_section')));
      await tester.pumpAndSettle();

      final doneLabel = _localDateLabel(DateTime.utc(2026, 3, 4, 12));
      final abandonedLabel = _localDateLabel(DateTime.utc(2026, 3, 2, 12));
      expect(find.text('Done $doneLabel · 25m'), findsOneWidget);
      expect(find.text('Abandoned $abandonedLabel'), findsOneWidget,
          reason: 'zero logged minutes are omitted, not rendered as 0m');
    });

    testWidgets('the replace path lands the retired Action in history',
        (tester) async {
      final todo = await _insertAt(db, id: 'hist4', title: 'Replace outcome');
      final curCtrl = StreamController<Action?>.broadcast();
      final plnCtrl = StreamController<List<Action>>.broadcast();
      final hisCtrl = StreamController<List<TerminatedAction>>.broadcast();
      addTearDown(curCtrl.close);
      addTearDown(plnCtrl.close);
      addTearDown(hisCtrl.close);

      Future<void> refresh() async {
        curCtrl.add(await tester
            .runAsync<Action?>(() => db.actionDao.getCurrentAction('hist4')));
        plnCtrl.add((await tester
            .runAsync(() => db.actionDao.getPlannedActions('hist4')))!);
        hisCtrl.add((await tester
            .runAsync(() => db.actionDao.getTerminatedActions('hist4')))!);
        await tester.pump();
        await tester.pump();
      }

      await tester.runAsync(() async {
        await db.actionDao.setCurrentAction('hist4', 'the incumbent');
        await db.actionDao.addPlannedAction('hist4', 'the challenger');
      });

      final (widget, router) = _buildScreen(
        db,
        'hist4',
        initialTodo: todo,
        currentActionStream: curCtrl.stream,
        plannedActionsStream: plnCtrl.stream,
        terminatedActionsStream: hisCtrl.stream,
      );
      await _showTaskDetail(tester, widget, router, 'hist4');
      await refresh();

      final planned = (await tester
          .runAsync(() => db.actionDao.getPlannedActions('hist4')))!;
      await tester.tap(find.byKey(Key('plan_promote_${planned.single.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('plan_replace_confirm')));
      await tester.pumpAndSettle();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await refresh();
      await tester.pumpAndSettle();

      final history = (await tester
          .runAsync(() => db.actionDao.getTerminatedActions('hist4')))!;
      expect(history.map((h) => h.action.actionText), ['the incumbent'],
          reason: 'the replaced Action is history, not a deletion');
      await tester.tap(find.byKey(const Key('action_history_section')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('history_action_${history.single.action.id}')),
          findsOneWidget);
      expect((await tester
              .runAsync(() => db.actionDao.getPlannedActions('hist4')))!,
          isEmpty,
          reason: 'a superseded row never leaks back into the planned queue');
    });

    testWidgets('the anchor row lays out at 320dp with the Abandon control',
        (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final todo = await _insertAt(db, id: 'hist5', title: 'Narrow outcome');
      final current = _historyAction(
        id: 'cur',
        text: 'a deliberately long current action text that must wrap',
        role: 'current',
      );
      final (widget, router) = _buildScreen(
        db,
        'hist5',
        initialTodo: todo,
        currentActionStream: Stream.value(current),
      );
      await _showTaskDetail(tester, widget, router, 'hist5');
      await tester.pump();

      expect(find.byKey(const Key('plan_current_action')), findsOneWidget);
      expect(find.byKey(const Key('plan_demote_button')), findsOneWidget);
      expect(find.byKey(const Key('plan_abandon_button')), findsOneWidget);

      // A third trailing control is the overflow risk. Measured rather than
      // inferred from `takeException`: the Plan section's unrelated
      // "Add planned action" row overflows at this width under the test font
      // (Ahem renders every glyph as a full em square), which would mask the
      // anchor row's own result either way.
      final anchor = tester.getRect(find.byKey(const Key('plan_current_action')));
      final abandon =
          tester.getRect(find.byKey(const Key('plan_abandon_button')));
      expect(anchor.width, lessThanOrEqualTo(320.0));
      expect(abandon.right, lessThanOrEqualTo(anchor.right),
          reason: 'the Abandon control stays inside the anchor row at 320dp');
      expect(abandon.width, greaterThan(0.0),
          reason: 'and is not squeezed to nothing');
      tester.takeException();
    });
  });

  // ---------------------------------------------------------------------------
  // A pending title / notes edit at teardown (issue #533).
  //
  // An Outcome's text saves on focus loss (ADR-0023) and `dispose()` backs that
  // up, exactly as `ClarifyCard` does on its Outcome shape. The route-pop path
  // saves today *only* because the Navigator hands focus over while the popped
  // subtree is still mounted, which is framework behaviour this screen does not
  // own; the backstop puts a floor under it, and its failure mode without one is
  // a silent lost edit.
  //
  // Every assertion reads the **raw** `todos` row rather than `TodoDao.getTodo`,
  // whose D2 projection COALESCEs the current Action's values over these columns
  // and would make the assertions unfalsifiable (NOTES.md 2026-07-26).
  // ---------------------------------------------------------------------------
  group('TaskDetailScreen — a pending text edit at teardown (#533)', () {
    late GtdDatabase db;
    late RecordingDomainOpCapture capture;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      capture = RecordingDomainOpCapture();
      db = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
    });
    tearDown(() async => db.close());

    Future<Map<String, Object?>> rawRow(String id) async => (await db
            .customSelect(
              'SELECT title, notes, updated_at FROM todos WHERE id = ?',
              variables: [Variable.withString(id)],
            )
            .getSingle())
        .data;

    /// Drops focus and lets the fire-and-forget save reach the database. The
    /// write is `unawaited`, so it needs a turn of the *real* event loop.
    Future<void> loseFocus(WidgetTester tester) async {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.runAsync(() => pumpEventQueue());
    }

    /// Tears the whole tree down with the field still focused — the shape a
    /// route pop would have if the Navigator ever stopped handing focus over.
    Future<void> unmountWhileFocused(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => pumpEventQueue());
    }

    /// Opens the notes editor (the pencil) and waits out the 50ms delayed
    /// `requestFocus` the screen schedules behind it.
    Future<void> openNotesEditor(WidgetTester tester) async {
      final pencil = find.byIcon(Icons.edit_outlined);
      await tester.ensureVisible(pencil);
      await tester.pump();
      await tester.tap(pencil);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('a title edit saves when the field loses focus',
        (tester) async {
      final todo = await _insertAt(db, id: 't', title: 'Buy milk');
      final (widget, router) = _buildScreen(db, 't', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 't');

      await tester.enterText(
          find.byKey(const Key('task_detail_title')), 'Buy oat milk');
      // Asserted *before* any unmount, or the dispose flush below would make a
      // working focus-loss trigger and a broken one indistinguishable
      // (docs/TESTING.md).
      await loseFocus(tester);

      expect((await rawRow('t'))['title'], 'Buy oat milk');
    });

    testWidgets('a notes edit saves when the field loses focus',
        (tester) async {
      final todo = await _insertAt(db, id: 't', title: 'Buy milk');
      final (widget, router) = _buildScreen(db, 't', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 't');

      await openNotesEditor(tester);
      await tester.enterText(
          find.byKey(const Key('task_detail_notes')), 'Ask the barista');
      await loseFocus(tester);

      expect((await rawRow('t'))['notes'], 'Ask the barista');
    });

    testWidgets(
        'a title edit still saves when the screen is torn down with the field '
        'focused', (tester) async {
      final todo = await _insertAt(db, id: 't', title: 'Buy milk');
      final (widget, router) = _buildScreen(db, 't', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 't');

      // No focus loss — straight to teardown.
      await tester.enterText(
          find.byKey(const Key('task_detail_title')), 'Buy oat milk');
      await unmountWhileFocused(tester);

      expect((await rawRow('t'))['title'], 'Buy oat milk');
    });

    testWidgets(
        'a notes edit still saves when the screen is torn down with the field '
        'focused', (tester) async {
      final todo = await _insertAt(db, id: 't', title: 'Buy milk');
      final (widget, router) = _buildScreen(db, 't', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 't');

      await openNotesEditor(tester);
      await tester.enterText(
          find.byKey(const Key('task_detail_notes')), 'Ask the barista');
      await unmountWhileFocused(tester);

      expect((await rawRow('t'))['notes'], 'Ask the barista');
    });

    // CHARACTERISATION, not a requirement — pins today's behaviour so #705
    // cannot change it silently.
    //
    // `TaskDetailNotifier.updateNotes` passes `notes:` with no `clearNotes`
    // flag, so emptying the field on this screen stores `''` rather than
    // nulling the column — diverging from `ActiveFocusScreen` and
    // `ClarifyCard`. The backstop deliberately routes through the same
    // `updateNotes` the focus-loss listener uses, inheriting the divergence
    // rather than manufacturing a disagreement between the screen's two exits.
    // Fixing #705 must flip this expectation to `isNull`.
    testWidgets('an emptied notes field flushes as an empty string, not NULL '
        '(#705)', (tester) async {
      final todo =
          await _insertAt(db, id: 't', title: 'Buy milk', notes: 'Ask them');
      final (widget, router) = _buildScreen(db, 't', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 't');

      await openNotesEditor(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('task_detail_notes')))
            .controller!
            .text,
        'Ask them',
        reason: 'the seeded notes must reach the field, or clearing it below '
            'is not a clear',
      );

      await tester.enterText(find.byKey(const Key('task_detail_notes')), '');
      await unmountWhileFocused(tester);

      expect((await rawRow('t'))['notes'], '');
    });

    // The other side of the guard. `TodoDao.updateFields` stamps `updated_at`
    // unconditionally and `last_clarified_at` on any mutation, and authors a
    // sync op — so an unconditional flush would restamp clarification and bump
    // sync arbitration on every exit from a screen the user only looked at.
    testWidgets('a clean teardown issues no write', (tester) async {
      final todo = await _insertAt(db, id: 't', title: 'Buy milk');
      final (widget, router) = _buildScreen(db, 't', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 't');

      await unmountWhileFocused(tester);

      // Seeded through raw SQL, so `updated_at` starts NULL: any write at all
      // would stamp it.
      expect((await rawRow('t'))['updated_at'], isNull);
      expect(capture.forCollection(todosCollection), isEmpty);
    });

    testWidgets('a failing flush is logged rather than thrown into teardown',
        (tester) async {
      final todo = await _insertAt(db, id: 't', title: 'Buy milk');
      final (widget, router) = _buildScreen(db, 't', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 't');
      await tester.enterText(
          find.byKey(const Key('task_detail_title')), 'Buy oat milk');

      // Closing the database is the one way to fail this write from outside the
      // screen: it is issued after `dispose()` has already run, so nothing in
      // the widget tree is left to intercept it.
      await db.close();
      await unmountWhileFocused(tester);

      expect(tester.takeException(), isNull);
    });

    // A write must not outlive its subject. Without the subject-missing latch
    // the flush fires against a row that is gone, and `TodoDao` authors the sync
    // op unconditionally — so an op would be authored for a deleted entity.
    // This is #447's rule (a write only counts if it landed) applied to the site
    // #447 names; the residual TOCTOU window is #444's.
    testWidgets('a subject that went missing under the open screen is never '
        'written to', (tester) async {
      await _insertAt(db, id: 'gone', title: 'Buy milk');
      final todo = (await db.todoDao.getTodo('gone'))!;
      final feed = StreamController<Todo?>.broadcast();
      addTearDown(feed.close);

      final (widget, router) =
          _buildScreen(db, 'gone', todoStream: feed.stream);
      await _showTaskDetail(tester, widget, router, 'gone');
      feed.add(todo);
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const Key('task_detail_title')), 'Buy oat milk');
      await tester.pump();

      // The row leaves local storage under the open screen. The provider
      // override decouples the stream from the row, so the row is still there
      // to prove the negative.
      feed.add(null);
      await tester.pumpAndSettle();
      capture.clear();

      await unmountWhileFocused(tester);

      final row = await rawRow('gone');
      expect(row['title'], 'Buy milk');
      expect(row['updated_at'], isNull);
      // The op-log assertion is the one that survives a future DAO that upserts.
      expect(capture.forCollection(todosCollection), isEmpty);
    });

    // CHARACTERISATION — green with and without the dispose flush. The pop path
    // works because the newly-current route hands focus over while the popped
    // subtree is still mounted, so the focus-loss listener fires normally. It is
    // pinned here so a future route-configuration change that removes the
    // handoff is caught by a test rather than by a user losing work.
    testWidgets('popping the route with the field focused persists the edit '
        'and raises nothing', (tester) async {
      final todo = await _insertAt(db, id: 't', title: 'Buy milk');
      final (widget, router) = _buildScreen(db, 't', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 't');

      await tester.enterText(
          find.byKey(const Key('task_detail_title')), 'Buy oat milk');
      router.pop();
      await tester.pumpAndSettle();
      await tester.runAsync(() => pumpEventQueue());

      expect((await rawRow('t'))['title'], 'Buy oat milk');
      expect(tester.takeException(), isNull);
    });
  });
}

/// An in-memory [Action] row for render-only history tests — the DAO reads are
/// covered in `test/database/action_history_test.dart`.
Action _historyAction({
  required String id,
  required String text,
  required String role,
  DateTime? doneAt,
  DateTime? updatedAt,
}) =>
    Action(
      id: id,
      outcomeId: 'outcome',
      userId: _userId,
      actionText: text,
      role: role,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: updatedAt,
      doneAt: doneAt,
    );

String _localDateLabel(DateTime utc) {
  final local = utc.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}
