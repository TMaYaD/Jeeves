/// The "about N sprints" hint a row carries beside a time estimate.
///
/// The count is a hint, never a target: it says roughly how many Sprints the
/// work may take, and changes nothing about the work itself.
library;

/// The hint for [timeEstimateMinutes] of work at [sprintDurationMinutes] per
/// Sprint — or null when there is nothing to divide.
///
/// The count is the estimate divided by the Sprint length, rounded up and
/// floored at one Sprint, so an estimate shorter than a Sprint still reads as
/// a Sprint. No estimate means no hint. A non-positive Sprint length has no
/// answer to give and reads as no hint rather than dividing by zero.
String? sprintHintLabel({
  required int? timeEstimateMinutes,
  required int sprintDurationMinutes,
}) {
  if (timeEstimateMinutes == null) return null;
  if (sprintDurationMinutes <= 0) return null;
  final sprints = (timeEstimateMinutes / sprintDurationMinutes).ceil();
  if (sprints <= 1) return 'about 1 sprint';
  return 'about $sprints sprints';
}
