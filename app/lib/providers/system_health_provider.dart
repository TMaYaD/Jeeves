/// System-health signals and the guardrail level derived from them (issue #52,
/// Story A). No UI: later stories read these to render the Level 1 / Level 2
/// surfaces and the health indicator.
///
/// Level 1 is "the Weekly Review is overdue". Level 2 is "the Weekly Review is
/// more than [kGuardrailReviewOverdueGraceHours] overdue, or the Inbox holds
/// more than [kGuardrailInboxCaptureLimit] unprocessed Captures". Only a
/// completed Weekly Review counts, never a partially done review period.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sync/collection_codecs.dart' show decodeInstant;
import 'clock_provider.dart';
import 'database_provider.dart';
import 'gtd_lists_provider.dart' show unfilteredInboxProvider;
import 'nudge_clock_provider.dart' show nudgeBoundaryTickProvider;
import 'periodic_review_settings_provider.dart'
    show periodicReviewLastCompletedProvider;

/// How long past its due instant the Weekly Review may run before Level 2.
const int kGuardrailReviewOverdueGraceHours = 48;

/// The Inbox holds more than this many unprocessed Captures at Level 2.
const int kGuardrailInboxCaptureLimit = 50;

const int _kWeeklyReviewCadenceDays = 7;

enum GuardrailLevel { none, level1, level2 }

/// Why a guardrail is active. Every restriction surface must say why.
enum GuardrailCause { reviewOverdue, inboxOverLimit }

/// The instant the Weekly Review falls due: last completion + 7 days.
DateTime weeklyReviewDueInstant(DateTime lastCompleted) =>
    lastCompleted.add(const Duration(days: _kWeeklyReviewCadenceDays));

/// The instant Level 2 starts for the review arm: due + the grace period.
DateTime weeklyReviewLevel2Instant(DateTime lastCompleted) =>
    weeklyReviewDueInstant(lastCompleted)
        .add(const Duration(hours: kGuardrailReviewOverdueGraceHours));

/// Baseline for a user who has never completed a Weekly Review: the review is
/// treated as having been "completed" at this instant. Currently the earliest
/// Outcome or Capture `created_at`; the single place to change if that
/// decision changes. Null when the user has no items at all.
final neverReviewedBaselineProvider = StreamProvider<DateTime?>((ref) {
  final db = ref.watch(databaseProvider);
  // created_at is stored as ISO-8601 TEXT (UTC), so MIN() is chronological.
  return db.customSelect(
    'SELECT MIN(created_at) AS earliest FROM ('
    'SELECT created_at FROM captures UNION ALL SELECT created_at FROM todos)',
    readsFrom: {db.captures, db.todos},
  ).watch().map((rows) => decodeInstant(rows.first.data['earliest']));
});

/// Count of Captures with `clarified_at IS NULL`. Zero until the stream loads.
final unprocessedCaptureCountProvider = Provider<int>((ref) {
  return ref.watch(unfilteredInboxProvider).asData?.value.length ?? 0;
});

/// The instant the Weekly Review is (or was) due, or null if there is no
/// completion and no never-reviewed baseline yet.
final weeklyReviewDueAtProvider = Provider<DateTime?>((ref) {
  final last = ref.watch(periodicReviewLastCompletedProvider) ??
      ref.watch(neverReviewedBaselineProvider).asData?.value;
  return last == null ? null : weeklyReviewDueInstant(last);
});

/// How long past due the Weekly Review is; [Duration.zero] when not overdue.
final weeklyReviewOverdueDurationProvider = Provider<Duration>((ref) {
  final due = ref.watch(weeklyReviewDueAtProvider);
  if (due == null) return Duration.zero;
  // Re-evaluate when a Nudge boundary (including due and due + grace) passes.
  ref.watch(nudgeBoundaryTickProvider);
  final overdue = ref.watch(clockProvider)().difference(due);
  return overdue.isNegative ? Duration.zero : overdue;
});

/// The active guardrail causes, empty when the system is healthy.
final guardrailCausesProvider = Provider<Set<GuardrailCause>>((ref) {
  final overdue = ref.watch(weeklyReviewOverdueDurationProvider);
  final inboxCount = ref.watch(unprocessedCaptureCountProvider);
  return {
    if (overdue > Duration.zero) GuardrailCause.reviewOverdue,
    if (inboxCount > kGuardrailInboxCaptureLimit) GuardrailCause.inboxOverLimit,
  };
});

final guardrailLevelProvider = Provider<GuardrailLevel>((ref) {
  final overdue = ref.watch(weeklyReviewOverdueDurationProvider);
  final causes = ref.watch(guardrailCausesProvider);
  if (causes.contains(GuardrailCause.inboxOverLimit) ||
      overdue > const Duration(hours: kGuardrailReviewOverdueGraceHours)) {
    return GuardrailLevel.level2;
  }
  if (causes.contains(GuardrailCause.reviewOverdue)) {
    return GuardrailLevel.level1;
  }
  return GuardrailLevel.none;
});
