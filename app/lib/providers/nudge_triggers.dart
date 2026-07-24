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

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ritual.dart';
import 'ceremony_in_progress_provider.dart';
import 'clock_provider.dart';
import 'database_provider.dart';
import 'focus_session_planning_provider.dart' show activeSessionProvider;
import 'focus_session_planning_settings_provider.dart'
    show focusSessionPlanningSettingsProvider;
import 'gtd_lists_provider.dart';
import 'nudge_clock_provider.dart';
import 'onboarding_provider.dart';
import 'periodic_review_settings_provider.dart'
    show
        emptyActionableBannerTrigger,
        periodicReviewIsDueProvider,
        periodicReviewLastCompletedProvider;
import 'shutdown_settings_provider.dart' show shutdownSettingsProvider;
import 'synced_preferences_provider.dart';

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
//
// These do the date math only; they take the current instant rather than
// sampling `DateTime.now()` themselves. The instant comes from [clockProvider]
// (overridable in tests) via [_now], and every time-based Trigger Provider also
// watches [nudgeBoundaryTickProvider] so Riverpod re-evaluates the predicate
// when a wall-clock boundary passes — see `nudge_clock_provider.dart`.

/// The current instant, read through the overridable [clockProvider] seam.
/// Also watches [nudgeBoundaryTickProvider], so any time-based Trigger that
/// reads the clock through this helper re-evaluates when a wall-clock boundary
/// passes — with no per-second polling.
DateTime _now(Ref ref) {
  ref.watch(nudgeBoundaryTickProvider);
  return ref.watch(clockProvider)();
}

DateTime _startOfToday(DateTime now) => DateTime(now.year, now.month, now.day);

/// Today's local-time instant of [hour]:[minute] relative to [now].
DateTime _todayAt(DateTime now, int hour, int minute) {
  final today = _startOfToday(now);
  return DateTime(today.year, today.month, today.day, hour, minute);
}

/// The most recent [hour]:[minute] local-time anchor at or before [now] —
/// today's if it has already passed, otherwise yesterday's.
DateTime _lastAnchorBefore(DateTime now, int hour, int minute) {
  final todayAnchor = _todayAt(now, hour, minute);
  if (!now.isBefore(todayAnchor)) return todayAnchor;
  return DateTime(now.year, now.month, now.day - 1, hour, minute);
}

// ---------------------------------------------------------------------------
// Day-attribution anchors (issue #460, ADR-0020)
// ---------------------------------------------------------------------------

/// Today's Daily Planning anchor instant, derived from the user's configured
/// planning time (default 08:00). Used only by the DPR Cadence Trigger for its
/// past-anchor gate and `firingSince` — it is *not* the day boundary for
/// session attribution (that is [lastShutdownAnchorProvider]).
final planningAnchorProvider = Provider<DateTime>((ref) {
  final now = _now(ref);
  final planningTime =
      ref.watch(focusSessionPlanningSettingsProvider).planningTime;
  return _todayAt(now, planningTime.hour, planningTime.minute);
});

/// The most recent Evening Shutdown anchor at or before now, derived from the
/// user's configured shutdown time (default 18:00 — the same source
/// [_esCadenceTrigger] reads). This is the **day boundary for session
/// attribution** (ADR-0020): a session belongs to the planning period opened
/// by the most recent ES anchor before its `started_at`.
final lastShutdownAnchorProvider = Provider<DateTime>((ref) {
  final now = _now(ref);
  final shutdownTime = ref.watch(shutdownSettingsProvider).shutdownTime;
  return _lastAnchorBefore(now, shutdownTime.hour, shutdownTime.minute);
});

/// Whether a session qualifies as belonging to the current planning period —
/// i.e. one exists whose `started_at >=` [lastShutdownAnchorProvider]. This is
/// the single source of "did today's planning happen" for the Daily Planning
/// nudge (ADR-0020). `ended_at` plays no part; an open session that started
/// before the last ES anchor does *not* qualify.
final qualifyingSessionTodayProvider = StreamProvider<bool>((ref) {
  final anchor = ref.watch(lastShutdownAnchorProvider);
  final db = ref.watch(databaseProvider);
  return db.focusSessionDao.watchQualifyingSessionExists(anchor);
});

// ---------------------------------------------------------------------------
// Cadence Trigger
// ---------------------------------------------------------------------------

