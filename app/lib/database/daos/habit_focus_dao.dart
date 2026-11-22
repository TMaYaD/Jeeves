/// DAO for time spent on a Habit in Focus Mode (issue #405).
///
/// A Habit can be run in Focus Mode with Sprints and breaks. The time is
/// recorded against the **Habit**, never against an Outcome: [HabitTimeLogs]
/// holds one row per Focus (breaks included) and [HabitSprints] one row per
/// Sprint, a break being the gap between two. Neither table is synced (the
/// same as the Habit tables), so no write here authors an op; each write still
/// runs inside `GtdDatabase.capturing`, the one transaction boundary.
///
/// **One thing at a time.** The DAO keeps at most one open Focus per user:
/// [openHabitFocus] closes a previous one first. An open Outcome engagement is
/// ended by the caller (`HabitFocusNotifier`), because that is Engagement
/// code and this DAO knows nothing of it.
library;

import 'package:drift/drift.dart';

import '../../models/habit_commitment.dart' show habitDayKey;
import '../../sync/collection_codecs.dart' show encodeInstant;
import '../../utils/uuid.dart';
import '../gtd_database.dart';
import 'habit_dao.dart' show HabitState;

part 'habit_focus_dao.g.dart';

/// The open Focus on a Habit and the Sprints run in it, oldest first.
class HabitFocusRecords {
  const HabitFocusRecords({required this.openLog, required this.sprints});

  /// The Focus that is running, or null when none is.
  final HabitTimeLog? openLog;

  /// The Sprints of [openLog], oldest first. Empty when there is no open Focus.
  final List<HabitSprint> sprints;
}

