/// The Sprint timer of a Focus on a Habit (issue #405).
///
/// A pure function of the recorded Habit Sprints, the open Habit log, the
/// Focus settings and `now` — the same rules as `deriveSprintTimerState` for an
/// Outcome, over the Habit's own tables. It neither calls nor changes the
/// Outcome function: the two clocks never share a record.
library;

import '../database/daos/sprint_dao.dart' show SprintRecord;
import '../database/gtd_database.dart';
import 'long_break.dart';
import '../providers/sprint_timer_provider.dart'
    show SprintPhase, SprintTimerState;

/// The ms-truncated UTC instant of [value], the grain a recorded instant has.
DateTime _floorToMillisecond(DateTime value) =>
    DateTime.fromMillisecondsSinceEpoch(value.millisecondsSinceEpoch,
        isUtc: true);

/// "About N sprints": the Habit's estimate over the Sprint length, at least 1.
int _sprintsInEstimate(int? estimateMinutes, int sprintMinutes) {
  if (estimateMinutes == null || estimateMinutes <= sprintMinutes) return 1;
  return (estimateMinutes / sprintMinutes).ceil();
}

/// The timer state of a Focus on a Habit at [now].
///
/// * No open log: idle.
/// * The latest Sprint of the log is running: focus, or focus overtime once
///   `started_at + planned length` has passed.
/// * The latest Sprint ended: break, or break overtime once
///   `ended_at + break length` has passed. The Break is the long one when
///   `longBreakDecision` says so over the log's own Sprints, as for an Outcome.
/// * An open log with no Sprint yet: idle, naming Sprint 1.
///
/// [sprints] are the Sprints of [openLog], oldest first. `activeTaskId` and
/// `activeTaskTitle` of the returned state carry the Habit's id and
/// [habitTitle], so the one Sprint ring draws it unchanged.
SprintTimerState deriveHabitSprintTimerState({
  required HabitTimeLog? openLog,
  required List<HabitSprint> sprints,
  required int sprintMinutesSetting,
  required int breakMinutesSetting,
  required int longBreakMinutesSetting,
  required int sprintsBeforeLongBreakSetting,
  required int? estimateMinutes,
  required DateTime now,
  String? habitTitle,
}) {
  if (openLog == null) {
    return SprintTimerState(
      sprintDurationMinutes: sprintMinutesSetting,
      currentBreakDurationMinutes: breakMinutesSetting,
      lastBreakDurationMinutes: breakMinutesSetting,
    );
  }

  final logStartedAtUtc =
      _floorToMillisecond(DateTime.parse(openLog.startedAt).toUtc());
  final inLog = [
    for (final s in sprints)
      if (!DateTime.parse(s.startedAt).toUtc().isBefore(logStartedAtUtc)) s,
  ];
  final latest = inLog.isEmpty ? null : inLog.last;
  final nowUtc = now.toUtc();
  final sprintMinutes = latest?.plannedDurationMinutes ?? sprintMinutesSetting;
  final recorded = inLog.length;
  final lastBreakEndedAt = inLog.length >= 2
      ? DateTime.parse(latest!.startedAt).toUtc().toLocal()
      : null;

  // Which Break follows the latest Sprint: the long one when the run of the
  // log's Sprints has spent its budget (issue #911), the short one otherwise.
  // A running Sprint has no Break after it yet and reads short.
  final longBreak = latest == null || latest.endedAt == null
      ? null
      : longBreakDecision(
          sprints: [
            for (final s in inLog)
              SprintRecord(
                id: s.id,
                userId: s.userId,
                actionId: s.habitId,
                startedAtUtc: DateTime.parse(s.startedAt).toUtc(),
                endedAtUtc: s.endedAt == null
                    ? null
                    : DateTime.parse(s.endedAt!).toUtc(),
                storedEndedAtUtc: s.endedAt == null
                    ? null
                    : DateTime.parse(s.endedAt!).toUtc(),
                plannedDurationMinutes: s.plannedDurationMinutes,
              ),
          ],
          sprintId: latest.id,
          sprintDurationMinutes: sprintMinutesSetting,
          shortBreakDurationMinutes: breakMinutesSetting,
          longBreakDurationMinutes: longBreakMinutesSetting,
          sprintsBeforeLongBreak: sprintsBeforeLongBreakSetting,
        );
  final isLongBreak = longBreak?.isLong ?? false;
  final breakMinutes = isLongBreak ? longBreakMinutesSetting : breakMinutesSetting;

  SprintTimerState build({
    required SprintPhase phase,
    required int sprintNumber,
    Duration remaining = Duration.zero,
    Duration total = Duration.zero,
    Duration overtime = Duration.zero,
  }) {
    final hint = _sprintsInEstimate(estimateMinutes, sprintMinutes);
    return SprintTimerState(
      phase: phase,
      activeTaskId: openLog.habitId,
      activeTaskTitle: habitTitle,
      sprintNumber: sprintNumber,
      totalSprints: hint > sprintNumber ? hint : sprintNumber,
      remaining: remaining,
      total: total,
      overtime: overtime,
      sprintDurationMinutes: sprintMinutes,
      currentBreakDurationMinutes: breakMinutes,
      isLongBreak: isLongBreak,
      longBreakSprintCount: isLongBreak ? longBreak!.sprintCount : 0,
      lastBreakDurationMinutes: breakMinutesSetting,
      lastBreakEndedAt: lastBreakEndedAt,
    );
  }

  if (latest != null && latest.endedAt == null) {
    final total = Duration(minutes: latest.plannedDurationMinutes);
    var elapsed = nowUtc.difference(DateTime.parse(latest.startedAt).toUtc());
    if (elapsed.isNegative) elapsed = Duration.zero;
    if (elapsed < total) {
      return build(
        phase: SprintPhase.focus,
        sprintNumber: recorded,
        remaining: total - elapsed,
        total: total,
      );
    }
    final overtime = elapsed - total;
    return build(
      phase: SprintPhase.focusOvertime,
      sprintNumber: recorded,
      total: total,
      overtime: overtime > total ? total : overtime,
    );
  }

  if (latest != null && latest.endedAt != null) {
    final endedAtUtc = DateTime.parse(latest.endedAt!).toUtc();
    final total = Duration(minutes: breakMinutes);
    final breakEndsAtUtc = endedAtUtc.add(total);
    if (nowUtc.isBefore(breakEndsAtUtc)) {
      return build(
        phase: SprintPhase.break_,
        sprintNumber: recorded,
        remaining: breakEndsAtUtc.difference(nowUtc),
        total: total,
      );
    }
    final overtime = nowUtc.difference(breakEndsAtUtc);
    return build(
      phase: SprintPhase.breakOvertime,
      sprintNumber: recorded,
      total: total,
      overtime: overtime > total ? total : overtime,
    );
  }

  return build(phase: SprintPhase.idle, sprintNumber: recorded + 1);
}
