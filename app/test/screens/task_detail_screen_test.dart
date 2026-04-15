import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show GtdState;
import 'package:jeeves/providers/connectivity_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/screens/task_detail/task_detail_screen.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase.forTesting(NativeDatabase.memory());

/// Inserts a test todo at [state] (bypassing the state machine for setup),
/// returns the persisted Drift row.
Future<Todo> _insertAt(
  GtdDatabase db, {
  required String id,
  String title = 'Test task',
  String state = 'inbox',
}) async {
  final now = DateTime.now();
  await db.customInsert(
    'INSERT INTO todos (id, title, state, user_id, created_at, time_spent_minutes) '
    'VALUES (?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString(id),
      Variable.withString(title),
      Variable.withString(state),
      Variable.withString(_userId),
      Variable.withDateTime(now),
      Variable.withInt(0),
    ],
  );
  return (await db.todoDao.getTodo(id, _userId))!;
}

/// Builds the app with an `/inbox` base route so that [GoRouter.pop] works
/// when the task detail screen transitions state and navigates back.
///
/// Returns `(widget, router)` — call `router.push('/task/$todoId')` then pump
/// once to render the task detail screen.
(Widget, GoRouter) _buildScreen(
  GtdDatabase db,
  String todoId, {
  Todo? initialTodo,
  List<Tag> initialTags = const [],
  List<Todo> initialBlockers = const [],
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
    ],
  );

  final widget = ProviderScope(
    overrides: [
      isOnlineProvider.overrideWith((_) => Stream.value(true)),
      inboxItemsProvider.overrideWith((_) => Stream.value([])),
      databaseProvider.overrideWithValue(db),
      // Override ALL stream providers with static values to prevent Drift from
      // creating cleanup timers when the ProviderScope is disposed.
      taskDetailTodoProvider(todoId)
          .overrideWith((_) => Stream.value(initialTodo)),
      taskTagsProvider(todoId)
          .overrideWith((_) => Stream.value(initialTags)),
      taskBlockersProvider(todoId)
          .overrideWith((_) => Stream.value(initialBlockers)),
      // ProjectPickerWidget and ContextTagPickerWidget also watch these:
      projectTagsProvider.overrideWith((_) => Stream.value([])),
      contextTagsProvider.overrideWith((_) => Stream.value([])),
    ],
    child: MaterialApp.router(routerConfig: router),
  );

  return (widget, router);
}

/// Pumps the widget to the task detail screen: renders inbox, pushes the task
/// route, then pumps enough frames for the screen to settle.
Future<void> _showTaskDetail(
  WidgetTester tester,
  Widget widget,
  GoRouter router,
  String todoId,
) async {
  await tester.pumpWidget(widget);
  await tester.pump(); // render inbox
  router.push('/task/$todoId');
  await tester.pump(); // process push
  await tester.pump(const Duration(milliseconds: 100)); // settle
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(configureSqliteForTests);

  group('TaskDetailScreen', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets('shows title field with current title', (tester) async {
      final todo = await _insertAt(db, id: 'task1', title: 'Fix the bug');
      final (widget, router) = _buildScreen(db, 'task1', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'task1');

      expect(find.text('Fix the bug'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('shows all six field sections', (tester) async {
      final todo = await _insertAt(db, id: 'task2', title: 'My task');
      final (widget, router) = _buildScreen(db, 'task2', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'task2');

      expect(find.text('Project'), findsOneWidget);
      expect(find.text('Context tags'), findsOneWidget);
      expect(find.text('Energy level'), findsOneWidget);
      expect(find.text('Time estimate (minutes)'), findsOneWidget);
      // "Blocked by" appears as both section label and form-field label.
      expect(find.text('Blocked by'), findsWidgets);
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('shows "Move to…" bottom action button', (tester) async {
      final todo = await _insertAt(db, id: 'task3', title: 'Task');
      final (widget, router) = _buildScreen(db, 'task3', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'task3');

      expect(find.text('Move to…'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('"Move to…" sheet lists only valid next states for inbox',
        (tester) async {
      final todo = await _insertAt(
          db, id: 'task4', title: 'Inbox task', state: 'inbox');
      final (widget, router) = _buildScreen(db, 'task4', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'task4');

      await tester.tap(find.text('Move to…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Valid from inbox: nextAction, waitingFor, somedayMaybe, done
      expect(find.text('Next Actions'), findsOneWidget);
      expect(find.text('Waiting For'), findsOneWidget);
      expect(find.text('Someday / Maybe'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);

      // Invalid from inbox: inProgress, scheduled, deferred
      expect(find.text('In Progress'), findsNothing);
      expect(find.text('Scheduled'), findsNothing);
      expect(find.text('Deferred'), findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('moving task to Next Actions succeeds', (tester) async {
      final todo = await _insertAt(
          db, id: 'task5', title: 'Move me', state: 'inbox');
      final (widget, router) = _buildScreen(db, 'task5', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'task5');

      await tester.tap(find.text('Move to…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('move_to_next_action')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Verify the DB was updated.
      final row = await db.todoDao.getTodo('task5', _userId);
      expect(row?.state, GtdState.nextAction.value);
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('energy level segmented button shows Low/Medium/High',
        (tester) async {
      final todo = await _insertAt(db, id: 'task6', title: 'Energy task');
      final (widget, router) = _buildScreen(db, 'task6', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'task6');

      expect(find.text('Low'), findsOneWidget);
      expect(find.text('Medium'), findsOneWidget);
      expect(find.text('High'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('blocked-by picker renders with None default', (tester) async {
      final todo = await _insertAt(db, id: 'task7', title: 'Blocked task');
      final (widget, router) = _buildScreen(db, 'task7', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'task7');

      // DropdownButtonFormField shows current value 'None'
      expect(find.text('None'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
    });
  });
}
