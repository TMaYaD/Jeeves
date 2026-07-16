import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/connectivity_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/providers/sprint_timer_provider.dart'
    show sprintTimerProvider;
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/screens/task_detail/task_detail_screen.dart';
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
          .overrideWith((_) => Stream.value(initialTodo)),
      taskTagsProvider(todoId)
          .overrideWith((_) => Stream.value(initialTags)),
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
  });
}
