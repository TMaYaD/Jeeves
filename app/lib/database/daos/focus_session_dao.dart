/// DAO for FocusSession lifecycle: open/close sessions, set current task,
/// and query session tasks for display.
library;

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart' show uuid;
import 'package:uuid/enums.dart' show Namespace;

import '../gtd_database.dart';

part 'focus_session_dao.g.dart';

/// Deterministic `focus_session_dispositions.id` for the (sessionId, taskId)
/// pair.
///
/// PowerSync exposes `focus_session_dispositions` as a view whose INSTEAD OF
/// INSERT trigger writes `NEW.id` into the backing table, so the row needs an
/// explicit id; deriving it from the pair makes re-recording a disposition
/// collapse under INSERT OR REPLACE onto the same row instead of accumulating
/// duplicates (todo_tags / capture_outcomes precedent).
String focusSessionDispositionIdFor(String sessionId, String taskId) => uuid.v5(
      Namespace.url.value,
      'jeeves://focus_session_disposition/$sessionId/$taskId',
    );

@DriftAccessor(
    tables: [FocusSessions, FocusSessionTasks, FocusSessionDispositions, TimeLogs, Todos])
class FocusSessionDao extends DatabaseAccessor<GtdDatabase>
    with _$FocusSessionDaoMixin {
  FocusSessionDao(super.db);

  /// Opens a new planning session for [userId] with [taskIds] as the day's
  /// task list. Closes any previously open session first.
  ///
  /// Returns the new session's id. Runs atomically in a transaction.
  ///
  /// [now] is injectable for deterministic testing; defaults to [DateTime.now].
  Future<String> openSession({
    required String userId,
    required List<String> taskIds,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc().toIso8601String();
    final newId = uuid.v4();

    await transaction(() async {
      // Close any open session (and its open time log).
      final existing = await (select(focusSessions)
            ..where((s) => s.endedAt.isNull()))
          .getSingleOrNull();
      if (existing != null) {
        // Close open time log before closing session.
        await (update(timeLogs)
              ..where((t) =>
                  t.endedAt.isNull() &
                  t.focusSessionId.equals(existing.id)))
            .write(TimeLogsCompanion(endedAt: Value(ts)));
        await (update(focusSessions)
              ..where((s) => s.id.equals(existing.id)))
            .write(FocusSessionsCompanion(endedAt: Value(ts)));
      }

      // Insert the new open session.
      await into(focusSessions).insert(FocusSessionsCompanion(
        id: Value(newId),
        userId: Value(userId),
        startedAt: Value(ts),
        endedAt: const Value(null),
        currentTaskId: const Value(null),
      ));

      // Insert task rows.
      for (var i = 0; i < taskIds.length; i++) {
        await into(focusSessionTasks).insert(FocusSessionTasksCompanion(
          id: Value(uuid.v4()),
          focusSessionId: Value(newId),
          taskId: Value(taskIds[i]),
          position: Value(i),
          userId: Value(userId),
        ));
      }
    });

    return newId;
  }

  /// Closes [sessionId], setting its [ended_at] and clearing
  /// [current_task_id]. Also closes any open time log for the session.
  ///
  /// [now] is injectable for deterministic testing.
  Future<void> closeSession({required String sessionId, DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc().toIso8601String();

    await transaction(() async {
      final session = await (select(focusSessions)
            ..where((s) => s.id.equals(sessionId) & s.endedAt.isNull()))
          .getSingleOrNull();
      if (session == null) return;

      // Close only the open time log that belongs to this session.
      await (update(timeLogs)
            ..where((t) =>
                t.endedAt.isNull() &
                t.focusSessionId.equals(sessionId)))
          .write(TimeLogsCompanion(endedAt: Value(ts)));

      await (update(focusSessions)..where((s) => s.id.equals(sessionId)))
          .write(FocusSessionsCompanion(
        endedAt: Value(ts),
        currentTaskId: const Value(null),
      ));
    });
  }

  /// Atomically closes any open time log for the session, optionally opens a
  /// new one for [taskId], and updates [current_task_id] on the session row.
  ///
  /// [taskId] need not be a Plan member: the Focus may point to any Outcome
  /// being engaged, whether or not it is on the Plan (CONTEXT.md
  /// § Engagement; ADR-0005). Off-Plan engagement still attributes the
  /// TimeLog to the session and surfaces in Review via the TimeLog union —
  /// the Plan itself never auto-grows (ADR-0002).
  ///
  /// Pass [taskId] = null to clear the focused task without starting a new log.
  ///
  /// [now] is injectable for deterministic testing.
  Future<void> setCurrentTask({
    required String sessionId,
    String? taskId,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc().toIso8601String();

    await transaction(() async {
      final session = await (select(focusSessions)
            ..where((s) => s.id.equals(sessionId) & s.endedAt.isNull()))
          .getSingleOrNull();
      if (session == null) return;

      // Close any open time log. The single-open-log invariant is global,
      // so we close defensively rather than scoping to this session — a stray
      // open log from elsewhere would otherwise coexist with the new one.
      await (update(timeLogs)..where((t) => t.endedAt.isNull()))
          .write(TimeLogsCompanion(endedAt: Value(ts)));

      // Open a new time log if a task is being focused.
      if (taskId != null) {
        await into(timeLogs).insert(TimeLogsCompanion(
          id: Value(uuid.v4()),
          userId: Value(session.userId),
          taskId: Value(taskId),
          startedAt: Value(ts),
          endedAt: const Value(null),
          focusSessionId: Value(sessionId),
        ));
      }

      // Update the session pointer.
      await (update(focusSessions)..where((s) => s.id.equals(sessionId)))
          .write(FocusSessionsCompanion(currentTaskId: Value(taskId)));
    });
  }

  /// Stream that emits the currently open session, or null.
  Stream<FocusSession?> watchActiveSession() =>
      (select(focusSessions)..where((s) => s.endedAt.isNull()))
          .watchSingleOrNull();

  /// One-shot query for the currently open session.
  Future<FocusSession?> getActiveSession() =>
      (select(focusSessions)..where((s) => s.endedAt.isNull()))
          .getSingleOrNull();

  /// Stream of [Todo] rows that are members of [sessionId], ordered by position.
  Stream<List<Todo>> watchSessionTasks(String sessionId) {
    return customSelect(
      'SELECT t.* FROM todos t '
      'JOIN focus_session_tasks fst ON fst.task_id = t.id '
      'WHERE fst.focus_session_id = ? '
      'ORDER BY fst.position',
      variables: [Variable<String>(sessionId)],
      readsFrom: {focusSessionTasks, todos},
    ).watch().map((rows) => rows.map((r) => todos.map(r.data)).toList());
  }

  /// Writes [disposition] to a single [focus_session_tasks] row.
  ///
  /// Throws [StateError] if [taskId] is not a member of [sessionId].
  /// Idempotent — calling twice with the same value is a no-op.
  ///
  /// [disposition] must be one of: 'rollover' | 'leave' | 'maybe'.
  Future<void> setTaskDisposition({
    required String sessionId,
    required String taskId,
    required String disposition,
  }) async {
    final membership = await (select(focusSessionTasks)
          ..where((fst) =>
              fst.focusSessionId.equals(sessionId) &
              fst.taskId.equals(taskId)))
        .getSingleOrNull();
    if (membership == null) {
      throw StateError('Task $taskId is not part of session $sessionId');
    }
    await (update(focusSessionTasks)
          ..where((fst) =>
              fst.focusSessionId.equals(sessionId) &
              fst.taskId.equals(taskId)))
        .write(FocusSessionTasksCompanion(disposition: Value(disposition)));
  }

  /// Atomically records per-task dispositions and closes [sessionId].
  ///
  /// [dispositions] maps task IDs to 'rollover' | 'leave' | 'maybe'.
  /// Done tasks (those with doneAt != null) must not appear in this map —
  /// the caller is responsible for filtering them out.
  ///
  /// Side effects:
  /// - Each 'maybe' task has its intent updated to 'maybe' on [todos].
  /// - Disposition values are persisted by membership class: Plan members to
  ///   [focus_session_tasks], off-Plan engaged Outcomes to
  ///   [focus_session_dispositions] (ADR-0015). The Plan never auto-grows from
  ///   an off-Plan disposition (ADR-0002).
  /// - The session is closed (ended_at set, current_task_id cleared).
  /// - Any open time log for the session is closed.
  ///
  /// [now] is injectable for deterministic testing.
  Future<void> reviewAndCloseSession({
    required String sessionId,
    required Map<String, String> dispositions,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc().toIso8601String();

    await transaction(() async {
      final session = await (select(focusSessions)
            ..where((s) => s.id.equals(sessionId) & s.endedAt.isNull()))
          .getSingleOrNull();
      if (session == null) return;

      // Partition dispositions by Plan membership: a Plan member has a
      // focus_session_tasks row for this session, an off-Plan engaged Outcome
      // does not (ADR-0002).
      final planRows = await (select(focusSessionTasks)
            ..where((fst) => fst.focusSessionId.equals(sessionId)))
          .get();
      final planTaskIds = planRows.map((r) => r.taskId).toSet();

      // Persist dispositions to the correct home.
      for (final entry in dispositions.entries) {
        if (planTaskIds.contains(entry.key)) {
          await (update(focusSessionTasks)
                ..where((fst) =>
                    fst.focusSessionId.equals(sessionId) &
                    fst.taskId.equals(entry.key)))
              .write(FocusSessionTasksCompanion(
            disposition: Value(entry.value),
          ));
        } else {
          // Off-Plan engaged Outcome — no Plan row exists, so its Disposition
          // goes to the separate store. Deterministic id + INSERT OR REPLACE so
          // a re-recorded disposition collapses onto the same row.
          await into(focusSessionDispositions).insert(
            FocusSessionDispositionsCompanion(
              id: Value(focusSessionDispositionIdFor(sessionId, entry.key)),
              focusSessionId: Value(sessionId),
              taskId: Value(entry.key),
              disposition: Value(entry.value),
              userId: Value(session.userId),
            ),
            mode: InsertMode.insertOrReplace,
          );
        }
      }

      // Update intent to 'maybe' for each 'maybe' disposition task.
      //
      // Sending an Outcome to Someday/Maybe is an Intent edit — a clarifying
      // micro-act per CONTEXT.md — so last_clarified_at is stamped alongside.
      for (final entry in dispositions.entries) {
        if (entry.value == 'maybe') {
          await customUpdate(
            'UPDATE todos SET intent = ?, updated_at = ?, '
            'last_clarified_at = ? WHERE id = ?',
            variables: [
              Variable('maybe'),
              Variable(ts),
              Variable(ts),
              Variable(entry.key),
            ],
            updates: {todos},
            updateKind: UpdateKind.update,
          );
        }
      }

      // Stamp last_next_action_completion_at on non-done Outcomes across the
      // Review surface — Plan members ∪ off-Plan engaged (Outcomes with a
      // TimeLog for this session). This marks them as "worked on in a session"
      // for the re-clarification predicate; off-Plan engaged Outcomes were
      // worked on too, so they earn the stamp.
      await customUpdate(
        'UPDATE todos SET last_next_action_completion_at = ? '
        'WHERE id IN ('
        '  SELECT task_id FROM focus_session_tasks '
        '  WHERE focus_session_id = ?'
        '  UNION '
        '  SELECT task_id FROM time_logs '
        '  WHERE focus_session_id = ?'
        ') AND done_at IS NULL AND user_id = ?',
        variables: [
          Variable(ts),
          Variable(sessionId),
          Variable(sessionId),
          Variable(session.userId),
        ],
        updates: {todos},
        updateKind: UpdateKind.update,
      );

      // Close any open time log for this session.
      await (update(timeLogs)
            ..where((t) =>
                t.endedAt.isNull() &
                t.focusSessionId.equals(sessionId)))
          .write(TimeLogsCompanion(endedAt: Value(ts)));

      // Close the session.
      await (update(focusSessions)..where((s) => s.id.equals(sessionId)))
          .write(FocusSessionsCompanion(
        endedAt: Value(ts),
        currentTaskId: const Value(null),
      ));
    });
  }

  /// Returns the task IDs with [disposition] = 'rollover' from the most
  /// recently closed session, across both Disposition homes: Plan members in
  /// [focus_session_tasks] and off-Plan engaged Outcomes in
  /// [focus_session_dispositions] (ADR-0015). The UNION de-duplicates.
  ///
  /// Returns an empty list when no closed session exists or none has rollover
  /// tasks.
  Future<List<String>> getLastClosedSessionRolloverTaskIds() async {
    final rows = await customSelect(
      'SELECT fst.task_id FROM focus_session_tasks fst '
      'JOIN focus_sessions fs ON fs.id = fst.focus_session_id '
      'WHERE fs.ended_at IS NOT NULL '
      'AND fst.disposition = ? '
      'AND fs.ended_at = ('
      '  SELECT MAX(ended_at) FROM focus_sessions '
      '  WHERE ended_at IS NOT NULL'
      ') '
      'UNION '
      'SELECT fsd.task_id FROM focus_session_dispositions fsd '
      'JOIN focus_sessions fs ON fs.id = fsd.focus_session_id '
      'WHERE fs.ended_at IS NOT NULL '
      'AND fsd.disposition = ? '
      'AND fs.ended_at = ('
      '  SELECT MAX(ended_at) FROM focus_sessions '
      '  WHERE ended_at IS NOT NULL'
      ')',
      variables: [
        Variable('rollover'),
        Variable('rollover'),
      ],
      readsFrom: {focusSessions, focusSessionTasks, focusSessionDispositions},
    ).get();
    return rows.map((r) => r.read<String>('task_id')).toList();
  }

  /// Stream of [Todo] rows in the currently open session.
  ///
  /// Joins through [focus_sessions] so no session-ID plumbing is needed at
  /// call sites. Returns an empty list when no session is open.
  Stream<List<Todo>> watchActiveSessionTasks() {
    return customSelect(
      'SELECT t.* FROM todos t '
      'JOIN focus_session_tasks fst ON fst.task_id = t.id '
      'WHERE fst.focus_session_id = ('
      '  SELECT id FROM focus_sessions WHERE ended_at IS NULL LIMIT 1'
      ') '
      'ORDER BY fst.position',
      variables: [],
      readsFrom: {focusSessionTasks, focusSessions, todos},
    ).watch().map((rows) => rows.map((r) => todos.map(r.data)).toList());
  }

  /// Reactive Review surface for the currently open session — the union of
  ///
  /// 1. Outcomes on the session's Plan (rows in [focus_session_tasks]), and
  /// 2. Outcomes engaged with during the session (rows in [time_logs] whose
  ///    [focus_session_id] = the open session).
  ///
  /// The reactive counterpart of [getReviewSurface], scoped to the active
  /// session (`ended_at IS NULL`) so no session-ID plumbing is needed at call
  /// sites — this is what the Evening Shutdown providers watch so off-Plan
  /// engaged Outcomes surface for disposition (CONTEXT.md § Engagement).
  ///
  /// Plan members are ordered by their [focus_session_tasks.position]; off-Plan
  /// engaged Outcomes follow, ordered by the start time of their earliest
  /// TimeLog for the session. Returns an empty list when no session is open.
  Stream<List<Todo>> watchActiveSessionReviewSurface() {
    return customSelect(
      'SELECT t.*, 0 AS surface_order, fst.position AS sort_key '
      'FROM todos t '
      'JOIN focus_session_tasks fst ON fst.task_id = t.id '
      'WHERE fst.focus_session_id = ('
      '  SELECT id FROM focus_sessions WHERE ended_at IS NULL LIMIT 1'
      ') '
      'UNION ALL '
      'SELECT t.*, 1 AS surface_order, '
      '       CAST(strftime(\'%s\', MIN(tl.started_at)) AS INTEGER) AS sort_key '
      'FROM todos t '
      'JOIN time_logs tl ON tl.task_id = t.id '
      'WHERE tl.focus_session_id = ('
      '  SELECT id FROM focus_sessions WHERE ended_at IS NULL LIMIT 1'
      ') '
      '  AND NOT EXISTS ('
      '    SELECT 1 FROM focus_session_tasks fst2 '
      '    WHERE fst2.focus_session_id = ('
      '      SELECT id FROM focus_sessions WHERE ended_at IS NULL LIMIT 1'
      '    ) AND fst2.task_id = t.id'
      '  ) '
      'GROUP BY t.id '
      'ORDER BY surface_order, sort_key',
      variables: [],
      readsFrom: {focusSessionTasks, timeLogs, focusSessions, todos},
    ).watch().map((rows) => rows.map((r) => todos.map(r.data)).toList());
  }

  /// One-shot query of the Review surface for [sessionId] — the union of
  ///
  /// 1. Outcomes on the session's Plan (rows in [focus_session_tasks]), and
  /// 2. Outcomes engaged with during the session (rows in [time_logs] whose
  ///    [focus_session_id] = [sessionId]).
  ///
  /// Per CONTEXT.md (Engagement context, line ~259): "The Review phase
  /// surfaces every Outcome that was either on the Plan or engaged with
  /// during the session (the union), so neither off-Plan work nor
  /// planned-but-untouched Outcomes slip past disposition."
  ///
  /// Plan members are ordered by their [focus_session_tasks.position];
  /// off-Plan engaged Outcomes follow, ordered by the start time of their
  /// earliest TimeLog for the session. The list contains no duplicates.
  Future<List<Todo>> getReviewSurface(String sessionId) async {
    final rows = await customSelect(
      // Plan members first (ordered by position), then off-Plan engaged
      // Outcomes (ordered by earliest TimeLog start for the session).  The
      // GROUP BY on the engaged side de-duplicates Todos that have multiple
      // TimeLogs for the session.  The NOT EXISTS clause keeps Plan members
      // from appearing a second time in the engaged half of the UNION.
      'SELECT t.*, 0 AS surface_order, fst.position AS sort_key '
      'FROM todos t '
      'JOIN focus_session_tasks fst ON fst.task_id = t.id '
      'WHERE fst.focus_session_id = ? '
      'UNION ALL '
      'SELECT t.*, 1 AS surface_order, '
      '       CAST(strftime(\'%s\', MIN(tl.started_at)) AS INTEGER) AS sort_key '
      'FROM todos t '
      'JOIN time_logs tl ON tl.task_id = t.id '
      'WHERE tl.focus_session_id = ? '
      '  AND NOT EXISTS ('
      '    SELECT 1 FROM focus_session_tasks fst2 '
      '    WHERE fst2.focus_session_id = ? AND fst2.task_id = t.id'
      '  ) '
      'GROUP BY t.id '
      'ORDER BY surface_order, sort_key',
      variables: [
        Variable<String>(sessionId),
        Variable<String>(sessionId),
        Variable<String>(sessionId),
      ],
      readsFrom: {focusSessionTasks, timeLogs, todos},
    ).get();
    return rows.map((r) => todos.map(r.data)).toList();
  }
}
