/// The estimate ladder: the values an estimate can take.
///
/// One ladder, so an estimate means the same number of minutes wherever it
/// was set. The shared options are what every estimate surface offers; the
/// stepper walks the same options and then 30-minute steps, because an
/// estimate that means "most of the morning" has to be sayable.
library;

/// The time-estimate options, in minutes, every effort picker offers.
///
/// One list so the clarify card, the standalone clarify screen, the n-m New
/// Outcome form and the Plan section's action sheet cannot drift apart — a
/// user who learns the ladder on one surface meets the same one everywhere.
const List<int> kEstimateOptionsMinutes = [5, 10, 15, 30, 45, 60, 90, 120];

/// The largest estimate the ladder offers: ten hours.
const int kMaxEstimateMinutes = 600;

/// The whole ladder: the shared options, then 30-minute steps to the top.
///
/// The steps continue the ladder's own grain — 120 to 150 is half an hour,
/// like 15 to 30 and 30 to 45 — so a value read off the stepper always
/// belongs to the same family as the ones below it.
List<int> get estimateLadderMinutes => [
  ...kEstimateOptionsMinutes,
  for (
    var m = kEstimateOptionsMinutes.last + 30;
    m <= kMaxEstimateMinutes;
    m += 30
  )
    m,
];

/// The value one step below [minutes] on the ladder; null for "no estimate".
///
/// Stepping below the shortest option clears the estimate rather than
/// inventing a shorter one: there is no such thing as a two-minute Action.
/// From a value that is not on the ladder, the step is to the nearest ladder
/// value below it — 25 minutes steps down to 15, not to 30.
int? stepEstimateDown(int? minutes) {
  if (minutes == null) return null;
  int? below;
  for (final value in estimateLadderMinutes) {
    if (value < minutes) below = value;
  }
  return below;
}

/// The value one step above [minutes] on the ladder; null at the top.
///
/// From a value that is not on the ladder, the step is to the nearest ladder
/// value above it — 25 minutes steps up to 30.
int? stepEstimateUp(int? minutes) {
  final ladder = estimateLadderMinutes;
  if (minutes == null) return ladder.first;
  for (final value in ladder) {
    if (value > minutes) return value;
  }
  return null;
}
