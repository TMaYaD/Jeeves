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

      final session = await db.focusSessionDao.getActiveSession();
      expect(session, isNotNull);
      expect(session!.id, sessionId);
      expect(session.userId, _userId);
      expect(session.endedAt, isNull);
      expect(session.currentTaskId, isNull);
    });

    test('inserts task rows with non-null id (regression: SqliteException 1811)',
        () async {
      await _insertTodo(db, id: 'tA', title: 'Task A');
      await _insertTodo(db, id: 'tB', title: 'Task B');

      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['tA', 'tB'],
      );

      final rows = await db.customSelect(
        'SELECT id, task_id FROM focus_session_tasks '
        'WHERE focus_session_id = ? ORDER BY position',
        variables: [Variable(sessionId)],
      ).get();

      expect(rows.length, 2);
      expect(rows[0].read<String>('task_id'), 'tA');
      expect(rows[1].read<String>('task_id'), 'tB');
      // Each row must have a non-null, non-empty id for PowerSync compatibility.
      for (final row in rows) {
        final id = row.read<String?>('id');
        expect(id, isNotNull);
        expect(id, isNotEmpty);
      }
    });

    test('inserts task rows carrying the session user_id (denormalized for '
        'PowerSync per-user bucketing)', () async {
      await _insertTodo(db, id: 'tA', title: 'Task A');
      await _insertTodo(db, id: 'tB', title: 'Task B');

      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['tA', 'tB'],
      );

      final rows = await db.customSelect(
        'SELECT user_id FROM focus_session_tasks WHERE focus_session_id = ?',
        variables: [Variable(sessionId)],
      ).get();

      expect(rows.length, 2);
      for (final row in rows) {
        expect(row.read<String?>('user_id'), _userId);
      }
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

      final active = await db.focusSessionDao.getActiveSession();
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

      final active = await db.focusSessionDao.getActiveSession();
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
          await db.timeLogDao.watchActiveLog().first;
      expect(logBefore, isNotNull);

      await db.focusSessionDao.closeSession(sessionId: sessionId);

      final logAfter = await db.timeLogDao.watchActiveLog().first;
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

      final log = await db.timeLogDao.watchActiveLog().first;
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

      final activeLog = await db.timeLogDao.watchActiveLog().first;
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

      final session = await db.focusSessionDao.getActiveSession();
      expect(session?.currentTaskId, 'task1');
    });

    test(
        'accepts an off-Plan task: Focus may point to any Outcome being '
        'engaged, whether or not on the Plan (CONTEXT.md § Engagement)',
        () async {
      await _insertTodo(db, id: 'planned', title: 'Planned');
      await _insertTodo(db, id: 'offplan', title: 'Off-plan');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['planned'],
      );

      await db.focusSessionDao.setCurrentTask(
          sessionId: sessionId, taskId: 'offplan');

      final session = await db.focusSessionDao.getActiveSession();
      expect(session?.currentTaskId, 'offplan');

      final log = await db.timeLogDao.watchActiveLog().first;
      expect(log?.taskId, 'offplan');
      expect(log?.focusSessionId, sessionId,
          reason: 'off-Plan engagement still attributes to the session');
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

      final session = await db.focusSessionDao.getActiveSession();
      expect(session?.currentTaskId, isNull);

      final activeLog = await db.timeLogDao.watchActiveLog().first;
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
      final session = await db.focusSessionDao.getActiveSession();
      expect(session, isNull);
    });

    test('returns the open session by id', () async {
      final sessionId =
          await db.focusSessionDao.openSession(userId: _userId, taskIds: []);
      final session = await db.focusSessionDao.getActiveSession();
      expect(session?.id, sessionId);
    });

    test('returns null after the session is closed', () async {
      final sessionId =
          await db.focusSessionDao.openSession(userId: _userId, taskIds: []);
      await db.focusSessionDao.closeSession(sessionId: sessionId);
      final session = await db.focusSessionDao.getActiveSession();
      expect(session, isNull);
    });

    test('watchActiveSession emits the new session after openSession', () async {
      final initial =
          await db.focusSessionDao.watchActiveSession().first;
      expect(initial, isNull);

      // Subscribe BEFORE mutating to capture the reactive emission.
      final nextEmission =
          db.focusSessionDao.watchActiveSession().skip(1).first;
      final sessionId =
          await db.focusSessionDao.openSession(userId: _userId, taskIds: []);
      final emitted = await nextEmission;
      expect(emitted?.id, sessionId);
    });
  });

  // ---------------------------------------------------------------------------
  // watchActiveSessionTasks
  // ---------------------------------------------------------------------------

  group('FocusSessionDao — watchActiveSessionTasks', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('returns empty list when no session is open', () async {
      final tasks =
          await db.focusSessionDao.watchActiveSessionTasks().first;
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
          await db.focusSessionDao.watchActiveSessionTasks().first;
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
          await db.focusSessionDao.watchActiveSessionTasks().first;
      expect(tasks, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // watchActiveSessionReviewSurface (issue #418)
  // ---------------------------------------------------------------------------

  group('FocusSessionDao — watchActiveSessionReviewSurface', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    Future<void> insertOffPlanTimeLog(
      String sessionId,
      String taskId,
      DateTime startedAt,
    ) async {
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: Value('tl-$taskId'),
            userId: const Value(_userId),
            taskId: Value(taskId),
            startedAt: Value(startedAt.toUtc().toIso8601String()),
            focusSessionId: Value(sessionId),
          ));
    }

    test('returns empty list when no session is open', () async {
      final surface =
          await db.focusSessionDao.watchActiveSessionReviewSurface().first;
      expect(surface, isEmpty);
    });

    test('unions Plan members and off-Plan engaged, Plan first, no duplicates',
        () async {
      await _insertTodo(db, id: 'X', title: 'X');
      await _insertTodo(db, id: 'Y', title: 'Y');
      await _insertTodo(db, id: 'Z', title: 'Z'); // off-Plan

      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['X', 'Y'],
        now: DateTime(2026, 5, 1, 9, 0),
      );
      // Engage X (a Plan member) and off-Plan-engage Z.
      await insertOffPlanTimeLog(sessionId, 'X', DateTime(2026, 5, 1, 9, 30));
      await insertOffPlanTimeLog(sessionId, 'Z', DateTime(2026, 5, 1, 10, 0));

      final surface =
          await db.focusSessionDao.watchActiveSessionReviewSurface().first;
      expect(surface.map((t) => t.id), orderedEquals(['X', 'Y', 'Z']));
      expect(surface.length, 3, reason: 'X must not appear twice.');
    });

    test('does not leak off-Plan engagement from a different (closed) session',
        () async {
      await _insertTodo(db, id: 'X', title: 'X');
      await _insertTodo(db, id: 'Q', title: 'Q');

      final priorId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: [],
        now: DateTime(2026, 4, 30, 9, 0),
      );
      await insertOffPlanTimeLog(priorId, 'Q', DateTime(2026, 4, 30, 10, 0));
      await db.focusSessionDao
          .closeSession(sessionId: priorId, now: DateTime(2026, 4, 30, 17, 0));

      await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['X'],
        now: DateTime(2026, 5, 1, 9, 0),
      );

      final surface =
          await db.focusSessionDao.watchActiveSessionReviewSurface().first;
      expect(surface.map((t) => t.id), unorderedEquals(['X']));
    });
  });

  // ---------------------------------------------------------------------------
  // setTaskDisposition
  // ---------------------------------------------------------------------------

  group('FocusSessionDao — setTaskDisposition', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('writes disposition to the correct task row', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['task1'],
      );

      await db.focusSessionDao.setTaskDisposition(
        sessionId: sessionId,
        taskId: 'task1',
        disposition: 'rollover',
      );

      final rows = await db.customSelect(
        'SELECT disposition FROM focus_session_tasks '
        'WHERE focus_session_id = ? AND task_id = ?',
        variables: [Variable(sessionId), Variable('task1')],
      ).get();
      expect(rows.length, 1);
      expect(rows.first.read<String?>('disposition'), 'rollover');
    });

    test('is idempotent — second call with same value succeeds', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['task1'],
      );

      await db.focusSessionDao.setTaskDisposition(
        sessionId: sessionId,
        taskId: 'task1',
        disposition: 'leave',
      );
      // Second call must not throw.
      await db.focusSessionDao.setTaskDisposition(
        sessionId: sessionId,
        taskId: 'task1',
        disposition: 'leave',
      );

      final rows = await db.customSelect(
        'SELECT disposition FROM focus_session_tasks '
        'WHERE focus_session_id = ? AND task_id = ?',
        variables: [Variable(sessionId), Variable('task1')],
      ).get();
      expect(rows.first.read<String?>('disposition'), 'leave');
    });

    test('throws StateError for a task not in the session', () async {
      final sessionId =
          await db.focusSessionDao.openSession(userId: _userId, taskIds: []);

      expect(
        () => db.focusSessionDao.setTaskDisposition(
          sessionId: sessionId,
          taskId: 'not-in-session',
          disposition: 'rollover',
        ),
        throwsStateError,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // reviewAndCloseSession
  // ---------------------------------------------------------------------------

  group('FocusSessionDao — reviewAndCloseSession', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('closes session and writes all disposition values', () async {
      await _insertTodo(db, id: 'tA', title: 'Task A');
      await _insertTodo(db, id: 'tB', title: 'Task B');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['tA', 'tB'],
      );

      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {'tA': 'rollover', 'tB': 'leave'},
      );

      final session = await (db.select(db.focusSessions)
            ..where((s) => s.id.equals(sessionId)))
          .getSingle();
      expect(session.endedAt, isNotNull);

      final rows = await db.customSelect(
        'SELECT task_id, disposition FROM focus_session_tasks '
        'WHERE focus_session_id = ? ORDER BY task_id',
        variables: [Variable(sessionId)],
      ).get();
      expect(rows.length, 2);
      expect(rows.firstWhere((r) => r.read<String>('task_id') == 'tA')
          .read<String?>('disposition'), 'rollover');
      expect(rows.firstWhere((r) => r.read<String>('task_id') == 'tB')
          .read<String?>('disposition'), 'leave');
    });

    test("updates intent to 'maybe' for 'maybe' disposition tasks", () async {
      await _insertTodo(db, id: 'tC', title: 'Task C');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['tC'],
      );

      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {'tC': 'maybe'},
      );

      final todo = await (db.select(db.todos)
            ..where((t) => t.id.equals('tC')))
          .getSingle();
      expect(todo.intent, 'maybe');
    });

    test("stamps lastClarifiedAt on tasks routed to intent='maybe'", () async {
      // Per CONTEXT.md ~L152, Intent edits stamp last_clarified_at. Sending a
      // task to Someday/Maybe via session review is an Intent edit.
      await _insertTodo(db, id: 'tCs', title: 'Task C-stamp');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['tCs'],
      );

      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {'tCs': 'maybe'},
      );

      final todo = await (db.select(db.todos)
            ..where((t) => t.id.equals('tCs')))
          .getSingle();
      expect(todo.lastClarifiedAt, isNotNull);
    });

    test("does not change intent for 'rollover' or 'leave' tasks", () async {
      await _insertTodo(db, id: 'tD', title: 'Task D');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['tD'],
      );

      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {'tD': 'rollover'},
      );

      final todo = await (db.select(db.todos)
            ..where((t) => t.id.equals('tD')))
          .getSingle();
      expect(todo.intent, 'next');
    });

    test('closes any open time log for the session', () async {
      await _insertTodo(db, id: 'tE', title: 'Task E');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['tE'],
      );
      await db.focusSessionDao.setCurrentTask(
          sessionId: sessionId, taskId: 'tE');

      final logBefore = await db.timeLogDao.watchActiveLog().first;
      expect(logBefore, isNotNull);

      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {'tE': 'leave'},
      );

      final logAfter = await db.timeLogDao.watchActiveLog().first;
      expect(logAfter, isNull);
    });

    test('with empty dispositions map still closes the session', () async {
      final sessionId =
          await db.focusSessionDao.openSession(userId: _userId, taskIds: []);

      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {},
      );

      final active = await db.focusSessionDao.getActiveSession();
      expect(active, isNull);
    });

    test(
        'skips a disposition for an Outcome neither on the Plan nor engaged '
        '(off the Review surface — no phantom row, no Intent flip)', () async {
      await _insertTodo(db, id: 'tP', title: 'Plan member');
      await _insertTodo(db, id: 'tGhost', title: 'Neither planned nor engaged');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['tP'],
      );

      // tGhost has no focus_session_tasks row and no TimeLog for the session,
      // so it is not on the Review surface (Plan ∪ engaged) — a stale caller
      // key. It must be dropped rather than persisted or mutated.
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {'tP': 'leave', 'tGhost': 'maybe'},
      );

      final dispRows = await db.customSelect(
        'SELECT task_id FROM focus_session_dispositions '
        'WHERE focus_session_id = ?',
        variables: [Variable(sessionId)],
      ).get();
      expect(dispRows, isEmpty,
          reason: 'No disposition row for an off-surface Outcome.');

      final ghost = await (db.select(db.todos)
            ..where((t) => t.id.equals('tGhost')))
          .getSingle();
      expect(ghost.intent, isNot('maybe'),
          reason: "A 'maybe' for an off-surface Outcome must not flip Intent.");
    });
  });

  // ---------------------------------------------------------------------------
  // getLastClosedSessionRolloverTaskIds
  // ---------------------------------------------------------------------------

  group('FocusSessionDao — getLastClosedSessionRolloverTaskIds', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('returns empty list when no closed sessions exist', () async {
      final ids = await db.focusSessionDao
          .getLastClosedSessionRolloverTaskIds();
      expect(ids, isEmpty);
    });

    test('returns rollover task IDs from the most recently closed session',
        () async {
      await _insertTodo(db, id: 'tA', title: 'A');
      await _insertTodo(db, id: 'tB', title: 'B');
      await _insertTodo(db, id: 'tC', title: 'C');

      // First (older) session — tA rolled over.
      final t1 = DateTime(2026, 4, 28, 9, 0);
      final t1End = DateTime(2026, 4, 28, 17, 0);
      final firstId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['tA'],
        now: t1,
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: firstId,
        dispositions: {'tA': 'rollover'},
        now: t1End,
      );

      // Second (newer) session — tB rolled over, tC left.
      final t2 = DateTime(2026, 4, 29, 9, 0);
      final t2End = DateTime(2026, 4, 29, 17, 0);
      final secondId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['tB', 'tC'],
        now: t2,
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: secondId,
        dispositions: {'tB': 'rollover', 'tC': 'leave'},
        now: t2End,
      );

      final ids = await db.focusSessionDao
          .getLastClosedSessionRolloverTaskIds();
      expect(ids, unorderedEquals(['tB']));
    });

    test('excludes rollover tasks from older sessions', () async {
      await _insertTodo(db, id: 'old', title: 'Old');
      await _insertTodo(db, id: 'new', title: 'New');

      final t1End = DateTime(2026, 4, 28, 17, 0);
      final oldId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['old'],
        now: DateTime(2026, 4, 28, 9, 0),
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: oldId,
        dispositions: {'old': 'rollover'},
        now: t1End,
      );

      final t2End = DateTime(2026, 4, 29, 17, 0);
      final newId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['new'],
        now: DateTime(2026, 4, 29, 9, 0),
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: newId,
        dispositions: {'new': 'leave'},
        now: t2End,
      );

      final ids = await db.focusSessionDao
          .getLastClosedSessionRolloverTaskIds();
      // 'old' is from an older session and must not appear.
      expect(ids, isEmpty);
    });
  });
}
