/// Whether the Break after a run of Sprints is a long one (issue #911).
///
/// The rule is wall time, not a count of Sprints. The user sets how many
/// Sprints come before a long Break, and that number becomes a time budget —
/// sprints × (sprint length + short Break length), 92 minutes at the
/// defaults. The Break after a Sprint is long when it would end at or after
/// the budget, measured from the moment the count last restarted.
///
/// The count restarts at a gap with no Sprint at least as long as a long
/// Break. A long Break taken to its end is such a gap, so it restarts the
/// count; one cut short is not, so the next Break is offered long again.
///
/// The count runs across Actions and across devices: it reads the recorded
/// Sprints and nothing else, so every device holding the same record reaches
/// the same answer.
library;

import '../database/daos/sprint_dao.dart';

/// Whether the Break after the Sprint [sprintId] is a long one.
///
/// [sprints] must be the recorded Sprints ordered by start, as
/// [sprintRecordsWithEffectiveEnds] returns them. The Sprint whose Break is
/// decided is found by id, so the answer is about that Sprint even when a
/// later Sprint on another Action exists.
///
/// [sprintDurationMinutes], [shortBreakDurationMinutes] and
/// [sprintsBeforeLongBreak] make the budget;
/// [longBreakDurationMinutes] is the gap that restarts the count. A Sprint
/// that has not ended has no Break after it yet, and reads as short.
bool isLongBreakAfterSprint({
  required List<SprintRecord> sprints,
  required String sprintId,
  required int sprintDurationMinutes,
  required int shortBreakDurationMinutes,
  required int longBreakDurationMinutes,
  required int sprintsBeforeLongBreak,
}) {
  final index = sprints.indexWhere((sprint) => sprint.id == sprintId);
  if (index < 0) return false;
  final sprint = sprints[index];
  final endedAtUtc = sprint.endedAtUtc;
  if (endedAtUtc == null) return false;

  // The run starts at its first Sprint: a gap with no Sprint at least as long
  // as a long Break restarts the count, and everything before that gap is a
  // run of its own.
  var runStartedAtUtc = sprint.startedAtUtc;
  for (var i = index - 1; i >= 0; i--) {
    final previous = sprints[i];
    final previousEndedAtUtc = previous.endedAtUtc;
    if (previousEndedAtUtc == null) break;
    final gap = sprints[i + 1].startedAtUtc.difference(previousEndedAtUtc);
    if (gap >= Duration(minutes: longBreakDurationMinutes)) break;
    runStartedAtUtc = previous.startedAtUtc;
  }

  final budget = Duration(
    minutes: sprintsBeforeLongBreak *
        (sprintDurationMinutes + shortBreakDurationMinutes),
  );
  // The Break runs from the Sprint's end to the end of the short Break, so it
  // ends this far into the run.
  final breakEndsAt = endedAtUtc.difference(runStartedAtUtc) +
      Duration(minutes: shortBreakDurationMinutes);
  return breakEndsAt >= budget;
}
