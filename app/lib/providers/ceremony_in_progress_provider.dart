/// Tracks which Ceremonies currently have a performance in progress
/// (the user has opened the Ceremony but not yet completed or abandoned it).
///
/// Used by the Nudge module to enforce the centralised in-progress hygiene
/// rule (ADR-0009): while any Ceremony performance of a Ritual is in progress,
/// the Ritual's Nudge is hidden regardless of Trigger state.
///
/// State is in-memory only — a Ceremony in progress is a per-device, per-app-
/// session fact. App restart with the wizard not open implicitly marks all
/// Ceremonies as not-in-progress; that matches what the user expects.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ritual.dart';

/// The set of Rituals whose Ceremony is currently in progress.
///
/// Wizard screens flip the membership: enter on the screen's `initState`,
/// exit on `dispose`. Reads are non-blocking (synchronous set membership).
class CeremonyInProgressNotifier extends Notifier<Set<RitualId>> {
  @override
  Set<RitualId> build() => const <RitualId>{};

  /// Mark [ritual]'s Ceremony performance as in progress. Idempotent.
  void enter(RitualId ritual) {
    if (state.contains(ritual)) return;
    state = {...state, ritual};
  }

  /// Mark [ritual]'s Ceremony performance as terminated (completed or
  /// abandoned). The Nudge model treats both terminations identically for
  /// hygiene purposes — a completed performance also satisfies the Cadence
  /// Trigger's "not completed in this period" predicate via the Ritual's
  /// own completion stamp, which is written separately.
  void exit(RitualId ritual) {
    if (!state.contains(ritual)) return;
    state = state.where((r) => r != ritual).toSet();
  }
}

final ceremonyInProgressProvider =
    NotifierProvider<CeremonyInProgressNotifier, Set<RitualId>>(
  CeremonyInProgressNotifier.new,
);

/// True iff [ritual]'s Ceremony performance is currently in progress.
final ceremonyInProgressForProvider =
    Provider.family<bool, RitualId>((ref, ritual) {
  return ref.watch(ceremonyInProgressProvider).contains(ritual);
});
