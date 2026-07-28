/// DAO for [TimeLogs]: open/close focus stints and query per-task totals.
library;

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../sync/collection_codecs.dart';
import '../gtd_database.dart';
import 'action_dao.dart';

part 'time_log_dao.g.dart';

@DriftAccessor(tables: [TimeLogs, Todos, Actions])
class TimeLogDao extends DatabaseAccessor<GtdDatabase>
    with _$TimeLogDaoMixin {
  TimeLogDao(super.db);

  /// Opens a new focus log for [taskId] / [userId].
  ///
  /// Any currently-open log is defensively closed first to enforce the global
  /// single-open-log invariant (handles offline edge-cases with stale rows).
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
    await attachedDatabase.capturing(() => transaction(() async {
      // Resolve the Outcome's current Action *inside* the transaction so a
      // concurrent supersede between resolve and insert cannot mis-attribute,
      // and so attributing to a planned/terminated row is impossible by
      // construction — the resolver filters `role = 'current'` (issue #476).
      final actionId = await ActionDao.currentActionIdFor(this, taskId);
      // Close any pre-existing open log.
      final stillOpen =
          await (select(timeLogs)..where((t) => t.endedAt.isNull())).get();
      await (update(timeLogs)..where((t) => t.endedAt.isNull()))
          .write(TimeLogsCompanion(endedAt: Value(ts.toIso8601String())));
      for (final row in stillOpen) {
        captureLogClosed(row.id, ts);
      }
      // Insert the new open log.
      final id = uuid.v4();
      await into(timeLogs).insert(TimeLogsCompanion(
        id: Value(id),
        userId: Value(userId),
        taskId: Value(taskId),
        actionId: Value(actionId),
        startedAt: Value(ts.toIso8601String()),
        endedAt: const Value(null),
        focusSessionId: Value(focusSessionId),
      ));
      captureLogOpened(
        attachedDatabase,
        id: id,
        userId: userId,
        taskId: taskId,
        actionId: actionId,
        startedAtIso: ts.toIso8601String(),
        focusSessionId: focusSessionId,
      );
    }));
  }

  /// A stint's full field set — the create assertion every peer builds the row
  /// from. `started_at` / `ended_at` are TEXT columns, so their stored strings
  /// travel opaque (see `collection_codecs.dart`).
  static void captureLogOpened(
    GtdDatabase db, {
    required String id,
    required String userId,
    required String taskId,
    required String? actionId,
    required String startedAtIso,
    required String? focusSessionId,
  }) {
    db.opCapture.write(
      collection: timeLogsCollection,
      entityId: id,
      fields: {
        'user_id': userId,
        'task_id': taskId,
        'action_id': actionId,
        'started_at': startedAtIso,
        'ended_at': null,
        'focus_session_id': focusSessionId,
      },
    );
  }

  void captureLogClosed(String id, DateTime ts) => captureLogClosedOn(
        attachedDatabase,
        id,
        ts,
      );

  static void captureLogClosedOn(GtdDatabase db, String id, DateTime ts) {
    db.opCapture.write(
      collection: timeLogsCollection,
      entityId: id,
      fields: {'ended_at': ts.toIso8601String()},
    );
  }

  /// Closes the open log for [taskId], if any.
  ///
  /// [now] is injectable for deterministic testing; defaults to [DateTime.now].
  Future<void> closeLog({required String taskId, DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    await attachedDatabase.capturing(() => transaction(() async {
      final open = await (select(timeLogs)
            ..where((t) => t.taskId.equals(taskId) & t.endedAt.isNull()))
          .get();
      await (update(timeLogs)
            ..where((t) => t.taskId.equals(taskId) & t.endedAt.isNull()))
          .write(TimeLogsCompanion(endedAt: Value(ts.toIso8601String())));
      for (final row in open) {
        captureLogClosed(row.id, ts);
      }
    }));
  }

  /// Stream that emits the currently-open log, or null.
  Stream<TimeLog?> watchActiveLog() {
    return (select(timeLogs)..where((t) => t.endedAt.isNull()))
        .watchSingleOrNull();
  }

  /// Correlated SQL subquery: ceiling-rounded total minutes across all
  /// `time_logs` rows whose `task_id` equals [taskIdRef] (a SQL expression,
  /// e.g. `'t.id'` or a bound `'?'`).
  ///
  /// Open rows (ended_at IS NULL) are included using the current UTC time.
  /// Per-interval ceiling arithmetic uses the `+ 0.9999` trick since SQLite
  /// has no CEIL() function. The inner alias `dtl` is chosen to avoid
  /// colliding with outer-query table aliases.
  ///
  /// This is the single derivation of time-spent from TimeLogs (the source of
  /// truth); queries that surface time-spent embed it rather than reading the
  /// dead `todos.time_spent_minutes` column (issue #480).
  static String totalMinutesSubquery(String taskIdRef) => '(SELECT COALESCE(SUM('
      '  CAST('
      '    ((julianday(COALESCE(dtl.ended_at, datetime(\'now\'))) - julianday(dtl.started_at))'
      '     * 86400 / 60 + 0.9999)'
      '  AS INTEGER)'
      '), 0) FROM time_logs dtl WHERE dtl.task_id = $taskIdRef)';

  /// Correlated SQL subquery: ceiling-rounded total minutes across all
  /// `time_logs` rows whose `action_id` equals [actionIdRef] (a SQL expression,
  /// e.g. `'actions.id'` or a bound `'?'`) — the Action-grain counterpart of
  /// [totalMinutesSubquery], with identical arithmetic.
  ///
  /// Embedded by `ActionDao.watchTerminatedActions` so an Outcome's history
  /// renders what each Action cost in one joined query rather than one lookup
  /// per row (issue #478). Legacy rows with a NULL `action_id` are counted at
  /// the Outcome grain by [totalMinutesSubquery] and belong to no Action, so
  /// they are absent here — the two derivations do not have to agree row-wise.
  ///
  /// The open-row (`ended_at IS NULL`) branch is defensive: every terminal
  /// Action transition closes that Action's open log first (issue #476), so a
  /// terminated Action should have none. The inner alias `dtla` avoids
  /// colliding with [totalMinutesSubquery]'s `dtl` when both appear in one
  /// query.
  static String totalMinutesSubqueryForAction(String actionIdRef) =>
      '(SELECT COALESCE(SUM('
      '  CAST('
      '    ((julianday(COALESCE(dtla.ended_at, datetime(\'now\'))) - julianday(dtla.started_at))'
      '     * 86400 / 60 + 0.9999)'
      '  AS INTEGER)'
      '), 0) FROM time_logs dtla WHERE dtla.action_id = $actionIdRef)';

  /// Ceiling-rounded sum of minutes spent on [taskId] across all log rows.
  ///
  /// See [totalMinutesSubquery] for the derivation semantics.
  Future<int> totalMinutesForTask(String taskId) async {
    final result = await customSelect(
      'SELECT ${totalMinutesSubquery('?')} AS total_minutes',
      variables: [Variable<String>(taskId)],
      readsFrom: {timeLogs},
    ).getSingle();
    return result.read<int>('total_minutes');
  }
}
