/// Tests for FocusSessionDao — open/close sessions, current-task management,
/// and session-task queries.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

const _userId = 'test-user';

Future<void> _insertTodo(GtdDatabase db,
    {required String id, required String title}) async {
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

  // ---------------------------------------------------------------------------
  // openSession
  // ---------------------------------------------------------------------------

  group('FocusSessionDao — openSession', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('creates an open session with no tasks when taskIds is empty', () async {
      final sessionId =
          await db.focusSessionDao.openSession(userId: _userId, taskIds: []);

      final session = await db.focusSessionDao.getActiveSession(_userId);
      expect(session, isNotNull);
      expect(session!.id, sessionId);
      expect(session.userId, _userId);
      expect(session.endedAt, isNull);
      expect(session.currentTaskId, isNull);
    });

    test('creates task rows in position order', () async {
      await _insertTodo(db, id: 't1', title: 'Task 1');
      await _insertTodo(db, id: 't2', title: 'Task 2');
      await _insertTodo(db, id: 't3', title: 'Task 3');

      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['t1', 't2', 't3'],
      );

      final tasks =
          await db.focusSessionDao.watchSessionTasks(sessionId).first;
      expect(tasks.map((t) => t.id), orderedEquals(['t1', 't2', 't3']));
    });

    test('closes prior open session before opening a new one', () async {
      final firstId =
          await db.focusSessionDao.openSession(userId: _userId, taskIds: []);
      final secondId =
          await db.focusSessionDao.openSession(userId: _userId, taskIds: []);

      final allSessions = await db.select(db.focusSessions).get();
      final first = allSessions.firstWhere((s) => s.id == firstId);
      final second = allSessions.firstWhere((s) => s.id == secondId);
      expect(first.endedAt, isNotNull);
      expect(second.endedAt, isNull);

      final active = await db.focusSessionDao.getActiveSession(_userId);
      expect(active?.id, secondId);
    });
  });

  // ---------------------------------------------------------------------------
  // closeSession
  // ---------------------------------------------------------------------------

  group('FocusSessionDao — closeSession', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('sets ended_at and session no longer appears as active', () async {
      final sessionId =
          await db.focusSessionDao.openSession(userId: _userId, taskIds: []);
      await db.focusSessionDao.closeSession(sessionId: sessionId);

      final session = await (db.select(db.focusSessions)
            ..where((s) => s.id.equals(sessionId)))
          .getSingle();
      expect(session.endedAt, isNotNull);

      final active = await db.focusSessionDao.getActiveSession(_userId);
      expect(active, isNull);
    });

    test('closes any open time log for the session user', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['task1'],
      );
      await db.focusSessionDao.setCurrentTask(
          sessionId: sessionId, taskId: 'task1');

      final logBefore =
          await db.timeLogDao.watchActiveLog(_userId).first;
      expect(logBefore, isNotNull);

      await db.focusSessionDao.closeSession(sessionId: sessionId);

      final logAfter = await db.timeLogDao.watchActiveLog(_userId).first;
      expect(logAfter, isNull);
    });

    test('no-ops for an already-closed session', () async {
      final sessionId =
          await db.focusSessionDao.openSession(userId: _userId, taskIds: []);
      await db.focusSessionDao.closeSession(sessionId: sessionId);
      // Calling again must not throw.
      await db.focusSessionDao.closeSession(sessionId: sessionId);
    });
  });

  // ---------------------------------------------------------------------------
  // setCurrentTask
  // ---------------------------------------------------------------------------

  group('FocusSessionDao — setCurrentTask', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('opens a time log for the focused task', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['task1'],
      );
      final startTime = DateTime(2026, 4, 28, 9, 0, 0);
      await db.focusSessionDao.setCurrentTask(
        sessionId: sessionId,
        taskId: 'task1',
        now: startTime,
      );

      final log = await db.timeLogDao.watchActiveLog(_userId).first;
      expect(log, isNotNull);
      expect(log!.taskId, 'task1');
      expect(DateTime.parse(log.startedAt), startTime.toUtc());
      expect(log.endedAt, isNull);
    });

    test('closes prior time log when switching tasks', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      await _insertTodo(db, id: 'task2', title: 'Task 2');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['task1', 'task2'],
      );
      final t1 = DateTime(2026, 4, 28, 9, 0, 0);
      final t2 = DateTime(2026, 4, 28, 9, 30, 0);

      await db.focusSessionDao.setCurrentTask(
          sessionId: sessionId, taskId: 'task1', now: t1);
      await db.focusSessionDao.setCurrentTask(
          sessionId: sessionId, taskId: 'task2', now: t2);

      final allLogs = await (db.select(db.timeLogs)
            ..where((l) => l.userId.equals(_userId)))
          .get();
      expect(allLogs.length, 2);

      final logForTask1 = allLogs.firstWhere((l) => l.taskId == 'task1');
      expect(logForTask1.endedAt, isNotNull);

      final activeLog = await db.timeLogDao.watchActiveLog(_userId).first;
      expect(activeLog?.taskId, 'task2');
    });

    test('updates current_task_id on the session row', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['task1'],
      );
      await db.focusSessionDao.setCurrentTask(
          sessionId: sessionId, taskId: 'task1');

      final session = await db.focusSessionDao.getActiveSession(_userId);
      expect(session?.currentTaskId, 'task1');
    });

    test('null taskId clears current_task_id and closes open time log',
        () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['task1'],
      );
      await db.focusSessionDao.setCurrentTask(
          sessionId: sessionId, taskId: 'task1');
      await db.focusSessionDao.setCurrentTask(
          sessionId: sessionId, taskId: null);

      final session = await db.focusSessionDao.getActiveSession(_userId);
      expect(session?.currentTaskId, isNull);

      final activeLog = await db.timeLogDao.watchActiveLog(_userId).first;
      expect(activeLog, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // watchActiveSession / getActiveSession
  // ---------------------------------------------------------------------------

  group('FocusSessionDao — watchActiveSession / getActiveSession', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('returns null when no session is open', () async {
      final session = await db.focusSessionDao.getActiveSession(_userId);
      expect(session, isNull);
    });

    test('returns the open session by id', () async {
      final sessionId =
          await db.focusSessionDao.openSession(userId: _userId, taskIds: []);
      final session = await db.focusSessionDao.getActiveSession(_userId);
      expect(session?.id, sessionId);
    });

    test('returns null after the session is closed', () async {
      final sessionId =
          await db.focusSessionDao.openSession(userId: _userId, taskIds: []);
      await db.focusSessionDao.closeSession(sessionId: sessionId);
      final session = await db.focusSessionDao.getActiveSession(_userId);
      expect(session, isNull);
    });

    test('watchActiveSession emits the new session after openSession', () async {
      final initial =
          await db.focusSessionDao.watchActiveSession(_userId).first;
      expect(initial, isNull);

      // Subscribe BEFORE mutating to capture the reactive emission.
      final nextEmission =
          db.focusSessionDao.watchActiveSession(_userId).skip(1).first;
      final sessionId =
          await db.focusSessionDao.openSession(userId: _userId, taskIds: []);
      final emitted = await nextEmission;
      expect(emitted?.id, sessionId);
    });
  });

  // ---------------------------------------------------------------------------
  // watchSessionTasksForUser
  // ---------------------------------------------------------------------------

  group('FocusSessionDao — watchSessionTasksForUser', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('returns empty list when no session is open', () async {
      final tasks =
          await db.focusSessionDao.watchSessionTasksForUser(_userId).first;
      expect(tasks, isEmpty);
    });

    test('returns tasks for the open session in position order', () async {
      await _insertTodo(db, id: 'a', title: 'Task A');
      await _insertTodo(db, id: 'b', title: 'Task B');
      await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['a', 'b'],
      );

      final tasks =
          await db.focusSessionDao.watchSessionTasksForUser(_userId).first;
      expect(tasks.map((t) => t.id), orderedEquals(['a', 'b']));
    });

    test('returns empty list after the session is closed', () async {
      await _insertTodo(db, id: 'a', title: 'Task A');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['a'],
      );
      await db.focusSessionDao.closeSession(sessionId: sessionId);

      final tasks =
          await db.focusSessionDao.watchSessionTasksForUser(_userId).first;
      expect(tasks, isEmpty);
    });
  });
}