/// The Cadence Trigger for [ritual]. See file-level docs for semantics.
///
/// Per-Ritual predicate sketches:
///   - DPR: now ≥ today's DPR anchor AND no qualifying session (none started
///     since the last ES anchor) AND DPR not in-progress. Fires even on a day
///     whose plan+shutdown both completed, once past the ES anchor (the ES
///     anchor starts the next planning period); with a stale open session it
///     fires alongside ES, which wins via queue ordering.
///     firingSince = later of (today's DPR anchor, last ES anchor).
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
  final now = _now(ref);

  // Past-anchor gate (ADR-0020): no nagging before today's DPR anchor.
  final dprAnchor = ref.watch(planningAnchorProvider);
  if (now.isBefore(dprAnchor)) return TriggerState.idle;

  // Day-attribution precondition: suppress while a qualifying session exists
  // (one started since the last ES anchor — open *or* already closed). Defer
  // until the stream has emitted at least once, otherwise we'd flash a DPR
  // firing state during cold start before it resolves. Note the deliberate
  // absence of a "no session open" precondition: a *stale* open session
  // (started before the last ES anchor) does not qualify, so DPR re-arms for
  // it and fires alongside ES — Evening Shutdown wins via queue ordering.
  final qualifying = ref.watch(qualifyingSessionTodayProvider);
  if (!qualifying.hasValue) return TriggerState.idle;
  if (qualifying.requireValue) return TriggerState.idle;

  // Content precondition: DPR is meaningful only when there is something
  // to plan. hasAnyItem gates the onboarding state; inbox-or-next non-empty
  // gates the "everything is done already" state.
  final hasAnyItem = ref.watch(hasAnyItemProvider);
  if (!hasAnyItem.hasValue || !hasAnyItem.requireValue) return TriggerState.idle;
  final inbox = ref.watch(unfilteredInboxProvider);
  final next = ref.watch(unfilteredNextProvider);
  if (!inbox.hasValue || !next.hasValue) return TriggerState.idle;
  if (inbox.requireValue.isEmpty && next.requireValue.isEmpty) {
    return TriggerState.idle;
  }

  // firingSince = the later of today's DPR anchor and the last ES anchor, so a
  // morning dismiss does not suppress the fresh post-ES-anchor re-arm edge.
  final lastEs = ref.watch(lastShutdownAnchorProvider);
  final since = dprAnchor.isAfter(lastEs) ? dprAnchor : lastEs;
  return TriggerState(isFiring: true, firingSince: since);
}

TriggerState _esCadenceTrigger(Ref ref) {
  final now = _now(ref);
  final session = ref.watch(activeSessionProvider);
  if (!session.hasValue) return TriggerState.idle;
  // World-state precondition: a FocusSession must be active. ES is the
  // Review phase of the active session.
  if (session.requireValue == null) return TriggerState.idle;

  final shutdownSettings = ref.watch(shutdownSettingsProvider);
  final anchor = _todayAt(now,
      shutdownSettings.shutdownTime.hour, shutdownSettings.shutdownTime.minute);
  if (now.isBefore(anchor)) return TriggerState.idle;

  return TriggerState(isFiring: true, firingSince: anchor);
}

