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
            ..where((s) => s.id.equals(sessionId)))
          .getSingleOrNull();
      if (session == null) return;

      // Close any open time log for this user.
      await (update(timeLogs)
            ..where(
                (t) => t.userId.equals(session.userId) & t.endedAt.isNull()))
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
            ..where((s) => s.id.equals(sessionId)))
          .getSingleOrNull();
      if (session == null) return;

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
