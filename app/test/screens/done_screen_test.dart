import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide Intent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show Intent;
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/done/done_screen.dart';
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
    initialLocation: '/done',
    routes: [
      GoRoute(
        path: '/done',
        builder: (_, _) => const DoneScreen(),
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

  group('DoneScreen', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'lists completed Outcomes newest-first, excluding completed-then-'
        'trashed ones', (tester) async {
      await _insertTodo(db, id: 'a', title: 'Done early');
      await db.todoDao.markDone('a', now: DateTime.utc(2026, 6, 1));
      await _insertTodo(db, id: 'b', title: 'Done late');
      await db.todoDao.markDone('b', now: DateTime.utc(2026, 6, 2));
      await _insertTodo(db, id: 'c', title: 'Done then trashed');
      await db.todoDao.markDone('c');
      await db.todoDao.setIntent('c', Intent.trash);
      await _insertTodo(db, id: 'd', title: 'Still active');

      final (widget, _) = _buildScreen(db);
      await tester.pumpWidget(widget);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Done early'), findsOneWidget);
      expect(find.text('Done late'), findsOneWidget);
      expect(find.text('Done then trashed'), findsNothing,
          reason: 'a trashed-and-completed Outcome surfaces in Trash only');
      expect(find.text('Still active'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Done late')).dy <
            tester.getTopLeft(find.text('Done early')).dy,
        isTrue,
        reason: 'most recently completed Outcome must be listed first',
      );

      await _dispose(tester);
    });

    testWidgets('shows no context-filter bar (stream is unfiltered)',
        (tester) async {
      final (widget, _) = _buildScreen(db);
      await tester.pumpWidget(widget);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(ActiveFilterBar), findsNothing);
      expect(find.text('Nothing in Done'), findsOneWidget);

      await _dispose(tester);
    });

    testWidgets('tapping a row navigates to /task/:id', (tester) async {
      await _insertTodo(db, id: 'a', title: 'Completed thing');
      await db.todoDao.markDone('a');

      final (widget, _) = _buildScreen(db);
      await tester.pumpWidget(widget);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Completed thing'));
      await tester.pumpAndSettle();

      expect(find.text('Detail a'), findsOneWidget);

      await _dispose(tester);
    });
  });
}
