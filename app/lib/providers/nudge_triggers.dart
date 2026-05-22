/// Triggers fire a Ritual's Nudge to "visible" when their predicate
/// transitions false→true. See `CONTEXT.md`'s **Trigger** entry for the
/// conceptual definition and `docs/adr/0008-cadence-as-anchor-with-period.md`
/// for the Cadence-as-anchor-with-period decision.
///
/// Two concrete shapes:
///
/// - **Cadence Trigger** — fires once per anchor-to-anchor period. The
///   predicate combines "current time has crossed into a new period",
///   "the Ritual has not been completed in this period", and any
///   world-state preconditions (e.g. FocusSession-lifecycle gates for
///   Daily Planning / Evening Shutdown). World-state preconditions stay
///   inside the Trigger, not as separate Ritual-level rules.
///
/// - **Content-state Trigger** — domain predicate over the user's data.
///   Today the only Ritual with one is Weekly Review (Next list empty
///   AND Waiting / Someday-Maybe still hold items). Refires on each
///   false→true edge of the predicate.
///
/// Each Trigger exposes `(isFiring, firingSince)` — `firingSince` is the
/// timestamp the current firing began, used by the Nudge's
/// dismiss-vs-firing comparison: a dismiss "sticks" until the next
/// false→true edge.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ritual.dart';
import 'ceremony_in_progress_provider.dart';
import 'focus_session_planning_provider.dart' show activeSessionProvider;
import 'gtd_lists_provider.dart';
import 'onboarding_provider.dart';
import 'periodic_review_settings_provider.dart'
    show
        emptyActionableBannerTrigger,
        periodicReviewIsDueProvider,
        periodicReviewLastCompletedProvider;
import 'shutdown_settings_provider.dart' show shutdownSettingsProvider;

// ---------------------------------------------------------------------------
// TriggerState
// ---------------------------------------------------------------------------

/// Current snapshot of a Trigger's predicate.
///
/// - [isFiring] is the current truth value of the predicate.
/// - [firingSince] is the timestamp the current firing began. Null when not
///   firing. Used by the Nudge's dismiss-vs-firing comparison.
class TriggerState {
  const TriggerState({this.isFiring = false, this.firingSince});

  final bool isFiring;
  final DateTime? firingSince;

  static const idle = TriggerState();

  @override
  bool operator ==(Object other) =>
      other is TriggerState &&
      other.isFiring == isFiring &&
      other.firingSince == firingSince;

  @override
  int get hashCode => Object.hash(isFiring, firingSince);
}

// ---------------------------------------------------------------------------
// Date helpers
// ---------------------------------------------------------------------------

DateTime _startOfToday() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

/// Today's local-time instant of [hour]:[minute] (or the most recent past
/// occurrence if [hour]:[minute] is still in the future today).
DateTime _todayAt(int hour, int minute) {
  final today = _startOfToday();
  return DateTime(today.year, today.month, today.day, hour, minute);
}

// ---------------------------------------------------------------------------
// Cadence Trigger
// ---------------------------------------------------------------------------

/// The Cadence Trigger for [ritual]. See file-level docs for semantics.
///
/// Per-Ritual predicate sketches:
///   - DPR: no FS active AND no FS opened today AND DPR not in-progress.
///     firingSince = start of today.
///   - ES:  FS active AND now ≥ shutdown anchor AND ES not in-progress.
///     firingSince = today's shutdown anchor.
///   - WR:  (no prior completion OR now ≥ last completion + 7d) AND
///     WR not in-progress.
///     firingSince = last completion + 7d (or app start if never completed).
final cadenceTriggerProvider =
    Provider.family<TriggerState, RitualId>((ref, ritual) {
  if (ref.watch(ceremonyInProgressForProvider(ritual))) return TriggerState.idle;

  return switch (ritual) {
    RitualId.dailyPlanning => _dprCadenceTrigger(ref),
    RitualId.eveningShutdown => _esCadenceTrigger(ref),
    RitualId.weeklyReview => _wrCadenceTrigger(ref),
  };
});

TriggerState _dprCadenceTrigger(Ref ref) {
  // Defer until the active-session stream has emitted at least once;
  // otherwise we'd flash a DPR firing state during cold start before the
  // stream resolves to "yes, today's session exists."
  final session = ref.watch(activeSessionProvider);
  if (!session.hasValue) return TriggerState.idle;
  // World-state precondition: no FocusSession currently active. Opening
  // a new one is incoherent if one is already running.
  if (session.requireValue != null) return TriggerState.idle;
  return TriggerState(isFiring: true, firingSince: _startOfToday());
}

