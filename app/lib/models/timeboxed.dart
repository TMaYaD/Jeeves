/// Timeboxed — an Action whose estimate is a limit rather than a guess
/// (CONTEXT.md § Timeboxed, issue #923).
///
/// The switch itself is one nullable boolean on the Action row
/// (`actions.timeboxed`); everything else about a limit is *derived* from
/// synced data — the Action's TimeLogs say when the limit passed, and the
/// recorded Sprints say which of them started past it. Nothing else is
/// stored, so every device holding the same rows reads the same limit, and
/// raising the estimate moves it with no second write.
library;

/// Whether an Action is Timeboxed: the switch is on **and** it has an
/// estimate.
///
/// One rule, read everywhere. Two devices can merge "the estimate was cleared"
/// with "the switch was turned on"; this reads that as off rather than as a
/// limit of nothing.
bool isTimeboxedAction({
  required bool? timeboxed,
  required int? timeEstimate,
}) =>
    (timeboxed ?? false) && timeEstimate != null;

/// What a Timeboxed Action's limit looks like right now.
///
/// Every field is derived at read time: the limit is the Action's estimate,
/// the instant it passed comes from the Action's TimeLogs, and the counts come
/// from the Sprints recorded against the Action.
class TimeboxedLimitStatus {
  const TimeboxedLimitStatus({
    required this.limitMinutes,
    required this.limitPassedAt,
    required this.sprintsBeforeLimit,
    required this.sprintsPastLimit,
    required this.sprintStarts,
  });

  /// The estimate, in minutes: the limit.
  final int limitMinutes;

  /// The instant the limit passed; null while it has not.
  final DateTime? limitPassedAt;

  /// The Sprints that started **before** the limit. The dots from this index
  /// on are the ones past it.
  final int sprintsBeforeLimit;

  /// The Sprints that started at or after the limit.
  final int sprintsPastLimit;

  /// The recorded Sprints' start instants, oldest first.
  final List<DateTime> sprintStarts;

  /// Whether the limit has been reached.
  bool get hasPassed => limitPassedAt != null;

  /// The minutes past the limit at [now]; zero while the limit has not passed.
  int minutesPast(DateTime now) {
    final passed = limitPassedAt;
    if (passed == null) return 0;
    final minutes = now.toUtc().difference(passed).inMinutes;
    return minutes < 0 ? 0 : minutes;
  }

  /// The number of the running Sprint when it started past the limit; null
  /// when the running Sprint is not one of them.
  ///
  /// A Sprint is past the limit when it started at or after the instant the
  /// limit passed.
  int? get runningSprintPastLimitNumber {
    final passed = limitPassedAt;
    if (passed == null) return null;
    if (sprintStarts.isEmpty) return null;
    if (sprintStarts.last.isBefore(passed)) return null;
    return sprintsPastLimit;
  }
}
