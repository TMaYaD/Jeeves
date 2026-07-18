/// How the clarify act maps Captures onto Outcomes.
///
/// A user preference over the *same* many-to-many storage (`captures` ×
/// `capture_outcomes`), never a storage change — toggling mid-stream leaves
/// every existing row valid. See `CONTEXT.md` § GTD Core (Capture) and
/// ADR-0006.
library;

/// The `user_preferences` key the selected mode is stored under.
///
/// Declared beside the enum so both the provider that reads/writes it and the
/// conflict registry that arbitrates it (`user_preferences_conflict.dart`) name
/// the same literal.
const kClarifyModePrefKey = 'clarify_mode';

/// The two clarify modes. Persisted by [name], so the wire values are
/// `oneToOne` / `nToM`.
enum ClarifyMode {
  /// Each Capture clarifies to *at most* one Outcome: routing to an Intent
  /// creates exactly one and `clarified_at` stamps automatically at that first
  /// Outcome link, while a discard is the legitimate zero-Outcome verdict that
  /// stamps without creating anything (ADR-0006). The shipped behaviour.
  oneToOne,

  /// Split/merge. The user explicitly completes each Capture and only that
  /// completion stamps `clarified_at`, so a Capture stays in the Inbox while
  /// Outcomes are incrementally carved out of it.
  nToM;

  /// Decodes a persisted value, falling back to [oneToOne] for anything
  /// unrecognised.
  ///
  /// The fallback is deliberate: a value written by a future client (or a
  /// corrupted row) must degrade to the safe, shipped mode rather than wedge
  /// the Inbox in a mode this build cannot drive.
  static ClarifyMode fromString(String? value) => ClarifyMode.values.firstWhere(
        (mode) => mode.name == value,
        orElse: () => ClarifyMode.oneToOne,
      );
}
