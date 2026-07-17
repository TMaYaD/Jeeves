import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/inbox/inbox_clarify_screen.dart';
import 'package:jeeves/models/todo.dart' show RoutingKind;
import 'package:jeeves/services/clarification_service.dart';
import '../../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

// Use 'local' to match CurrentUserIdNotifier's default build() value.
const _userId = 'local';

TodosCompanion _companion({
  required String id,
  required String title,
  String? notes,
  String? energyLevel,
  int? timeEstimate,
}) {
  final now = DateTime.now();
  return TodosCompanion(
    id: Value(id),
    title: Value(title),
    notes: notes != null ? Value(notes) : const Value.absent(),
    energyLevel:
        energyLevel != null ? Value(energyLevel) : const Value.absent(),
    timeEstimate:
        timeEstimate != null ? Value(timeEstimate) : const Value.absent(),
    captureSource: const Value('manual'),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  );
}

/// Delegates every [ClarificationService] call to a real
/// [DaoClarificationService] while recording the clear flags the last
/// [updateFields] call carried, so tests can assert the screen never sends a
/// spurious clear for a field that had no value.
class _RecordingClarificationService implements ClarificationService {
  _RecordingClarificationService(this._inner);

  final ClarificationService _inner;

  bool? lastClearNotes;
  bool? lastClearEnergyLevel;
  bool? lastClearTimeEstimate;
  bool? lastClearDueDate;

  @override
  Future<void> updateFields(
    String id, {
    String? title,
    String? notes,
    String? energyLevel,
    int? timeEstimate,
    DateTime? dueDate,
    bool clearNotes = false,
    bool clearEnergyLevel = false,
    bool clearTimeEstimate = false,
    bool clearDueDate = false,
  }) {
    lastClearNotes = clearNotes;
    lastClearEnergyLevel = clearEnergyLevel;
    lastClearTimeEstimate = clearTimeEstimate;
    lastClearDueDate = clearDueDate;
    return _inner.updateFields(
      id,
      title: title,
      notes: notes,
      energyLevel: energyLevel,
      timeEstimate: timeEstimate,
      dueDate: dueDate,
      clearNotes: clearNotes,
      clearEnergyLevel: clearEnergyLevel,
      clearTimeEstimate: clearTimeEstimate,
      clearDueDate: clearDueDate,
    );
  }

  @override
  Future<bool> exists(String id) => _inner.exists(id);

  @override
  Future<Set<String>> getPersonTagIds(String id) =>
      _inner.getPersonTagIds(id);

  @override
  Future<void> clarifyToOutcome(
    String id, {
    required RoutingKind to,
    String? nextActionText,
    Set<String>? personTagIds,
    String? userId,
  }) =>
      _inner.clarifyToOutcome(
        id,
        to: to,
        nextActionText: nextActionText,
        personTagIds: personTagIds,
        userId: userId,
      );

  @override
  Future<int> promoteCaptureToOutcome(
    String id, {
    String? intent,
    DateTime? dueDate,
  }) =>
      _inner.promoteCaptureToOutcome(id, intent: intent, dueDate: dueDate);

  @override
  Future<int> completeOutcome(String id) => _inner.completeOutcome(id);

  @override
  Future<void> stampClarified(String id) => _inner.stampClarified(id);
}

Widget _buildApp(
  GtdDatabase db,
  String todoId, {
  ClarificationService? clarificationService,
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      if (clarificationService != null)
        clarificationServiceProvider.overrideWithValue(clarificationService),
    ],
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

    testWidgets('deselecting energy level clears it on routing',
        (tester) async {
      await db.inboxDao.insertTodo(
        _companion(id: 'x', title: 'Buy milk', energyLevel: 'high'),
      );

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      // Tapping the selected chip deselects it (onSelect(null)).
      await tester.ensureVisible(find.text('High'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('High'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.energyLevel, isNull);
      expect(row.clarified, isTrue);
    });

    testWidgets('deselecting time estimate clears it on routing',
        (tester) async {
      await db.inboxDao.insertTodo(
        _companion(id: 'x', title: 'Buy milk', timeEstimate: 30),
      );

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      // Tapping the selected chip deselects it (_timeEstimate = null).
      await tester.ensureVisible(find.text('30m'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('30m'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.timeEstimate, isNull);
      expect(row.clarified, isTrue);
    });

    testWidgets('deleting notes clears them on routing', (tester) async {
      await db.inboxDao.insertTodo(
        _companion(id: 'x', title: 'Buy milk', notes: 'Full fat'),
      );

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('clarify_notes')), '');
      await tester.pump();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.notes, isNull);
      expect(row.clarified, isTrue);
    });

    testWidgets('routing an untouched item makes no spurious clearing writes',
        (tester) async {
      // Row carries no energy / time estimate / notes / due date.
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Buy milk'));

      final recorder =
          _RecordingClarificationService(DaoClarificationService(db));
      await tester.pumpWidget(
        _buildApp(db, 'x', clarificationService: recorder),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      // No field had a value, so the screen must not raise any clear flag —
      // this is what preserves the null = no-change contract.
      expect(recorder.lastClearNotes, isFalse);
      expect(recorder.lastClearEnergyLevel, isFalse);
      expect(recorder.lastClearTimeEstimate, isFalse);
      expect(recorder.lastClearDueDate, isFalse);

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.energyLevel, isNull);
      expect(row.timeEstimate, isNull);
      expect(row.notes, isNull);
      expect(row.dueDate, isNull);
      expect(row.clarified, isTrue);
    });
  });

  // The null = no-change contract: updateFields with no fields and no clear
  // flags must not stamp last_clarified_at. The widget "untouched" test can't
  // observe this because routing stamps the column afterwards, so assert it
  // directly against the service.
  group('DaoClarificationService.updateFields no-spurious-write contract', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('a no-op updateFields does not stamp last_clarified_at', () async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Buy milk'));
      final service = DaoClarificationService(db);

      await service.updateFields('x');

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.lastClarifiedAt, isNull);
    });

    test('clearNotes nulls the column and stamps', () async {
      await db.inboxDao.insertTodo(
        _companion(id: 'x', title: 'Buy milk', notes: 'Full fat'),
      );
      final service = DaoClarificationService(db);

      await service.updateFields('x', clearNotes: true);

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.notes, isNull);
      expect(row.lastClarifiedAt, isNotNull);
    });
  });
}
