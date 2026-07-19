import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide Intent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show Intent;
import 'package:jeeves/providers/connectivity_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/providers/sprint_timer_provider.dart'
    show sprintTimerProvider;
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/screens/task_detail/task_detail_screen.dart';
import 'package:jeeves/widgets/state_surfaces.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<Todo> _insertAt(
  GtdDatabase db, {
  required String id,
  String title = 'Test task',
  String intent = 'next',
}) async {
  final now = DateTime.now();
  await db.customInsert(
    'INSERT INTO todos (id, title, user_id, created_at, time_spent_minutes, intent) '
    'VALUES (?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString(id),
      Variable.withString(title),
      Variable.withString(_userId),
      Variable.withDateTime(now),
      Variable.withInt(0),
      Variable.withString(intent),
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
      isOnlineProvider.overrideWith((_) => Stream.value(true)),
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
  await tester.pump(const Duration(milliseconds: 100));
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

      expect(find.text('Fix the bug'), findsOneWidget);
    });

    testWidgets('shows all UI sections modeled as a show page', (tester) async {
      final todo = await _insertAt(db, id: 'task2', title: 'My task');
      final (widget, router) = _buildScreen(db, 'task2', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'task2');

      expect(find.text('ADD PROJECT'), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);
      expect(find.text('NOTES'), findsOneWidget);
      expect(find.text('DUE DATE'), findsOneWidget);
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

    testWidgets('shows status pill', (tester) async {
      final todo = await _insertAt(db, id: 'task3', title: 'Task');
      final (widget, router) = _buildScreen(db, 'task3', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'task3');

      expect(find.byKey(const Key('status_pill')), findsOneWidget);
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

      expect(find.byKey(const Key('task_detail_start_focus')), findsOneWidget);
    });

    testWidgets('does not render Start focus on a completed task',
        (tester) async {
      final todo = await _insertAt(db, id: 'done1', title: 'Done task');
      final done = todo.copyWith(
        doneAt: Value(DateTime.now().toUtc().toIso8601String()),
      );
      final (widget, router) = _buildScreen(db, 'done1', initialTodo: done);
      await _showTaskDetail(tester, widget, router, 'done1');

      expect(find.byKey(const Key('task_detail_start_focus')), findsNothing);
    });

    testWidgets(
        'Start focus with no open FocusSession opens an ad-hoc TimeLog and '
        'navigates to /focus/active', (tester) async {
      final todo = await _insertAt(db, id: 'engage2', title: 'Engageable');
      final (widget, router) = _buildScreen(db, 'engage2', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'engage2');

      // No FocusSession is open — the affordance must still engage.
      expect(await db.focusSessionDao.getActiveSession(), isNull);

      await tester.tap(find.byKey(const Key('task_detail_start_focus')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
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

      await tester.tap(find.byKey(const Key('task_detail_start_focus')));
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
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('task_detail_start_focus')));
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
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.runAsync(
        () => container.read(focusModeProvider.notifier).startFocus('other'),
      );

      await tester.tap(find.byKey(const Key('task_detail_start_focus')));
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
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.runAsync(
        () =>
            container.read(focusModeProvider.notifier).startFocus('engage6'),
      );

      await tester.tap(find.byKey(const Key('task_detail_start_focus')));
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
      expect(find.text('Buy milk'), findsOneWidget);

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
}
