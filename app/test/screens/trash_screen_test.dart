import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide Intent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show Intent;
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/trash/trash_screen.dart';
import 'package:jeeves/widgets/active_filter_bar.dart';
import '../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<void> _insertTodo(
  GtdDatabase db, {
  required String id,
  required String title,
}) async {
  final now = DateTime.now().toUtc();
  await db.into(db.todos).insert(TodosCompanion(
    id: Value(id),
    title: Value(title),
    clarified: const Value(true),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
}

(Widget, GoRouter) _buildScreen(GtdDatabase db) {
  final router = GoRouter(
    initialLocation: '/trash',
    routes: [
      GoRoute(
        path: '/trash',
        builder: (_, _) => const TrashScreen(),
      ),
      GoRoute(
        path: '/task/:id',
        builder: (context, state) => Scaffold(
          body: Text('Detail ${state.pathParameters['id']}'),
        ),
      ),
    ],
  );
  final widget = ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: MaterialApp.router(routerConfig: router),
  );
  return (widget, router);
}

/// Unmounts the screen so the streaming providers dispose — and their drift
/// stream-close timers fire — before the test framework's end-of-test
/// pending-timer invariant check runs.
Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(configureSqliteForTests);

  group('TrashScreen', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'lists exactly the trashed Outcomes — including completed-then-'
        'trashed — newest-trashed first', (tester) async {
      await _insertTodo(db, id: 'a', title: 'Trashed early');
      await db.todoDao
          .setIntent('a', Intent.trash, now: DateTime.utc(2026, 6, 1));
      await _insertTodo(db, id: 'b', title: 'Done then trashed');
      await db.todoDao.markDone('b');
      await db.todoDao
          .setIntent('b', Intent.trash, now: DateTime.utc(2026, 6, 2));
      await _insertTodo(db, id: 'c', title: 'Still active');

      final (widget, _) = _buildScreen(db);
      await tester.pumpWidget(widget);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Trashed early'), findsOneWidget);
      expect(find.text('Done then trashed'), findsOneWidget,
          reason: 'completed-then-trashed surfaces in Trash (AC 1)');
      expect(find.text('Still active'), findsNothing);
      // Newest-trashed first: b (June 2) renders above a (June 1).
      expect(
        tester.getTopLeft(find.text('Done then trashed')).dy <
            tester.getTopLeft(find.text('Trashed early')).dy,
        isTrue,
        reason: 'newest-trashed Outcome must be listed first',
      );

      await _dispose(tester);
    });

    testWidgets('shows no context-filter bar (stream is unfiltered)',
        (tester) async {
      await _insertTodo(db, id: 'a', title: 'Trashed');
      await db.todoDao.setIntent('a', Intent.trash);

      final (widget, _) = _buildScreen(db);
      await tester.pumpWidget(widget);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(ActiveFilterBar), findsNothing);

      await _dispose(tester);
    });

    testWidgets('shows empty state when nothing is trashed', (tester) async {
      final (widget, _) = _buildScreen(db);
      await tester.pumpWidget(widget);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Trash is empty'), findsOneWidget);

      await _dispose(tester);
    });

    testWidgets('tapping a row navigates to /task/:id', (tester) async {
      await _insertTodo(db, id: 'a', title: 'Trashed');
      await db.todoDao.setIntent('a', Intent.trash);

      final (widget, _) = _buildScreen(db);
      await tester.pumpWidget(widget);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Trashed'));
      await tester.pumpAndSettle();

      expect(find.text('Detail a'), findsOneWidget);

      await _dispose(tester);
    });
  });
}
