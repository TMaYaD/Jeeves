/// Tests for FocusSessionDao — open/close sessions, current-task management,
/// and session-task queries.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/focus_session_dao.dart'
    show SessionSettlement;
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
      // `id` is the sync row identifier the op log names the entity by — the
      // domain key is (focus_session_id, task_id), so the row carries one
      // anyway, NOT NULL and unique (ADR-0025).
      for (final row in rows) {
        final id = row.read<String?>('id');
        expect(id, isNotNull);
        expect(id, isNotEmpty);
      }
    });

    test('inserts task rows carrying the session user_id (denormalized so a '
        'junction row names its owner without a JOIN)', () async {
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

    test('throws when a session is already open — never auto-closes it '
        '(ADR-0020)', () async {
      final firstId =
          await db.focusSessionDao.openSession(userId: _userId, taskIds: []);

      // Opening a second session must throw — the sole enforcement of the
      // single-open-session invariant. The prior session is left untouched.
      await expectLater(
        db.focusSessionDao.openSession(userId: _userId, taskIds: []),
        throwsA(isA<StateError>()),
      );

      // The transaction rolled back: still exactly one open session, the first.
      final allSessions = await db.select(db.focusSessions).get();
      expect(allSessions, hasLength(1));
      final active = await db.focusSessionDao.getActiveSession();
      expect(active?.id, firstId);
      expect(active?.endedAt, isNull);
    });

    test('opens a new session once the prior one has been closed', () async {
      final firstId =
          await db.focusSessionDao.openSession(userId: _userId, taskIds: []);
      await db.focusSessionDao.closeSession(sessionId: firstId);

      final secondId =
          await db.focusSessionDao.openSession(userId: _userId, taskIds: []);
      final active = await db.focusSessionDao.getActiveSession();
      expect(active?.id, secondId);
    });
  });

  // ---------------------------------------------------------------------------
  // watchQualifyingSessionExists — ES-anchor day attribution (ADR-0020)
  // ---------------------------------------------------------------------------

  group('FocusSessionDao — qualifying session (ES-anchor attribution)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    // Anchor is 18:00 local; sessions are placed relative to it.
    final esAnchor = DateTime(2026, 5, 20, 18, 0);

    Future<String> openAt(DateTime startedAt) async =>
        db.focusSessionDao.openSession(userId: _userId, taskIds: [], now: startedAt);

    test('no sessions → false', () async {
      expect(await db.focusSessionDao.qualifyingSessionExists(esAnchor), isFalse);
    });

    test('started after the anchor, still open → true', () async {
      await openAt(esAnchor.add(const Duration(minutes: 30)));
      expect(await db.focusSessionDao.qualifyingSessionExists(esAnchor), isTrue);
    });

    test('started after the anchor, already closed → true (ended_at plays '
        'no part)', () async {
      final id = await openAt(esAnchor.add(const Duration(minutes: 30)));
      await db.focusSessionDao.closeSession(
          sessionId: id, now: esAnchor.add(const Duration(hours: 1)));
      expect(await db.focusSessionDao.qualifyingSessionExists(esAnchor), isTrue);
    });

    test('started exactly at the anchor → true (>= boundary)', () async {
      await openAt(esAnchor);
      expect(await db.focusSessionDao.qualifyingSessionExists(esAnchor), isTrue);
    });

    test('started before the anchor, still open → false (stale open)',
        () async {
      await openAt(esAnchor.subtract(const Duration(hours: 3)));
      expect(await db.focusSessionDao.qualifyingSessionExists(esAnchor), isFalse);
    });

    test('started before the anchor, closed after it → false '
        '(start-time only)', () async {
      final id = await openAt(esAnchor.subtract(const Duration(hours: 3)));
      await db.focusSessionDao.closeSession(
          sessionId: id, now: esAnchor.add(const Duration(hours: 1)));
      expect(await db.focusSessionDao.qualifyingSessionExists(esAnchor), isFalse);
    });

    test('watch stream re-emits false → true when a qualifying session opens',
        () async {
      final stream = db.focusSessionDao.watchQualifyingSessionExists(esAnchor);
      expect(await stream.first, isFalse);
      await openAt(esAnchor.add(const Duration(minutes: 10)));
      expect(
        await stream.firstWhere((v) => v),
        isTrue,
      );
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

    test('attributes the opened log to the task\'s current Action (issue #476)',
        () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      await db.actionDao.setCurrentAction('task1', 'do the thing');
      final current = await db.actionDao.getCurrentAction('task1');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['task1'],
      );

      await db.focusSessionDao.setCurrentTask(
          sessionId: sessionId, taskId: 'task1', now: DateTime(2026, 4, 28, 9));

      final log = await db.timeLogDao.watchActiveLog().first;
      expect(log!.actionId, current!.id);
    });

    test('leaves action_id NULL when the focused task is Actionless (#476)',
        () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['task1'],
      );

      await db.focusSessionDao.setCurrentTask(
          sessionId: sessionId, taskId: 'task1', now: DateTime(2026, 4, 28, 9));

      final log = await db.timeLogDao.watchActiveLog().first;
      expect(log!.actionId, isNull);
    });

    test('switching tasks opens the new log against the new task\'s Action',
        () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      await _insertTodo(db, id: 'task2', title: 'Task 2');
      await db.actionDao.setCurrentAction('task1', 'step on one');
      await db.actionDao.setCurrentAction('task2', 'step on two');
      final action2 = await db.actionDao.getCurrentAction('task2');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['task1', 'task2'],
      );
      final t1 = DateTime(2026, 4, 28, 9, 0, 0);
      final t2 = DateTime(2026, 4, 28, 9, 30, 0);

      await db.focusSessionDao
          .setCurrentTask(sessionId: sessionId, taskId: 'task1', now: t1);
      await db.focusSessionDao
          .setCurrentTask(sessionId: sessionId, taskId: 'task2', now: t2);

      final active = await db.timeLogDao.watchActiveLog().first;
      expect(active!.taskId, 'task2');
      expect(active.actionId, action2!.id);
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
  // The multi-open-session conflict (issue #600)
  //
  // `openSession`'s StateError is the *sole* enforcement of the
  // single-open-session invariant (ADR-0020) — reduced state converges without
  // consulting a local constraint, so two devices can each open a session
  // offline and both rows land here on the next pull. The rows are inserted
  // directly, which is exactly what the projector does on that pull.
  //
  // Every read then has to answer, and answer the *same* row: a reader that
  // raised would take the Focus surface down, and readers that disagreed would
  // render one session's Plan under another session's identity.
  // ---------------------------------------------------------------------------

  group('FocusSessionDao — two open sessions (sync conflict)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    /// Lands an open session the way a pull does: straight into the table,
    /// past the writer's guard.
    Future<void> project(String id, DateTime startedAt) =>
        db.into(db.focusSessions).insert(FocusSessionsCompanion(
              id: Value(id),
              userId: const Value(_userId),
              startedAt: Value(startedAt.toUtc().toIso8601String()),
              endedAt: const Value(null),
            ));

    /// Inserted oldest-first, so a query with no ORDER BY answers `older`
    /// (rowid order) and only the blessed ordering answers `newer`.
    Future<void> twoOpen() async {
      await project('older', DateTime.utc(2026, 7, 28, 9));
      await project('newer', DateTime.utc(2026, 7, 29, 9));
    }

    test('getActiveSession answers the winner rather than raising', () async {
      await twoOpen();

      final session = await db.focusSessionDao.getActiveSession();

      expect(session, isNotNull);
      expect(session!.id, 'newer',
          reason: 'greatest started_at wins, tie-break smallest id');
    });

    test('watchActiveSession emits the winner rather than erroring', () async {
      await twoOpen();

      await expectLater(
        db.focusSessionDao.watchActiveSession().first,
        completion(isA<FocusSession>().having((s) => s.id, 'id', 'newer')),
      );
    });

    test('the Plan reads agree with the active-session reader', () async {
      await _insertTodo(db, id: 'tOld', title: 'Yesterday');
      await _insertTodo(db, id: 'tNew', title: 'Today');
      await twoOpen();
      await db.into(db.focusSessionTasks).insert(FocusSessionTasksCompanion(
            id: const Value('fst-old'),
            focusSessionId: const Value('older'),
            taskId: const Value('tOld'),
            position: const Value(0),
            userId: const Value(_userId),
          ));
      await db.into(db.focusSessionTasks).insert(FocusSessionTasksCompanion(
            id: const Value('fst-new'),
            focusSessionId: const Value('newer'),
            taskId: const Value('tNew'),
            position: const Value(0),
            userId: const Value(_userId),
          ));

      final active = await db.focusSessionDao.getActiveSession();
      final tasks = await db.focusSessionDao.watchActiveSessionTasks().first;
      final review =
          await db.focusSessionDao.watchActiveSessionReviewSurface().first;

      expect(active!.id, 'newer');
      expect(tasks.map((t) => t.id), ['tNew'],
          reason: 'the Plan must belong to the session the readers call active');
      expect(review.map((t) => t.id), ['tNew']);
    });

    test('openSession names the session the readers call active', () async {
      await twoOpen();

      await expectLater(
        db.focusSessionDao.openSession(userId: _userId, taskIds: []),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('newer'),
        )),
      );
    });

    test('breaks an equal-started_at tie on the smallest id', () async {
      // The different-timestamp fixtures never exercise the `id ASC` tie-break,
      // so a regression that dropped it would still pass. Two sessions that
      // start in the same instant (a cross-device race can land exactly that)
      // must resolve deterministically to the smallest id. Inserted in reverse
      // id order so rowid order would answer 'z-session'.
      final startedAt = DateTime.utc(2026, 7, 29, 9);
      await project('z-session', startedAt);
      await project('a-session', startedAt);

      final session = await db.focusSessionDao.getActiveSession();

      expect(session?.id, 'a-session',
          reason: 'equal started_at, tie-break smallest id');
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

    test(
        'time spent on a Review-surface Outcome sums its session time_logs '
        '(issue #480, #604)', () async {
      await _insertTodo(db, id: 'X', title: 'X');

      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['X'],
        now: DateTime(2026, 5, 1, 9, 0),
      );
      // Two closed stints: 25 minutes + 10 minutes.
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('tl-X-1'),
            userId: const Value(_userId),
            taskId: const Value('X'),
            startedAt:
                Value(DateTime.utc(2026, 5, 1, 9, 30).toIso8601String()),
            endedAt: Value(DateTime.utc(2026, 5, 1, 9, 55).toIso8601String()),
            focusSessionId: Value(sessionId),
          ));
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('tl-X-2'),
            userId: const Value(_userId),
            taskId: const Value('X'),
            startedAt:
                Value(DateTime.utc(2026, 5, 1, 10, 0).toIso8601String()),
            endedAt: Value(DateTime.utc(2026, 5, 1, 10, 10).toIso8601String()),
            focusSessionId: Value(sessionId),
          ));

      final surface =
          await db.focusSessionDao.watchActiveSessionReviewSurface().first;
      expect(surface.single.id, 'X',
          reason: 'the Outcome is on the Review surface');
      // The surface carries no total; the derivation lives on TimeLogDao and is
      // what every consumer reads (issue #604).
      expect(await db.timeLogDao.totalMinutesForTask('X'), 35,
          reason: 'SUM(time_logs) across both stints');
    });

    test(
        'time spent spans all sessions, not just the open one '
        '(cumulative, TimeLogDao.totalMinutesForTask)', () async {
      await _insertTodo(db, id: 'X', title: 'X');

      final priorId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['X'],
        now: DateTime(2026, 4, 30, 9, 0),
      );
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('tl-X-prior'),
            userId: const Value(_userId),
            taskId: const Value('X'),
            startedAt:
                Value(DateTime.utc(2026, 4, 30, 9, 30).toIso8601String()),
            endedAt: Value(DateTime.utc(2026, 4, 30, 9, 50).toIso8601String()),
            focusSessionId: Value(priorId),
          ));
      await db.focusSessionDao
          .closeSession(sessionId: priorId, now: DateTime(2026, 4, 30, 17, 0));

      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['X'],
        now: DateTime(2026, 5, 1, 9, 0),
      );
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('tl-X-today'),
            userId: const Value(_userId),
            taskId: const Value('X'),
            startedAt:
                Value(DateTime.utc(2026, 5, 1, 9, 30).toIso8601String()),
            endedAt: Value(DateTime.utc(2026, 5, 1, 9, 45).toIso8601String()),
            focusSessionId: Value(sessionId),
          ));

      final surface =
          await db.focusSessionDao.watchActiveSessionReviewSurface().first;
      expect(surface.single.id, 'X');
      expect(await db.timeLogDao.totalMinutesForTask('X'), 35,
          reason: '20m from the prior session + 15m today');
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

  // ---------------------------------------------------------------------------
  // watchLastClosedSessionRolloverTasks — the Todo-row, reactive counterpart of
  // getLastClosedSessionRolloverTaskIds (shares its rollover-ids SQL).
  // ---------------------------------------------------------------------------

  group('FocusSessionDao — watchLastClosedSessionRolloverTasks', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('emits empty list when no closed sessions exist', () async {
      final tasks = await db.focusSessionDao
          .watchLastClosedSessionRolloverTasks()
          .first;
      expect(tasks, isEmpty);
    });

    test('emits rollover Todo rows from the most recently closed session',
        () async {
      await _insertTodo(db, id: 'tA', title: 'A');
      await _insertTodo(db, id: 'tB', title: 'B');
      await _insertTodo(db, id: 'tC', title: 'C');

      // First (older) session — tA rolled over.
      final firstId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['tA'],
        now: DateTime(2026, 4, 28, 9, 0),
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: firstId,
        dispositions: {'tA': 'rollover'},
        now: DateTime(2026, 4, 28, 17, 0),
      );

      // Second (newer) session — tB rolled over, tC left.
      final secondId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['tB', 'tC'],
        now: DateTime(2026, 4, 29, 9, 0),
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: secondId,
        dispositions: {'tB': 'rollover', 'tC': 'leave'},
        now: DateTime(2026, 4, 29, 17, 0),
      );

      final tasks = await db.focusSessionDao
          .watchLastClosedSessionRolloverTasks()
          .first;
      // Only tB (rollover, newest session); tC (leave) and tA (older) excluded.
      expect(tasks.map((t) => t.id), unorderedEquals(['tB']));
      expect(tasks.single.title, 'B');
    });

    test('re-emits when a session closes', () async {
      await _insertTodo(db, id: 'x', title: 'X');
      final stream =
          db.focusSessionDao.watchLastClosedSessionRolloverTasks();
      final future = expectLater(
        stream.map((rows) => rows.map((t) => t.id).toList()),
        emitsInOrder([
          <String>[],
          ['x'],
        ]),
      );

      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['x'],
        now: DateTime(2026, 4, 29, 9, 0),
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {'x': 'rollover'},
        now: DateTime(2026, 4, 29, 17, 0),
      );

      await future;
    });
  });

  // ---------------------------------------------------------------------------
  // Settlements (#693) — derived, session-scoped, writes nothing
  // ---------------------------------------------------------------------------

  group('FocusSessionDao — active session Settlements', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    final anchorAt = DateTime.utc(2026, 5, 1, 10, 0);

    /// The two facts the settlement anchor joins: a `done` Action on [taskId],
    /// and a TimeLog attributing that Action's engagement to [sessionId].
    Future<String> completeActionInSession(
      String sessionId,
      String taskId, {
      DateTime? doneAt,
      String? actionId,
    }) async {
      final at = doneAt ?? anchorAt;
      final aid = actionId ?? 'act-$taskId';
      await db.into(db.actions).insert(ActionsCompanion(
            id: Value(aid),
            outcomeId: Value(taskId),
            userId: const Value(_userId),
            actionText: const Value('do the thing'),
            role: const Value('done'),
            doneAt: Value(at),
            createdAt: Value(at.subtract(const Duration(hours: 2))),
          ));
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: Value('tl-$aid'),
            userId: const Value(_userId),
            taskId: Value(taskId),
            actionId: Value(aid),
            startedAt:
                Value(at.subtract(const Duration(minutes: 25)).toIso8601String()),
            endedAt: Value(at.toIso8601String()),
            focusSessionId: Value(sessionId),
          ));
      return aid;
    }

    Future<void> reclarifyAt(String taskId, DateTime at) =>
        (db.update(db.todos)..where((t) => t.id.equals(taskId)))
            .write(TodosCompanion(lastClarifiedAt: Value(at)));

    Future<void> seedCurrent(String taskId, {DateTime? createdAt}) =>
        db.into(db.actions).insert(ActionsCompanion(
              id: Value('cur-$taskId'),
              outcomeId: Value(taskId),
              userId: const Value(_userId),
              actionText: const Value('the next move'),
              role: const Value('current'),
              createdAt: Value(createdAt ?? anchorAt.add(const Duration(minutes: 1))),
            ));

    Future<void> tagPerson(String taskId) async {
      await db.into(db.tags).insert(
            TagsCompanion(
              id: const Value('tag-person'),
              name: const Value('Trixy'),
              type: const Value('person'),
              userId: const Value(_userId),
            ),
            mode: InsertMode.insertOrReplace,
          );
      await db.into(db.todoTags).insert(TodoTagsCompanion(
            id: Value('tt-$taskId'),
            todoId: Value(taskId),
            tagId: const Value('tag-person'),
            userId: const Value(_userId),
          ));
    }

    Future<void> setIntent(String taskId, String intent) =>
        (db.update(db.todos)..where((t) => t.id.equals(taskId)))
            .write(TodosCompanion(intent: Value(intent)));

    Future<String> openWith(List<String> taskIds) => db.focusSessionDao
        .openSession(userId: _userId, taskIds: taskIds, now: DateTime(2026, 5, 1, 9));

    test('no open session settles nothing, on both surfaces', () async {
      expect(await db.focusSessionDao.getActiveSessionSettlements(), isEmpty);
      expect(
        await db.focusSessionDao.watchActiveSessionSettlements().first,
        isEmpty,
      );
    });

    test('a completed Outcome settles as done (arm (a), #693 AC4)', () async {
      await _insertTodo(db, id: 'X', title: 'X');
      await openWith(['X']);
      await (db.update(db.todos)..where((t) => t.id.equals('X'))).write(
        TodosCompanion(doneAt: Value(anchorAt.toIso8601String())),
      );

      expect(
        await db.focusSessionDao.getActiveSessionSettlements(),
        {'X': SessionSettlement.done},
      );
    });

    test(
        'an Action completed in-session then re-clarified settles as next '
        '(arm (b)) — and the watcher agrees with the one-shot', () async {
      await _insertTodo(db, id: 'X', title: 'X');
      final sessionId = await openWith(['X']);
      await completeActionInSession(sessionId, 'X');
      await reclarifyAt('X', anchorAt.add(const Duration(seconds: 5)));
      await seedCurrent('X');

      expect(
        await db.focusSessionDao.getActiveSessionSettlements(),
        {'X': SessionSettlement.next},
      );
      expect(
        await db.focusSessionDao.watchActiveSessionSettlements().first,
        {'X': SessionSettlement.next},
      );
    });

    test('intent = maybe wins over a current Action → someday', () async {
      await _insertTodo(db, id: 'X', title: 'X');
      final sessionId = await openWith(['X']);
      await completeActionInSession(sessionId, 'X');
      await reclarifyAt('X', anchorAt.add(const Duration(seconds: 5)));
      await setIntent('X', 'maybe');

      expect(
        await db.focusSessionDao.getActiveSessionSettlements(),
        {'X': SessionSettlement.someday},
      );
    });

    test('a person Tag with no current Action → waitingFor', () async {
      await _insertTodo(db, id: 'X', title: 'X');
      final sessionId = await openWith(['X']);
      await completeActionInSession(sessionId, 'X');
      await reclarifyAt('X', anchorAt.add(const Duration(seconds: 5)));
      await tagPerson('X');

      expect(
        await db.focusSessionDao.getActiveSessionSettlements(),
        {'X': SessionSettlement.waitingFor},
      );
    });

    test(
        'a person Tag AND a current Action → next: rung 3 sits ahead of rung 4',
        () async {
      await _insertTodo(db, id: 'X', title: 'X');
      final sessionId = await openWith(['X']);
      await completeActionInSession(sessionId, 'X');
      await reclarifyAt('X', anchorAt.add(const Duration(seconds: 5)));
      await tagPerson('X');
      await seedCurrent('X');

      expect(
        await db.focusSessionDao.getActiveSessionSettlements(),
        {'X': SessionSettlement.next},
        reason: 'the user gave it a next move; that is what the summary says',
      );
    });

    test(
        're-planned by promoting an already-queued Action → next, even when '
        'the Outcome carries a person Tag (created_at is untouched by promote)',
        () async {
      await _insertTodo(db, id: 'X', title: 'X');
      final sessionId = await openWith(['X']);
      await tagPerson('X');
      // A planned Action that predates the session entirely.
      await db.actionDao.addPlannedAction(
        'X',
        'the queued move',
        now: DateTime.utc(2026, 4, 20, 9),
      );
      await completeActionInSession(sessionId, 'X');
      final planned = await (db.select(db.actions)
            ..where((a) => a.outcomeId.equals('X') & a.role.equals('planned')))
          .getSingle();
      // Promote stamps last_clarified_at, so this alone settles the row.
      await db.actionDao.promotePlannedAction(
        planned.id,
        now: anchorAt.add(const Duration(seconds: 5)),
      );

      expect(
        await db.focusSessionDao.getActiveSessionSettlements(),
        {'X': SessionSettlement.next},
      );
    });

    test('an Action completed in a different session does not settle',
        () async {
      await _insertTodo(db, id: 'X', title: 'X');
      final priorId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['X'],
        now: DateTime(2026, 4, 30, 9),
      );
      await completeActionInSession(priorId, 'X',
          doneAt: DateTime.utc(2026, 4, 30, 10));
      await db.focusSessionDao
          .closeSession(sessionId: priorId, now: DateTime(2026, 4, 30, 17));
      await reclarifyAt('X', DateTime.utc(2026, 4, 30, 11));

      await openWith(['X']);

      expect(await db.focusSessionDao.getActiveSessionSettlements(), isEmpty,
          reason: 'attribution is by session id, never a wall-clock window');
    });

    test('completed but never re-clarified does not settle', () async {
      await _insertTodo(db, id: 'X', title: 'X');
      final sessionId = await openWith(['X']);
      await completeActionInSession(sessionId, 'X');

      expect(await db.focusSessionDao.getActiveSessionSettlements(), isEmpty,
          reason:
              'a dismissed re-clarify sheet writes nothing — the Outcome still '
              'owes an answer and belongs in the disposition step');
    });

    test('re-clarified *before* the completion does not settle', () async {
      await _insertTodo(db, id: 'X', title: 'X');
      final sessionId = await openWith(['X']);
      await reclarifyAt('X', anchorAt.subtract(const Duration(hours: 1)));
      await completeActionInSession(sessionId, 'X');

      expect(await db.focusSessionDao.getActiveSessionSettlements(), isEmpty);
    });

    test('an off-Plan engaged Outcome settles the same as a Plan member',
        () async {
      await _insertTodo(db, id: 'X', title: 'X'); // Plan member
      await _insertTodo(db, id: 'Z', title: 'Z'); // off-Plan
      final sessionId = await openWith(['X']);
      await completeActionInSession(sessionId, 'Z');
      await reclarifyAt('Z', anchorAt.add(const Duration(seconds: 5)));
      await seedCurrent('Z');

      expect(
        await db.focusSessionDao.getActiveSessionSettlements(),
        {'Z': SessionSettlement.next},
      );
    });

    test(
        'an Actionless engagement never settles under arm (b): the TimeLog '
        'carries no action_id, so there is no anchor to compare against',
        () async {
      await _insertTodo(db, id: 'X', title: 'X');
      final sessionId = await openWith(['X']);
      // A sprint started on an Actionless Plan member: task-attributed, but
      // action_id IS NULL (TimeLogDao's resolver finds nothing `current`).
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('tl-actionless'),
            userId: const Value(_userId),
            taskId: const Value('X'),
            startedAt: Value(anchorAt.toIso8601String()),
            focusSessionId: Value(sessionId),
          ));
      await reclarifyAt('X', anchorAt.add(const Duration(minutes: 5)));
      await seedCurrent('X');

      expect(await db.focusSessionDao.getActiveSessionSettlements(), isEmpty,
          reason:
              'documented hole: no Action was completed, so nothing settled');
    });

    test(
        'Settlement is a read: it changes no GTD List membership and writes '
        'nothing (#693 AC5)', () async {
      await _insertTodo(db, id: 'N', title: 'still on Next');
      await _insertTodo(db, id: 'W', title: 'waiting on Trixy');
      final sessionId = await openWith(['N', 'W']);

      await completeActionInSession(sessionId, 'N');
      await reclarifyAt('N', anchorAt.add(const Duration(seconds: 5)));
      await seedCurrent('N');

      await completeActionInSession(sessionId, 'W');
      await reclarifyAt('W', anchorAt.add(const Duration(seconds: 5)));
      await tagPerson('W');

      final before = await db.select(db.todos).get();
      final settlements =
          await db.focusSessionDao.getActiveSessionSettlements();
      expect(settlements,
          {'N': SessionSettlement.next, 'W': SessionSettlement.waitingFor});

      // Exactly what each verdict implies — Settlement did not move anything.
      expect((await db.todoDao.watchNext().first).map((t) => t.id),
          contains('N'));
      expect((await db.todoDao.watchPersonTagged().first).map((t) => t.id),
          contains('W'));
      expect((await db.todoDao.watchMaybe().first), isEmpty);

      expect(await db.select(db.todos).get(), equals(before),
          reason: 'reading Settlements must never write through');
    });
  });
}