TriggerState _esCadenceTrigger(Ref ref) {
  final session = ref.watch(activeSessionProvider);
  if (!session.hasValue) return TriggerState.idle;
  // World-state precondition: a FocusSession must be active. ES is the
  // Review phase of the active session.
  if (session.requireValue == null) return TriggerState.idle;

  final shutdownSettings = ref.watch(shutdownSettingsProvider);
  final anchor = _todayAt(
      shutdownSettings.shutdownTime.hour, shutdownSettings.shutdownTime.minute);
  if (DateTime.now().isBefore(anchor)) return TriggerState.idle;

  return TriggerState(isFiring: true, firingSince: anchor);
}

TriggerState _wrCadenceTrigger(Ref ref) {
  if (!ref.watch(periodicReviewIsDueProvider)) return TriggerState.idle;

  final lastCompleted = ref.watch(periodicReviewLastCompletedProvider);
  // firingSince: when the cadence-due edge would have fired. For a
  // never-completed Ritual we report start-of-today (the predicate has
  // been true since whenever the app booted today; start-of-today is a
  // stable, surface-friendly stamp).
  final since = lastCompleted == null
      ? _startOfToday()
      : lastCompleted.add(const Duration(days: 7));
  return TriggerState(isFiring: true, firingSince: since);
}

// ---------------------------------------------------------------------------
// Content-state Trigger
// ---------------------------------------------------------------------------

/// The Content-state Trigger for [ritual]. Only Weekly Review has one today
/// (Next list empty AND Waiting / Someday-Maybe still hold items); the others
/// return [TriggerState.idle].
///
/// `firingSince` is reported as `_startOfToday()` while firing. Wall-time
/// would be more precise but the Provider re-evaluates on every list-stream
/// rebuild — using wall-time would silently make every rebuild a fresh
/// "edge," defeating dismiss persistence. A stable per-day stamp matches
/// today's date-scoped dismiss semantics for the content-state predicate;
/// the more granular false→true edge tracking (per `CONTEXT.md`'s **Nudge**
/// entry and ambiguity #3) is the planned follow-on.
final contentStateTriggerProvider =
    Provider.family<TriggerState, RitualId>((ref, ritual) {
  if (ref.watch(ceremonyInProgressForProvider(ritual))) return TriggerState.idle;

  switch (ritual) {
    case RitualId.weeklyReview:
      return _wrContentStateTrigger(ref);
    case RitualId.dailyPlanning:
    case RitualId.eveningShutdown:
      return TriggerState.idle;
  }
});

TriggerState _wrContentStateTrigger(Ref ref) {
  final hasTodos = ref.watch(hasTodosProvider);
  if (!hasTodos.hasValue || !hasTodos.requireValue) return TriggerState.idle;

  final firing = emptyActionableBannerTrigger(
    inbox: ref.watch(unfilteredInboxProvider),
    next: ref.watch(unfilteredNextActionsProvider),
    waiting: ref.watch(unfilteredWaitingForProvider),
    maybe: ref.watch(unfilteredMaybeProvider),
  );
  if (!firing) return TriggerState.idle;
  return TriggerState(isFiring: true, firingSince: _startOfToday());
}

// ---------------------------------------------------------------------------
// Aggregate helpers
// ---------------------------------------------------------------------------

/// All Triggers configured for [ritual]. The list is the simple union of the
/// concrete Triggers; iteration order is irrelevant for the Nudge predicate.
final triggersForRitualProvider =
    Provider.family<List<TriggerState>, RitualId>((ref, ritual) {
  return [
    ref.watch(cadenceTriggerProvider(ritual)),
    ref.watch(contentStateTriggerProvider(ritual)),
  ];
});

/// The most recent `firingSince` across [ritual]'s currently-firing Triggers,
/// or null if none are firing. The Nudge's dismiss-vs-firing predicate
/// compares the user's `dismissed_at` against this value: a dismiss is
/// effective until any Trigger's `firingSince` advances past it.
final mostRecentFiringEdgeProvider =
    Provider.family<DateTime?, RitualId>((ref, ritual) {
  final firing = ref
      .watch(triggersForRitualProvider(ritual))
      .where((t) => t.isFiring && t.firingSince != null)
      .map((t) => t.firingSince!)
      .toList();
  if (firing.isEmpty) return null;
  return firing.reduce((a, b) => a.isAfter(b) ? a : b);
});
