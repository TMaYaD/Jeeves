import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/inbox/inbox_clarify_screen.dart';
import '../../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

// Use 'local' to match CurrentUserIdNotifier's default build() value.
const _userId = 'local';

TodosCompanion _companion({
  required String id,
  required String title,
  String? notes,
}) {
  final now = DateTime.now();
  return TodosCompanion(
    id: Value(id),
    title: Value(title),
    notes: notes != null ? Value(notes) : const Value.absent(),
    captureSource: const Value('manual'),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  );
}

Widget _buildApp(GtdDatabase db, String todoId) {
  return ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: MaterialApp.router(
      routerConfig: GoRouter(
        // Nest the clarify route under /inbox so pop() has a page to return to.
        initialLocation: '/inbox/$todoId/clarify',
        routes: [
          GoRoute(
            path: '/inbox',
            builder: (context, _) => const Scaffold(body: Text('Inbox')),
            routes: [
              GoRoute(
                path: ':id/clarify',
                builder: (context, state) => InboxClarifyScreen(
                  todoId: state.pathParameters['id']!,
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  group('InboxClarifyScreen', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    testWidgets('displays todo title and notes pre-populated', (tester) async {
      await db.inboxDao.insertTodo(
        _companion(id: 'x', title: 'Buy milk', notes: 'Full fat'),
      );

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      // Title and notes controllers are pre-filled from the DB row.
      final titleField =
          tester.widget<TextField>(find.byKey(const Key('clarify_title')));
      final notesField =
          tester.widget<TextField>(find.byKey(const Key('clarify_notes')));
      expect(titleField.controller?.text, 'Buy milk');
      expect(notesField.controller?.text, 'Full fat');
    });

    testWidgets('Next Action sets clarified = true', (tester) async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.clarified, isTrue);
    });

    testWidgets('Next Action leaves no clarified=false rows for the user',
        (tester) async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      // Use a one-shot query (not a watch stream) inside testWidgets to avoid
      // FakeAsync / stream-emission ordering issues.
      final unclarified = await (db.select(db.todos)
            ..where((t) =>
                t.userId.equals(_userId) & t.clarified.equals(false)))
          .get();
      expect(unclarified, isEmpty);
    });

    testWidgets('Maybe sets clarified = true with intent = maybe',
        (tester) async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Learn guitar'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      // The destination buttons are below the fold on the 800×600 test surface;
      // scroll them into view before tapping.
      await tester.ensureVisible(find.text('Maybe'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Maybe'));
      await tester.pumpAndSettle();

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.clarified, isTrue);
      expect(row.intent, 'maybe');
    });

    testWidgets('Done (discard) sets done_at', (tester) async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Old idea'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Done (discard)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done (discard)'));
      await tester.pumpAndSettle();

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.doneAt, isNotNull);
    });

    testWidgets('Skip leaves clarified = false', (tester) async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Deferred'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Skip'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.clarified, isFalse);
    });

    testWidgets('Skip leaves item in inbox (clarified=false)', (tester) async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Deferred'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Skip'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      final unclarified = await (db.select(db.todos)
            ..where((t) =>
                t.userId.equals(_userId) & t.clarified.equals(false)))
          .get();
      expect(unclarified.length, 1);
    });

    testWidgets('empty title does not process the item', (tester) async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Has title'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      // Clear the title field.
      await tester.enterText(find.byKey(const Key('clarify_title')), '');
      await tester.pump();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      // Item must still be unclarified — empty title blocks processing.
      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.clarified, isFalse);
    });

    testWidgets('edited title is persisted when processing', (tester) async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Old title'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('clarify_title')), 'New title');
      await tester.pump();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.title, 'New title');
      expect(row.clarified, isTrue);
    });
  });
}
