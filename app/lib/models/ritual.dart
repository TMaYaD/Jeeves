/// The three Rituals the app currently treats as integral to the user's GTD
/// practice. Each Ritual is a Ceremony with a discipline overlay; see
/// `CONTEXT.md`'s **Ritual** entry for the conceptual definition.
///
/// `RitualId` is the identifier used by the Nudge module to address each
/// Ritual's Nudge state, Triggers, and persistence keys.
enum RitualId {
  /// Weekly Review — restores the user's trusted state. Highest priority.
  weeklyReview,

  /// Daily Planning Ritual — opens a FocusSession's Planning phase.
  dailyPlanning,

  /// Evening Shutdown — closes the active FocusSession's Review phase.
  eveningShutdown,
}

extension RitualPriority on RitualId {
  /// Linear priority for the Nudge queue (higher = earlier). Today hardcoded;
  /// see `CONTEXT.md`'s **Ritual** entry for the rationale (Weekly Review
  /// restores the trusted state Daily Planning operates on).
  int get priority => switch (this) {
        RitualId.weeklyReview => 2,
        RitualId.dailyPlanning => 1,
        RitualId.eveningShutdown => 0,
      };

  /// Stable string key for SharedPreferences / synced-prefs / debugging.
  /// Matches the existing per-Ritual key prefixes so consolidation can
  /// migrate without rewriting stored values.
  String get keyPrefix => switch (this) {
        RitualId.weeklyReview => 'periodic_review',
        RitualId.dailyPlanning => 'planning',
        RitualId.eveningShutdown => 'shutdown',
      };
}

/// Rituals in descending priority order (queue position when all visible).
const ritualsByPriority = <RitualId>[
  RitualId.weeklyReview,
  RitualId.dailyPlanning,
  RitualId.eveningShutdown,
];
