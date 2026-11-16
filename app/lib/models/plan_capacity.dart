import '../database/gtd_database.dart';

/// Minutes left in an open session: the available time chosen at Start Day
/// minus the whole minutes elapsed since the session started, never below zero.
///
/// The session stores no end time, so this is an estimate of the day remaining
/// (issue #700). It only ever feeds an advisory warning.
int planTimeLeftMinutes({
  required DateTime sessionStartedAt,
  required int availableMinutes,
  required DateTime now,
}) {
  final elapsedMinutes = now.difference(sessionStartedAt).inMinutes;
  final leftMinutes = availableMinutes - elapsedMinutes;
  return leftMinutes < 0 ? 0 : leftMinutes;
}

/// Total of the estimates of the Plan's unfinished Outcomes, an estimate-less
/// one counted at [defaultTimeEstimateMinutes] — the rule Daily Planning's
/// summary uses. Logged time is not subtracted; done Outcomes are excluded
/// because the comparison is against time still to come.
int unfinishedPlanEstimateMinutes(
  Iterable<Todo> planOutcomes,
  int defaultTimeEstimateMinutes,
) =>
    planOutcomes
        .where((t) => t.doneAt == null)
        .fold<int>(0, (sum, t) => sum + (t.timeEstimate ?? defaultTimeEstimateMinutes));

/// Whether adding [candidateEstimateMinutes] to a Plan already carrying
/// [unfinishedPlanMinutes] would pass [timeLeftMinutes]. Equal is within.
bool planExceedsTimeLeft({
  required int unfinishedPlanMinutes,
  required int candidateEstimateMinutes,
  required int timeLeftMinutes,
}) =>
    unfinishedPlanMinutes + candidateEstimateMinutes > timeLeftMinutes;
