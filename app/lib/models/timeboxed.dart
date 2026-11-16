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
}) => (timeboxed ?? false) && timeEstimate != null;

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

  /// Whether the limit has passed by [now].
  ///
  /// [limitPassedAt] can be in the future: an open stint runs on, so the limit
  /// is reached inside it — at an instant that has not arrived yet. Such a
  /// limit has not been passed, and nothing should say it has.
  bool hasPassedAt(DateTime now) {
    final passed = limitPassedAt;
    if (passed == null) return false;
    return !now.toUtc().isBefore(passed);
  }

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

/// Jeeves' advice before a Sprint that would start past a Timeboxed limit
/// (issue #923).
///
/// The shape is the app's Jeeves treatment: a bold headline over a quieter
/// line (docs/DESIGN.md § Voice).
class TimeboxedAdvice {
  const TimeboxedAdvice({required this.headline, required this.detail});

  /// The bold line — 16px, w700, ink.
  final String headline;

  /// The quieter line under it — 13px, w500, muted.
  final String detail;
}

/// The advice for the Sprint that would be the [nth] past the limit.
///
/// One-based: 1 is the first Sprint started past the limit. The tone grows
/// firmer with each further one, as the story asks — the first states the
/// fact, the second says the limit was the user's own, the third and beyond
/// say plainly that the day is moving on.
TimeboxedAdvice timeboxedAdviceFor(int nth) {
  if (nth <= 1) {
    return const TimeboxedAdvice(
      headline: 'The limit has run its course, sir.',
      detail: 'Another sprint would be the first beyond it.',
    );
  }
  if (nth == 2) {
    return const TimeboxedAdvice(
      headline: 'That would be the second past the limit, sir.',
      detail: 'The limit was your own; I merely keep it in view.',
    );
  }
  return TimeboxedAdvice(
    headline: 'That would be the ${englishOrdinalWord(nth)} past the limit, sir.',
    detail:
        'I do not wish to nag. The rest of the day, however, is beginning '
        'to notice.',
  );
}

/// The English ordinal in words: first, second, third, fourth, fifth.
///
/// The advice names the count in words — "the third past the limit" — where
/// [englishOrdinal] spells the number out for a label or a list. A count past
/// the words spelled here falls back to the numeric form.
String englishOrdinalWord(int n) {
  const words = [
    'first',
    'second',
    'third',
    'fourth',
    'fifth',
    'sixth',
    'seventh',
    'eighth',
    'ninth',
    'tenth',
    'eleventh',
    'twelfth',
  ];
  if (n < 1 || n > words.length) return englishOrdinal(n);
  return words[n - 1];
}

/// The English ordinal for [n]: 1st, 2nd, 3rd, 4th, 11th, 21st.
String englishOrdinal(int n) {
  if (n <= 0) return '$n';
  final suffix = switch (n % 100) {
    11 || 12 || 13 => 'th',
    _ => switch (n % 10) {
      1 => 'st',
      2 => 'nd',
      3 => 'rd',
      _ => 'th',
    },
  };
  return '$n$suffix';
}
