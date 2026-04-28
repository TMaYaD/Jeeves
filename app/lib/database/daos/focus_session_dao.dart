/// DAO for FocusSession lifecycle: open/close sessions, set current task,
/// and query session tasks for display.
library;

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../gtd_database.dart';

part 'focus_session_dao.g.dart';

@DriftAccessor(tables: [FocusSessions, FocusSessionTasks, TimeLogs, Todos])
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
      // Close any open session (and its open time log) for this user.
      final existing = await (select(focusSessions)
            ..where((s) => s.userId.equals(userId) & s.endedAt.isNull()))
          .getSingleOrNull();
      if (existing != null) {
        // Close open time log before closing session.
        await (update(timeLogs)
              ..where((t) => t.userId.equals(userId) & t.endedAt.isNull()))
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
          focusSessionId: Value(newId),
          taskId: Value(taskIds[i]),
          position: Value(i),
        ));
      }
    });

    return newId;
  }

  /// Closes [sessionId], setting its [ended_at] and clearing
  /// [current_task_id]. Also closes any open time log for the session owner.
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
                t.userId.equals(session.userId) &
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

  /// Atomically closes any open time log for the session owner, optionally
  /// opens a new one for [taskId], and updates [current_task_id] on the
  /// session row.
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

      if (taskId != null) {
        final membership = await (select(focusSessionTasks)
              ..where((fst) =>
                  fst.focusSessionId.equals(sessionId) &
                  fst.taskId.equals(taskId)))
            .getSingleOrNull();
        if (membership == null) {
          throw StateError('Task is not part of this focus session');
        }
      }

      // Close any open time log for this user.
      await (update(timeLogs)
            ..where(
                (t) => t.userId.equals(session.userId) & t.endedAt.isNull()))
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

  /// Stream that emits the currently open session for [userId], or null.
  Stream<FocusSession?> watchActiveSession(String userId) =>
      (select(focusSessions)
            ..where((s) => s.userId.equals(userId) & s.endedAt.isNull()))
          .watchSingleOrNull();

  /// One-shot query for the currently open session for [userId].
  Future<FocusSession?> getActiveSession(String userId) =>
      (select(focusSessions)
            ..where((s) => s.userId.equals(userId) & s.endedAt.isNull()))
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
  /// - All disposition values are persisted to [focus_session_tasks].
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

      // Persist dispositions on focus_session_tasks rows.
      for (final entry in dispositions.entries) {
        await (update(focusSessionTasks)
              ..where((fst) =>
                  fst.focusSessionId.equals(sessionId) &
                  fst.taskId.equals(entry.key)))
            .write(FocusSessionTasksCompanion(
          disposition: Value(entry.value),
        ));
      }

      // Update intent to 'maybe' for each 'maybe' disposition task.
      for (final entry in dispositions.entries) {
        if (entry.value == 'maybe') {
          await customUpdate(
            'UPDATE todos SET intent = ?, updated_at = ? '
            'WHERE id = ? AND user_id = ?',
            variables: [
              Variable('maybe'),
              Variable(ts),
              Variable(entry.key),
              Variable(session.userId),
            ],
            updates: {todos},
            updateKind: UpdateKind.update,
          );
        }
      }

      // Close any open time log for this session.
      await (update(timeLogs)
            ..where((t) =>
                t.userId.equals(session.userId) &
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
  /// recently closed session for [userId].
  ///
  /// Returns an empty list when no closed session exists or none has rollover
  /// tasks.
  Future<List<String>> getLastClosedSessionRolloverTaskIds(
      String userId) async {
    final rows = await customSelect(
      'SELECT fst.task_id FROM focus_session_tasks fst '
      'JOIN focus_sessions fs ON fs.id = fst.focus_session_id '
      'WHERE fs.user_id = ? '
      'AND fs.ended_at IS NOT NULL '
      'AND fst.disposition = ? '
      'AND fs.ended_at = ('
      '  SELECT MAX(ended_at) FROM focus_sessions '
      '  WHERE user_id = ? AND ended_at IS NOT NULL'
      ')',
      variables: [
        Variable(userId),
        Variable('rollover'),
        Variable(userId),
      ],
      readsFrom: {focusSessions, focusSessionTasks},
    ).get();
    return rows.map((r) => r.read<String>('task_id')).toList();
  }

  /// Stream of [Todo] rows in the user's currently open session.
  ///
  /// Joins through [focus_sessions] so no session-ID plumbing is needed at
  /// call sites. Returns an empty list when no session is open.
  Stream<List<Todo>> watchSessionTasksForUser(String userId) {
    return customSelect(
      'SELECT t.* FROM todos t '
      'JOIN focus_session_tasks fst ON fst.task_id = t.id '
      'JOIN focus_sessions fs ON fs.id = fst.focus_session_id '
      'WHERE fs.user_id = ? AND fs.ended_at IS NULL '
      'ORDER BY fst.position',
      variables: [Variable<String>(userId)],
      readsFrom: {focusSessionTasks, focusSessions, todos},
    ).watch().map((rows) => rows.map((r) => todos.map(r.data)).toList());
  }
}
