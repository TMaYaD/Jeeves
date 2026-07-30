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

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ritual.dart';
import 'ceremony_in_progress_provider.dart';
import 'nudge_triggers.dart';
import 'synced_preferences_provider.dart';

// ---------------------------------------------------------------------------
// Key helpers
// ---------------------------------------------------------------------------

String _dismissedAtKey(RitualId ritual) => '${ritual.keyPrefix}_nudge_dismissed_at';
String _snoozedUntilKey(RitualId ritual) => '${ritual.keyPrefix}_nudge_snoozed_until';

// ---------------------------------------------------------------------------
// NudgeState
// ---------------------------------------------------------------------------

/// Persisted Nudge state for one Ritual. The `visible` flag is *computed*
/// from this state combined with Trigger state and the in-progress flag — it
/// is not part of the persisted record.
class NudgeState {
  const NudgeState({this.dismissedAt, this.snoozedUntil});

  /// Timestamp of the most recent user-dismiss. The Nudge stays hidden until
  /// any Trigger's `firingSince` advances past this.
  final DateTime? dismissedAt;

  /// Snooze expiry. `null` means no snooze; a value in the past has expired
  /// and is treated as `null` for visibility purposes (kept around so a
  /// future "reactivate snooze" UX can read it).
  final DateTime? snoozedUntil;

  NudgeState copyWith({
    DateTime? dismissedAt,
    DateTime? snoozedUntil,
    bool clearDismissedAt = false,
    bool clearSnoozedUntil = false,
  }) {
    return NudgeState(
      dismissedAt: clearDismissedAt ? null : (dismissedAt ?? this.dismissedAt),
      snoozedUntil:
          clearSnoozedUntil ? null : (snoozedUntil ?? this.snoozedUntil),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NudgeState &&
      other.dismissedAt == dismissedAt &&
      other.snoozedUntil == snoozedUntil;

  @override
  int get hashCode => Object.hash(dismissedAt, snoozedUntil);
}

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

  // In-progress hygiene — ADR-0009. Hidden regardless of Trigger state.
  if (ref.watch(ceremonyInProgressForProvider(ritual))) return false;

  final firingEdge = ref.watch(mostRecentFiringEdgeProvider(ritual));
  if (firingEdge == null) return false;

  final s = ref.watch(nudgeStateProvider(ritual));
  final now = DateTime.now();

  // Snooze blocks visibility until expiry.
  if (s.snoozedUntil != null && now.isBefore(s.snoozedUntil!)) return false;

  // Dismiss blocks until a Trigger refires past the dismiss time.
  if (s.dismissedAt != null && !s.dismissedAt!.isBefore(firingEdge)) {
    return false;
  }

  return true;
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

  /// Stamps `dismissed_at = now`. Suppresses the Nudge until any Trigger
  /// firing edge advances past `now`. See CONTEXT.md's **Nudge** entry.
  Future<void> dismiss(RitualId ritual) async {
    await syncedPrefs(_ref).set(
      _dismissedAtKey(ritual),
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  /// Stamps `snoozed_until = now + [duration]`. Hides the Nudge until
  /// that timestamp regardless of Trigger refires.
  Future<void> snooze(RitualId ritual, Duration duration) async {
    await syncedPrefs(_ref).set(
      _snoozedUntilKey(ritual),
      DateTime.now().toUtc().add(duration).toIso8601String(),
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
