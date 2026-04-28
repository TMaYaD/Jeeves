/// DAO for [TimeLogs]: open/close focus stints and query per-task totals.
library;

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../gtd_database.dart';

part 'time_log_dao.g.dart';

@DriftAccessor(tables: [TimeLogs, Todos])
class TimeLogDao extends DatabaseAccessor<GtdDatabase>
    with _$TimeLogDaoMixin {
  TimeLogDao(super.db);

  /// Opens a new focus log for [taskId] / [userId].
  ///
  /// If another log is already open for [userId] it is defensively closed first
  /// to handle offline edge-cases with stale open rows.
  ///
  /// [focusSessionId] links this log to the active [FocusSession] row; callers
  /// that manage sessions directly (e.g. [FocusSessionDao.setCurrentTask]) pass
  /// it; legacy callers omit it and the field is left null.
  ///
  /// [now] is injectable for deterministic testing; defaults to [DateTime.now].
  Future<void> openLog({
    required String taskId,
    required String userId,
    String? focusSessionId,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    await transaction(() async {
      // Close any pre-existing open log for this user.
      await (update(timeLogs)
            ..where((t) => t.userId.equals(userId) & t.endedAt.isNull()))
          .write(TimeLogsCompanion(endedAt: Value(ts.toIso8601String())));
      // Insert the new open log.
      await into(timeLogs).insert(TimeLogsCompanion(
        id: Value(uuid.v4()),
        userId: Value(userId),
        taskId: Value(taskId),
        startedAt: Value(ts.toIso8601String()),
        endedAt: const Value(null),
        focusSessionId: Value(focusSessionId),
      ));
    });
  }

  /// Closes the open log for [taskId], if any.
  ///
  /// [now] is injectable for deterministic testing; defaults to [DateTime.now].
  Future<void> closeLog({required String taskId, DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    await (update(timeLogs)
          ..where((t) => t.taskId.equals(taskId) & t.endedAt.isNull()))
        .write(TimeLogsCompanion(endedAt: Value(ts.toIso8601String())));
  }

  /// Stream that emits the currently-open log for [userId], or null.
  Stream<TimeLog?> watchActiveLog(String userId) {
    return (select(timeLogs)
          ..where((t) => t.userId.equals(userId) & t.endedAt.isNull()))
        .watchSingleOrNull();
  }

  /// Ceiling-rounded sum of minutes spent on [taskId] across all log rows.
  ///
  /// Open rows (ended_at IS NULL) are included using the current UTC time.
  /// Per-interval ceiling arithmetic uses the `+ 0.9999` trick since SQLite
  /// has no CEIL() function.
  Future<int> totalMinutesForTask(String taskId) async {
    final result = await customSelect(
      'SELECT COALESCE(SUM('
      '  CAST('
      '    ((julianday(COALESCE(ended_at, datetime(\'now\'))) - julianday(started_at))'
      '     * 86400 / 60 + 0.9999)'
      '  AS INTEGER)'
      '), 0) AS total_minutes '
      'FROM time_logs '
      'WHERE task_id = ?',
      variables: [Variable<String>(taskId)],
      readsFrom: {timeLogs},
    ).getSingle();
    return result.read<int>('total_minutes');
  }
}
