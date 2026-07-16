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
  });
}