TriggerState _wrCadenceTrigger(Ref ref) {
  final now = _now(ref);
  if (!ref.watch(periodicReviewIsDueProvider)) return TriggerState.idle;

  // Content precondition: WR has nothing to review in the onboarding state.
  final hasAnyItem = ref.watch(hasAnyItemProvider);
  if (!hasAnyItem.hasValue || !hasAnyItem.requireValue) return TriggerState.idle;

  final lastCompleted = ref.watch(periodicReviewLastCompletedProvider);
  // firingSince: when the cadence-due edge would have fired. For a
  // never-completed Ritual we report start-of-today (the predicate has
  // been true since whenever the app booted today; start-of-today is a
  // stable, surface-friendly stamp).
  final since = lastCompleted == null
      ? _startOfToday(now)
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

/// The Weekly Review **content-state** predicate as a standalone, watchable
/// tri-state: `true` when there are todos AND the inbox + Next List are both
/// empty while Waiting For or Someday/Maybe still hold items; `false` when
/// loaded but not firing; `null` while any of the underlying lists are still
/// loading. Extracted from [_wrContentStateTrigger] so [contentFiringEdgeProvider]
/// can observe genuine `false→true` transitions (and not mistake a
/// loading→firing edge on startup for a re-fire).
final wrContentFiringProvider = Provider<bool?>((ref) {
  final hasAnyItem = ref.watch(hasAnyItemProvider);
  final inbox = ref.watch(unfilteredInboxProvider);
  final next = ref.watch(unfilteredNextProvider);
  final waiting = ref.watch(unfilteredWaitingForProvider);
  final maybe = ref.watch(unfilteredMaybeProvider);
  if (!hasAnyItem.hasValue ||
      !inbox.hasValue ||
      !next.hasValue ||
      !waiting.hasValue ||
      !maybe.hasValue) {
    return null; // still loading — truth value unknown
  }
  if (!hasAnyItem.requireValue) return false;
  return emptyActionableBannerTrigger(
    inbox: inbox,
    next: next,
    waiting: waiting,
    maybe: maybe,
  );
});

String _contentFiringEdgeKey(RitualId ritual) =>
    '${ritual.keyPrefix}_nudge_content_firing_edge';

/// The persisted `false→true` firing edge of [ritual]'s content-state Trigger,
/// reported as that Trigger's `firingSince`.
///
/// A content-state dismiss releases when the most-recent firing edge advances
/// past `dismissed_at` (see `nudge_provider.dart`). Stamping this edge on each
/// genuine re-fire — rather than the old per-day `_startOfToday` approximation —
/// releases the dismiss the moment the predicate re-fires, not at the day
/// boundary. The edge is persisted to synced-prefs so it survives an app
/// restart; on a restart where the predicate is already firing but nothing was
/// persisted, it falls back to start-of-today (the prior behaviour), so a
/// same-day dismiss is not spuriously released. Idle/loading ⇒ `null`.
class ContentFiringEdgeNotifier extends Notifier<DateTime?> {
  // Weekly Review is the only Ritual with a content-state Trigger today.
  static const _ritual = RitualId.weeklyReview;

  bool? _prevFiring;

  /// This session's freshly stamped edge. Held in memory because
  /// `syncedPrefs(ref).set(...)` is async: until that write is reflected in
  /// `syncedPreferencesProvider`, a rebuild while still firing would otherwise
  /// read `persisted == null` and regress `firingSince` to start-of-today,
  /// transiently re-hiding a just-released dismiss.
  DateTime? _stampedEdge;

  @override
  DateTime? build() {
    final firing = ref.watch(wrContentFiringProvider);
    final prefs = ref.watch(syncedPreferencesProvider).asData?.value;
    final persisted = DateTime.tryParse(
      prefs?.get<String>(_contentFiringEdgeKey(_ritual)) ?? '',
    );

    final prev = _prevFiring;
    _prevFiring = firing;

    if (firing != true) return null; // loading or not firing ⇒ no edge

    if (prev == false) {
      // A genuine false→true re-fire (not a startup loading→firing edge, which
      // would have prev == null): stamp a fresh edge, cache it, and persist it.
      final edge = ref.read(clockProvider)();
      _stampedEdge = edge;
      unawaited(syncedPrefs(ref).set(
        _contentFiringEdgeKey(_ritual),
        edge.toUtc().toIso8601String(),
      ));
      return edge;
    }
    // Already firing (startup, or a rebuild while still firing). Prefer the
    // freshest edge: this session's in-memory stamp bridges the window before
    // the async persist lands; the persisted value covers a cold restart and a
    // newer cross-device edge. Fall back to start-of-today when neither exists.
    return _latest(_stampedEdge, persisted) ??
        _startOfToday(ref.read(clockProvider)());
  }
}

/// The later of two nullable instants (a `null` argument counts as absent).
DateTime? _latest(DateTime? a, DateTime? b) =>
    a == null || b == null ? (a ?? b) : (a.isAfter(b) ? a : b);

final contentFiringEdgeProvider =
    NotifierProvider<ContentFiringEdgeNotifier, DateTime?>(
  ContentFiringEdgeNotifier.new,
);

TriggerState _wrContentStateTrigger(Ref ref) {
  if (ref.watch(wrContentFiringProvider) != true) return TriggerState.idle;
  final edge = ref.watch(contentFiringEdgeProvider);
  // While firing the tracker has stamped an edge; fall back defensively to
  // start-of-today (kept boundary-reactive via _now) if it has not yet.
  return TriggerState(
    isFiring: true,
    firingSince: edge ?? _startOfToday(_now(ref)),
  );
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