@DriftAccessor(tables: [HabitTimeLogs, HabitSprints, Habits])
class HabitFocusDao extends DatabaseAccessor<GtdDatabase>
    with _$HabitFocusDaoMixin {
  HabitFocusDao(super.db);

  /// Opens a Focus on [habitId]: closes the user's open Focus on any Habit,
  /// opens a log and starts Sprint 1 of [plannedSprintMinutes].
  ///
  /// Throws an [ArgumentError] for a Habit that is not there or belongs to
  /// another user, and a [StateError] for a Habit with no time estimate or one
  /// that is not active today (paused or archived). Returns the log's id.
  ///
  /// [now] is injectable for deterministic testing.
  Future<String> openHabitFocus({
    required String habitId,
    required String userId,
    required int plannedSprintMinutes,
    DateTime? now,
  }) async {
    final instant = _instant(now);
    final stamp = encodeInstant(instant)!;
    final logId = uuid.v4();
    await attachedDatabase.capturing(() async {
      final habit = await (select(habits)..where((h) => h.id.equals(habitId)))
          .getSingleOrNull();
      if (habit == null || habit.userId != userId) {
        throw ArgumentError.value(
            habitId, 'habitId', 'There is no such Habit for this user.');
      }
      if (habit.timeEstimateMinutes == null) {
        throw StateError('A Habit with no time estimate has no Focus Mode.');
      }
      final state = await attachedDatabase.habitDao
          .stateOn(habitId, habitDayKey(now ?? DateTime.now()));
      if (state != HabitState.active) {
        throw StateError('A Habit that is not active today has no Focus Mode.');
      }
      // One thing at a time: an Outcome engagement still open in the store
      // (the in-memory state is empty after a restart) ends in the same
      // transaction, before the Habit log opens. A Habit rejected above
      // leaves it running.
      final openOutcomeLogs = await (attachedDatabase.select(
              attachedDatabase.timeLogs)
            ..where((t) => t.userId.equals(userId) & t.endedAt.isNull()))
          .get();
      for (final taskId in {for (final log in openOutcomeLogs) log.taskId}) {
        await attachedDatabase.timeLogDao.closeLog(taskId: taskId, now: instant);
      }
      await _closeOpenFocus(userId, stamp);
      await into(habitTimeLogs).insert(HabitTimeLogsCompanion.insert(
        id: Value(logId),
        userId: userId,
        habitId: habitId,
        startedAt: stamp,
      ));
      await _insertSprint(habitId, userId, stamp, plannedSprintMinutes);
    });
    return logId;
  }

  /// Starts the next Sprint of the open Focus: ends the running Sprint if there
  /// is one, then starts a new one on the same Habit. Throws a [StateError]
  /// when no Focus is open. Returns the new Sprint's id.
  Future<String> startHabitSprint({
    required String userId,
    required int plannedSprintMinutes,
    DateTime? now,
  }) async {
    final stamp = encodeInstant(_instant(now))!;
    late String sprintId;
    await attachedDatabase.capturing(() async {
      final log = await _openLogOf(userId);
      if (log == null) {
        throw StateError('There is no open Focus on a Habit to start a Sprint in.');
      }
      await _endRunningSprint(userId, stamp);
      sprintId =
          await _insertSprint(log.habitId, userId, stamp, plannedSprintMinutes);
    });
    return sprintId;
  }

  /// Ends the user's running Sprint, if any. The Focus stays open: the gap
  /// that follows is a break. A second call writes nothing.
  Future<void> endRunningHabitSprint({
    required String userId,
    DateTime? now,
  }) {
    final stamp = encodeInstant(_instant(now))!;
    return attachedDatabase
        .capturing(() => _endRunningSprint(userId, stamp));
  }

  /// Ends the running Sprint and the open log. Does nothing when no Focus is
  /// open, so Stop, an Outcome start and a restart can all call it.
  Future<void> closeHabitFocus({required String userId, DateTime? now}) {
    final stamp = encodeInstant(_instant(now))!;
    return attachedDatabase.capturing(() => _closeOpenFocus(userId, stamp));
  }

  /// The user's open Focus on a Habit, or null.
  Future<HabitTimeLog?> openHabitTimeLog(String userId) => _openLogOf(userId);

  /// The open Focus on [habitId] and its Sprints, live.
  ///
  /// The Sprints are those the Habit ran since the log started.
  Stream<HabitFocusRecords> watchHabitFocusRecords(String habitId) {
    // A Sprint starting or ending does not touch the log row, so the watch
    // reads both tables and re-queries on a change to either.
    return customSelect(
      'SELECT 1',
      readsFrom: {habitTimeLogs, habitSprints},
    ).watch().asyncMap((_) async {
      final rows = await (select(habitTimeLogs)
            ..where((l) => l.habitId.equals(habitId) & l.endedAt.isNull())
            ..orderBy([(l) => OrderingTerm.desc(l.startedAt)])
            ..limit(1))
          .get();
      if (rows.isEmpty) {
        return const HabitFocusRecords(openLog: null, sprints: []);
      }
      final log = rows.single;
      final sprints = await sprintsOfLog(log);
      return HabitFocusRecords(openLog: log, sprints: sprints);
    });
  }

  /// The Sprints [habitId] ran since [log] started, oldest first.
  Future<List<HabitSprint>> sprintsOfLog(HabitTimeLog log) =>
      (select(habitSprints)
            ..where((s) =>
                s.habitId.equals(log.habitId) &
                s.startedAt.isBiggerOrEqualValue(log.startedAt))
            ..orderBy([
              (s) => OrderingTerm.asc(s.startedAt),
              (s) => OrderingTerm.asc(s.id),
            ]))
          .get();

  // --- inside a capturing transaction ---------------------------------------

  Future<HabitTimeLog?> _openLogOf(String userId) => (select(habitTimeLogs)
        ..where((l) => l.userId.equals(userId) & l.endedAt.isNull())
        ..orderBy([(l) => OrderingTerm.desc(l.startedAt)])
        ..limit(1))
      .getSingleOrNull();

  Future<void> _endRunningSprint(String userId, String stamp) =>
      (update(habitSprints)
            ..where((s) => s.userId.equals(userId) & s.endedAt.isNull()))
          .write(HabitSprintsCompanion(endedAt: Value(stamp)));

  Future<void> _closeOpenFocus(String userId, String stamp) async {
    await _endRunningSprint(userId, stamp);
    await (update(habitTimeLogs)
          ..where((l) => l.userId.equals(userId) & l.endedAt.isNull()))
        .write(HabitTimeLogsCompanion(endedAt: Value(stamp)));
  }

  Future<String> _insertSprint(
    String habitId,
    String userId,
    String stamp,
    int plannedSprintMinutes,
  ) async {
    final id = uuid.v4();
    await into(habitSprints).insert(HabitSprintsCompanion.insert(
      id: Value(id),
      userId: userId,
      habitId: habitId,
      startedAt: stamp,
      plannedDurationMinutes: plannedSprintMinutes,
    ));
    return id;
  }

  static DateTime _instant(DateTime? now) {
    final utc = (now ?? DateTime.now()).toUtc();
    return DateTime.fromMillisecondsSinceEpoch(utc.millisecondsSinceEpoch,
        isUtc: true);
  }
}
