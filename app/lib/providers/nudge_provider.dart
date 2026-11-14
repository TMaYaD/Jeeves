/// The Nudge module — per-Ritual persistent state (dismiss / snooze) plus
/// the computed visibility predicate and the cross-Ritual Nudge queue.
/// See `CONTEXT.md`'s **Nudge** and **Nudge queue** entries for the
/// conceptual definitions and `docs/adr/0009-in-progress-hygiene-at-nudge-level.md`
/// for the centralised in-progress hygiene rule.
///
/// **Visibility predicate** (recomputed reactively):
///
/// ```
/// visible =
///     (some Trigger of this Ritual is currently firing)
///   ∧ (no Ceremony performance of this Ritual is currently in progress)
///   ∧ (snoozed_until is null OR now > snoozed_until)
///   ∧ (dismissed_at is null OR dismissed_at < latest Trigger firing edge)
/// ```
///
/// **Persistence**: `dismissed_at` and `snoozed_until` are stored in
/// synced-preferences under per-Ritual keys (`<keyPrefix>_nudge_dismissed_at`
/// / `<keyPrefix>_nudge_snoozed_until`). Cross-device field-grain LWW over the
/// op log — a dismiss on one device suppresses the Nudge on every other device
/// until the next Trigger firing edge.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/nudge_predicates.dart';
import '../models/ritual.dart';
import 'ceremony_in_progress_provider.dart';
import 'clock_provider.dart';
import 'nudge_triggers.dart';
import 'synced_preferences_provider.dart';

export '../models/nudge_predicates.dart' show NudgeState;

// ---------------------------------------------------------------------------
// Key helpers
// ---------------------------------------------------------------------------

String _dismissedAtKey(RitualId ritual) => '${ritual.keyPrefix}_nudge_dismissed_at';
String _snoozedUntilKey(RitualId ritual) => '${ritual.keyPrefix}_nudge_snoozed_until';

// ---------------------------------------------------------------------------
// NudgeState provider (persisted, per-Ritual)
// ---------------------------------------------------------------------------

/// Reads [ritual]'s persisted Nudge state from synced preferences. Returns
/// an empty state (`dismissedAt = snoozedUntil = null`) until the synced-prefs
/// snapshot loads.
final nudgeStateProvider =
    Provider.family<NudgeState, RitualId>((ref, ritual) {
  final prefs = ref.watch(syncedPreferencesProvider).asData?.value;
  if (prefs == null) return const NudgeState();
  return NudgeState(
    dismissedAt: DateTime.tryParse(
      prefs.get<String>(_dismissedAtKey(ritual)) ?? '',
    ),
    snoozedUntil: DateTime.tryParse(
      prefs.get<String>(_snoozedUntilKey(ritual)) ?? '',
    ),
  );
});

// ---------------------------------------------------------------------------
// Visibility predicate
// ---------------------------------------------------------------------------

/// True once synced prefs have completed their initial load. Until this is
/// true the [NudgeState] returned by [nudgeStateProvider] is the empty
/// default, which would mask a real dismiss/snooze and flash the banner on
/// before the persisted state arrives. Surface predicates gate on it.
final nudgePrefsReadyProvider = Provider<bool>((ref) {
  return ref.watch(syncedPreferencesProvider).asData?.value != null;
});

/// True iff [ritual]'s Nudge is currently visible. See file-level docs for
/// the predicate.
final nudgeVisibleProvider =
    Provider.family<bool, RitualId>((ref, ritual) {
  // Defer until synced prefs have loaded — see [nudgePrefsReadyProvider].
  if (!ref.watch(nudgePrefsReadyProvider)) return false;

  // In-progress hygiene. Hidden regardless of Trigger state.
  if (ref.watch(ceremonyInProgressForProvider(ritual))) return false;

  final firingEdge = ref.watch(mostRecentFiringEdgeProvider(ritual));
  if (firingEdge == null) return false;

  final s = ref.watch(nudgeStateProvider(ritual));
  final now = ref.watch(clockProvider)();

  // Snooze blocks visibility until expiry. Re-evaluate at the expiry instant:
  // nothing else changes when a snooze runs out, so without this the Nudge
  // would stay hidden until some unrelated rebuild.
  final snoozedUntil = s.snoozedUntil;
  if (snoozedUntil != null && now.isBefore(snoozedUntil)) {
    final timer = Timer(snoozedUntil.difference(now), ref.invalidateSelf);
    ref.onDispose(timer.cancel);
  }

  return nudgeVisibleAt(now, firingEdge, s, null);
});

// ---------------------------------------------------------------------------
// NudgeActions — write surface for surfaces (banner/notification) to use
// ---------------------------------------------------------------------------

/// Persists user actions on a Ritual's Nudge. Surfaces call into the
/// notifier rather than mutating synced-prefs directly so all Nudge writes
/// flow through one place — keeping any future analytics in one location.
class NudgeActions {
  NudgeActions(this._ref);

  final Ref _ref;

  /// Stamps `dismissed_at = at` (default: now). Suppresses the Nudge until
  /// any Trigger firing edge advances past `at`. See CONTEXT.md's **Nudge**
  /// entry. Pass [at] when replaying an action taken earlier (a notification
  /// button tapped in a background isolate): the instant the user acted, not
  /// the instant it was recorded, decides which firings it covers.
  Future<void> dismiss(RitualId ritual, {DateTime? at}) async {
    await syncedPrefs(_ref).set(
      _dismissedAtKey(ritual),
      (at ?? _ref.read(clockProvider)()).toUtc().toIso8601String(),
    );
  }

  /// Stamps `snoozed_until = at + [duration]` ([at] defaults to now). Hides
  /// the Nudge until that timestamp regardless of Trigger refires.
  Future<void> snooze(RitualId ritual, Duration duration,
      {DateTime? at}) async {
    await syncedPrefs(_ref).set(
      _snoozedUntilKey(ritual),
      (at ?? _ref.read(clockProvider)()).toUtc().add(duration).toIso8601String(),
    );
  }

  /// Clears any active snooze. Used when the user explicitly opens the
  /// Ceremony — opening implicitly cancels a snooze.
  Future<void> clearSnooze(RitualId ritual) async {
    await syncedPrefs(_ref).remove(_snoozedUntilKey(ritual));
  }
}

final nudgeActionsProvider = Provider<NudgeActions>(NudgeActions.new);

// ---------------------------------------------------------------------------
// Nudge queue
// ---------------------------------------------------------------------------

/// The Nudge queue: the list of currently-visible Ritual Nudges ordered by
/// Ritual priority. Surfaces (Banner, Notification) consume the head — the
/// queue is empty when no Ritual's Nudge is visible.
///
/// See `CONTEXT.md`'s **Nudge queue** entry. Recomputed reactively from the
/// per-Ritual `nudgeVisibleProvider`s.
final nudgeQueueProvider = Provider<List<RitualId>>((ref) {
  return [
    for (final ritual in ritualsByPriority)
      if (ref.watch(nudgeVisibleProvider(ritual))) ritual,
  ];
});

/// The head of the Nudge queue (highest-priority currently-visible Ritual)
/// or `null` if the queue is empty. Convenience accessor for single-
/// occupancy surfaces.
final nudgeQueueHeadProvider = Provider<RitualId?>((ref) {
  final q = ref.watch(nudgeQueueProvider);
  return q.isEmpty ? null : q.first;
});
