import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/connectivity_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/screens/task_detail/task_detail_screen.dart';
import '../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<Todo> _insertAt(
  GtdDatabase db, {
  required String id,
  String title = 'Test task',
  String state = 'next_action',
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

    setUp(() => db = _openInMemory());
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

    testWidgets('status pill sheet lists valid transitions for next_action items',
        (tester) async {
      final todo = await _insertAt(db, id: 'task4', title: 'Next action task');
      final (widget, router) = _buildScreen(db, 'task4', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'task4');

      await tester.tap(find.byKey(const Key('status_pill')));
      await tester.pumpAndSettle();

      expect(find.text('In Progress'), findsOneWidget);
      // Waiting For is no longer a FSM state — it is set via the waiting_for column.
      expect(find.text('Waiting For'), findsNothing);
      // 'done' is no longer a state transition — completion is via markDone().
      expect(find.text('Done'), findsNothing);

      // "Next Actions" appears once in the status pill (current state label),
      // but not as a transition target in the sheet.
      expect(find.text('Next Actions'), findsOneWidget);
      expect(find.text('Someday / Maybe'), findsNothing);
    });

    testWidgets('waiting_for section is visible on detail screen', (tester) async {
      final todo = await _insertAt(db, id: 'task5', title: 'Waiting task');
      final (widget, router) = _buildScreen(db, 'task5', initialTodo: todo);
      await _showTaskDetail(tester, widget, router, 'task5');

      expect(find.text('WAITING FOR'), findsOneWidget);
      // No waiting_for set yet → shows 'Not set'.
      expect(find.text('Not set'), findsOneWidget);
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

  });
}
