/// End-to-end integration test for the full focus session lifecycle:
/// planning → session with task switching → session review → next planning
/// pre-loading rolled-over tasks.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

const _userId = 'test-user';

Future<void> _insertTodo(
  GtdDatabase db, {
  required String id,
  required String title,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
    id: Value(id),
    title: Value(title),
    clarified: const Value(true),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
}

void main() {
  setUpAll(configureSqliteForTests);

  group('Focus session lifecycle — review and rollover', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('review → close → next planning pre-selects rollover tasks', () async {
      // --- Setup: three tasks ---
      await _insertTodo(db, id: 'tA', title: 'Task A');
      await _insertTodo(db, id: 'tB', title: 'Task B');
      await _insertTodo(db, id: 'tC', title: 'Task C');

      final t0 = DateTime(2026, 4, 28, 9, 0);

      // --- Open session with A, B, C ---
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['tA', 'tB', 'tC'],
        now: t0,
      );

      // --- Focus task A and mark it done ---
      final t1 = DateTime(2026, 4, 28, 9, 5);
      await db.focusSessionDao.setCurrentTask(
          sessionId: sessionId, taskId: 'tA', now: t1);
      await db.todoDao.markDone('tA', _userId, now: t1);

      // --- Switch to task B ---
      final t2 = DateTime(2026, 4, 28, 9, 30);
      await db.focusSessionDao.setCurrentTask(
          sessionId: sessionId, taskId: 'tB', now: t2);

      // B and C are still pending (doneAt is null).
      // --- Review: B → rollover, C → maybe ---
      final t3 = DateTime(2026, 4, 28, 17, 0);
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {'tB': 'rollover', 'tC': 'maybe'},
        now: t3,
      );

      // --- Assertions: session closed ---
      final session = await (db.select(db.focusSessions)
            ..where((s) => s.id.equals(sessionId)))
          .getSingle();
      expect(session.endedAt, isNotNull);

      // --- todos.intent for C must be 'maybe' ---
      final todoC = await (db.select(db.todos)
            ..where((t) => t.id.equals('tC')))
          .getSingle();
      expect(todoC.intent, 'maybe');

      // --- todos.intent for B must remain 'next' ---
      final todoB = await (db.select(db.todos)
            ..where((t) => t.id.equals('tB')))
          .getSingle();
      expect(todoB.intent, 'next');

      // --- focus_session_tasks dispositions ---
      final fstRows = await db.customSelect(
        'SELECT task_id, disposition FROM focus_session_tasks '
        'WHERE focus_session_id = ? ORDER BY task_id',
        variables: [Variable(sessionId)],
      ).get();
      expect(fstRows.length, 3);

      final fstA =
          fstRows.firstWhere((r) => r.read<String>('task_id') == 'tA');
      final fstB =
          fstRows.firstWhere((r) => r.read<String>('task_id') == 'tB');
      final fstC =
          fstRows.firstWhere((r) => r.read<String>('task_id') == 'tC');

      expect(fstA.read<String?>('disposition'), isNull); // done task, not in map
      expect(fstB.read<String?>('disposition'), 'rollover');
      expect(fstC.read<String?>('disposition'), 'maybe');

      // --- All time logs must be closed ---
      final openLogs = await (db.select(db.timeLogs)
            ..where((l) => l.userId.equals(_userId) & l.endedAt.isNull()))
          .get();
      expect(openLogs, isEmpty);

      // --- Rollover task IDs: only B ---
      final rolloverIds = await db.focusSessionDao
          .getLastClosedSessionRolloverTaskIds(_userId);
      expect(rolloverIds, unorderedEquals(['tB']));
    });
  });
}
