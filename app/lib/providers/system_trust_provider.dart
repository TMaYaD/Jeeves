/// System Trust signals (issue #52, Story A). No UI: later stories read these
/// to render the Weekly Review and Inbox nudges and the Settings section.
///
/// A signal is a fact about the system and whether it needs attention. The
/// signals never block anything; they are nudges.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sync/collection_codecs.dart' show decodeInstant;
import 'clock_provider.dart';
import 'database_provider.dart';
import 'gtd_lists_provider.dart' show unfilteredInboxProvider;
import 'nudge_clock_provider.dart' show nudgeBoundaryTickProvider;
import 'periodic_review_settings_provider.dart'
    show
        periodicReviewLastCompletedProvider,
        periodicReviewLastSessionFinishedProvider;

/// The Inbox is too full when it holds more than this many Captures.
const int kInboxTooFullCaptureLimit = 50;

const int _kWeeklyReviewCadenceDays = 7;

/// Baseline for a user who has never finished a Weekly Review: the review is
/// treated as last done at this instant. Currently the earliest Outcome or
/// Capture `created_at`; the single place to change if that decision changes.
/// Null when the user has no items at all.
final neverReviewedBaselineProvider = StreamProvider<DateTime?>((ref) {
  final db = ref.watch(databaseProvider);
  // created_at is stored as ISO-8601 TEXT (UTC), so MIN() is chronological.
  return db.customSelect(
    'SELECT MIN(created_at) AS earliest FROM ('
    'SELECT created_at FROM captures UNION ALL SELECT created_at FROM todos)',
    readsFrom: {db.captures, db.todos},
  ).watch().map((rows) => decodeInstant(rows.first.data['earliest']));
});

/// The later of the completion stamp and the session-finished stamp, or null
/// if neither exists (a never-reviewed user).
final weeklyReviewLastReviewedAtProvider = Provider<DateTime?>((ref) {
  final completed = ref.watch(periodicReviewLastCompletedProvider);
  final sessionFinished = ref.watch(periodicReviewLastSessionFinishedProvider);
  if (completed == null) return sessionFinished;
  if (sessionFinished == null) return completed;
  return sessionFinished.isAfter(completed) ? sessionFinished : completed;
});

/// The instant the Weekly Review falls due: seven days after the last review,
/// or after the never-reviewed baseline. Null when there is neither.
final weeklyReviewDueAtProvider = Provider<DateTime?>((ref) {
  final from = ref.watch(weeklyReviewLastReviewedAtProvider) ??
      ref.watch(neverReviewedBaselineProvider).asData?.value;
  return from?.add(const Duration(days: _kWeeklyReviewCadenceDays));
});

/// Local calendar days from the due day to today: 0 on the due day, null
/// before it (or when nothing is due).
final weeklyReviewDaysLateProvider = Provider<int?>((ref) {
  final due = ref.watch(weeklyReviewDueAtProvider);
  if (due == null) return null;
  // Re-evaluate at the due instant and at every local midnight.
  ref.watch(nudgeBoundaryTickProvider);
  final now = ref.watch(clockProvider)();
  if (now.isBefore(due)) return null;
  // Dates built as UTC so a DST change cannot shift the whole-day difference.
  final dueLocal = due.toLocal();
  final nowLocal = now.toLocal();
  return DateTime.utc(nowLocal.year, nowLocal.month, nowLocal.day)
      .difference(DateTime.utc(dueLocal.year, dueLocal.month, dueLocal.day))
      .inDays;
});

/// Count of Captures with `clarified_at IS NULL`. Zero until the stream loads.
final unprocessedCaptureCountProvider = Provider<int>((ref) {
  return ref.watch(unfilteredInboxProvider).asData?.value.length ?? 0;
});

/// True while the Inbox holds more than [kInboxTooFullCaptureLimit] Captures.
final inboxTooFullProvider = Provider<bool>(
  (ref) => ref.watch(unprocessedCaptureCountProvider) > kInboxTooFullCaptureLimit,
);

enum TrustSignalKind { inbox, weeklyReview }

/// One System Trust signal: its fact and whether it needs attention.
class TrustSignal {
  const TrustSignal({
    required this.kind,
    required this.needsAttention,
    this.captureCount,
    this.daysLate,
    this.lastReviewedAt,
  });

  final TrustSignalKind kind;
  final bool needsAttention;

  /// Inbox signal: the number of unprocessed Captures.
  final int? captureCount;

  /// Weekly Review signal: days late, null before the due day.
  final int? daysLate;

  /// Weekly Review signal: the last review, null if never reviewed.
  final DateTime? lastReviewedAt;
}

class SystemTrust {
  const SystemTrust(this.signals);

  final List<TrustSignal> signals;

  bool get needsAttention => signals.any((s) => s.needsAttention);
  bool get allGood => !needsAttention;
}

final systemTrustProvider = Provider<SystemTrust>((ref) {
  return SystemTrust([
    TrustSignal(
      kind: TrustSignalKind.inbox,
      needsAttention: ref.watch(inboxTooFullProvider),
      captureCount: ref.watch(unprocessedCaptureCountProvider),
    ),
    TrustSignal(
      kind: TrustSignalKind.weeklyReview,
      needsAttention: ref.watch(weeklyReviewDaysLateProvider) != null,
      daysLate: ref.watch(weeklyReviewDaysLateProvider),
      lastReviewedAt: ref.watch(weeklyReviewLastReviewedAtProvider),
    ),
  ]);
});
