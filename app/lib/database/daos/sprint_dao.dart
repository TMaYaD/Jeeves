/// DAO for [Sprints]: the recorded Sprint (issue #910).
///
/// A Sprint is a timebox spent on an Action. It is recorded with the Action, a
/// start, an end (null while it runs) and the length that was set when it
/// started, and it replicates between devices like a TimeLog. A Break is the gap
/// between Sprints and is not recorded.
///
/// **The earliest end stands.** Two devices that closed one Sprint at different
/// instants converge on the earlier end (`min_timestamp_value`, see
/// `sync/merge_strategy.dart`). A Sprint two devices both left open, with a later
/// Sprint after it, **reads** as ending 1 ms before that later Sprint starts —
/// derived by [sprintRecordsWithEffectiveEnds] from merged state, never written,
/// so no device authors a convergence write.
library;

import 'package:drift/drift.dart';

import '../../sync/collection_codecs.dart';
import '../../utils/uuid.dart';
import '../gtd_database.dart';
import 'action_dao.dart';

part 'sprint_dao.g.dart';

/// One Sprint as the app reads it: typed instants and the **effective** end.
class SprintRecord {
  const SprintRecord({
    required this.id,
    required this.userId,
    required this.actionId,
    required this.startedAtUtc,
    required this.endedAtUtc,
    required this.storedEndedAtUtc,
    required this.plannedDurationMinutes,
  });

  final String id;
  final String userId;
  final String? actionId;
  final DateTime startedAtUtc;

  /// The stored end, or — for an open Sprint that has a later Sprint — one
  /// millisecond before that later Sprint started. Null only for the running
  /// Sprint (the user's latest, with no stored end).
  final DateTime? endedAtUtc;

  /// What the row stores; null while open, whatever [endedAtUtc] derives.
  final DateTime? storedEndedAtUtc;
  final int plannedDurationMinutes;

  bool get isRunning => endedAtUtc == null;
}

/// Parses a stored instant; null when it does not read as one.
DateTime? _parseStoredInstant(String? value) =>
    value == null ? null : DateTime.tryParse(value)?.toUtc();

/// The Sprints of [rows] with their effective ends, ordered by start then id.
///
/// A pure function of the rows, so every device holding the same merged rows
/// computes the same ends. Per user, an open Sprint that is not the user's latest
/// reads as ending 1 ms before the next Sprint starts; a stored end always wins
/// over the derivation. Rows whose start does not parse are skipped.
List<SprintRecord> sprintRecordsWithEffectiveEnds(Iterable<Sprint> rows) {
  final parsed = <({Sprint row, DateTime startedAtUtc})>[];
  for (final row in rows) {
    final startedAtUtc = _parseStoredInstant(row.startedAt);
    if (startedAtUtc != null) {
      parsed.add((row: row, startedAtUtc: startedAtUtc));
    }
  }
  int byStartThenId(
    ({Sprint row, DateTime startedAtUtc}) a,
    ({Sprint row, DateTime startedAtUtc}) b,
  ) {
    final byStart = a.startedAtUtc.compareTo(b.startedAtUtc);
    return byStart != 0 ? byStart : a.row.id.compareTo(b.row.id);
  }

  parsed.sort(byStartThenId);

  final laterStartByIndex = <int, DateTime>{};
  final latestIndexByUser = <String, int>{};
  for (var index = parsed.length - 1; index >= 0; index--) {
    final userId = parsed[index].row.userId;
    final later = latestIndexByUser[userId];
    if (later != null) laterStartByIndex[index] = parsed[later].startedAtUtc;
    // Walking backwards, the first sighting of a user is their latest Sprint;
    // thereafter the *next* Sprint is the one seen most recently.
    latestIndexByUser[userId] = index;
  }

  return [
    for (var index = 0; index < parsed.length; index++)
      () {
        final row = parsed[index].row;
        final stored = _parseStoredInstant(row.endedAt);
        final nextStart = laterStartByIndex[index];
        return SprintRecord(
          id: row.id,
          userId: row.userId,
          actionId: row.actionId,
          startedAtUtc: parsed[index].startedAtUtc,
          endedAtUtc: stored ??
              (nextStart?.subtract(const Duration(milliseconds: 1))),
          storedEndedAtUtc: stored,
          plannedDurationMinutes: row.plannedDurationMinutes,
        );
      }(),
  ];
}

@DriftAccessor(tables: [Sprints, Actions])
class SprintDao extends DatabaseAccessor<GtdDatabase> with _$SprintDaoMixin {
  SprintDao(super.db);

  /// Starts a recorded Sprint on [taskId]'s current Action.
  ///
  /// In one `capturing` transaction: resolves the Outcome's current Action (as
  /// the TimeLog does), ends the user's running Sprint if there is one, inserts
  /// the row and captures it whole. Returns the new Sprint's id.
  ///
  /// [now] is injectable for deterministic testing.
  Future<String> startSprint({
    required String taskId,
    required String userId,
    required int plannedDurationMinutes,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final startedAtIso = encodeInstant(ts)!;
    final id = uuid.v4();
    var wroteAction = false;
    await attachedDatabase.capturing(() async {
      final resolved =
          await ActionDao.ensureCurrentActionIdFor(attachedDatabase, taskId, ts);
      wroteAction = resolved.wroteAction;
      await closeRunningSprintOn(attachedDatabase, ts, userId: userId);
      await into(sprints).insert(SprintsCompanion(
        id: Value(id),
        userId: Value(userId),
        actionId: Value(resolved.actionId),
        startedAt: Value(startedAtIso),
        endedAt: const Value(null),
        plannedDurationMinutes: Value(plannedDurationMinutes),
      ));
      attachedDatabase.opCapture.write(
        collection: sprintsCollection,
        entityId: id,
        fields: {
          'user_id': userId,
          'action_id': resolved.actionId,
          'started_at': startedAtIso,
          'ended_at': null,
          'planned_duration_minutes': plannedDurationMinutes,
        },
      );
    });
    if (wroteAction) {
      attachedDatabase.notifyActionsViewWrite();
      attachedDatabase.notifyTodosViewWrite();
    }
    return id;
  }

  /// Ends the user's running Sprint at [now], if there is one. A second call
  /// writes and captures nothing: the first end stands locally.
  Future<void> endRunningSprint({required String userId, DateTime? now}) {
    final ts = (now ?? DateTime.now()).toUtc();
    return attachedDatabase
        .capturing(() => closeRunningSprintOn(attachedDatabase, ts, userId: userId));
  }

  /// Ends the running Sprint — the user's latest, when it has no stored end — at
  /// [ts], inside the caller's capturing transaction.
  ///
  /// The single spelling every writer shares: the Sprint DAO's own end, and the
  /// five places that close a TimeLog (a Sprint never outlives its TimeLog).
  /// Earlier Sprints left open on other devices are not touched: they already
  /// read as ending before the later Sprint, and a stored end later than that
  /// would only be overridden by the earlier end anyway.
  static Future<void> closeRunningSprintOn(
    GtdDatabase db,
    DateTime ts, {
    required String userId,
  }) async {
    final latest = await (db.select(db.sprints)
          ..where((s) => s.userId.equals(userId))
          ..orderBy([
            (s) => OrderingTerm.desc(s.startedAt),
            (s) => OrderingTerm.desc(s.id),
          ])
          ..limit(1))
        .getSingleOrNull();
    if (latest == null || latest.endedAt != null) return;
    await _endSprintById(db, ts, latest.id);
  }

  static Future<void> _endSprintById(
      GtdDatabase db, DateTime ts, String sprintId) async {
    final endedAtIso = encodeInstant(ts.toUtc())!;
    await (db.update(db.sprints)
          ..where((s) => s.id.equals(sprintId) & s.endedAt.isNull()))
        .write(SprintsCompanion(endedAt: Value(endedAtIso)));
    db.opCapture.write(
      collection: sprintsCollection,
      entityId: sprintId,
      fields: {'ended_at': endedAtIso},
    );
  }

  /// Ends, at [ts], the running Sprint of each TimeLog in [closedLogs] — the
  /// rows the caller has just closed — inside the caller's capturing
  /// transaction.
  ///
  /// A Sprint belongs to a TimeLog when it is the user's *earliest* open Sprint
  /// on the log's Action that started at or after the log did and before the
  /// start of any later, still-open TimeLog of the same user on that Action.
  /// Two offline devices that each opened a TimeLog and a Sprint on one Action
  /// therefore map one-to-one, and closing the older TimeLog leaves the newer
  /// one's Sprint running.
  static Future<void> closeRunningSprintsOfLogs(
    GtdDatabase db,
    DateTime ts,
    Iterable<TimeLog> closedLogs,
  ) async {
    DateTime? ms(String iso) {
      final parsed = DateTime.tryParse(iso)?.toUtc();
      // Sprint instants are millisecond-truncated; a TimeLog's may not be.
      return parsed == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(parsed.millisecondsSinceEpoch,
              isUtc: true);
    }

    for (final log in closedLogs) {
      final logStart = ms(log.startedAt);
      final actionMatches = log.actionId == null
          ? db.timeLogs.actionId.isNull()
          : db.timeLogs.actionId.equals(log.actionId!);
      final laterOpenLogs = await (db.select(db.timeLogs)
            ..where((t) =>
                t.userId.equals(log.userId) &
                t.endedAt.isNull() &
                t.id.isNotValue(log.id) &
                actionMatches))
          .get();
      DateTime? upperBound;
      for (final other in laterOpenLogs) {
        final otherStart = ms(other.startedAt);
        if (otherStart == null || logStart == null) continue;
        if (!otherStart.isAfter(logStart)) continue;
        if (upperBound == null || otherStart.isBefore(upperBound)) {
          upperBound = otherStart;
        }
      }
      final candidates = await (db.select(db.sprints)
            ..where((s) =>
                s.userId.equals(log.userId) &
                s.endedAt.isNull() &
                (log.actionId == null
                    ? s.actionId.isNull()
                    : s.actionId.equals(log.actionId!)))
            ..orderBy([
              (s) => OrderingTerm.asc(s.startedAt),
              (s) => OrderingTerm.asc(s.id),
            ]))
          .get();
      for (final sprint in candidates) {
        final start = DateTime.tryParse(sprint.startedAt)?.toUtc();
        if (logStart != null && start != null && start.isBefore(logStart)) {
          continue;
        }
        if (upperBound != null && start != null && !start.isBefore(upperBound)) {
          continue;
        }
        await _endSprintById(db, ts, sprint.id);
        break;
      }
    }
  }

  /// Every recorded Sprint with its effective end, ordered by start.
  Future<List<SprintRecord>> getAllRecords() async =>
      sprintRecordsWithEffectiveEnds(await select(sprints).get());
}
