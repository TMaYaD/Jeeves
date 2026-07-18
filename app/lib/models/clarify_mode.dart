/// The user-selectable clarify modes (CONTEXT.md § GTD Core).
///
/// Both modes run over the same many-to-many Capture↔Outcome storage — the
/// mode is a preference, never a storage change. It governs only *when*
/// `captures.clarified_at` is stamped:
///
/// - [ClarifyMode.oneToOne] — each Capture clarifies to exactly one Outcome and
///   the first Outcome link stamps automatically.
/// - [ClarifyMode.nToM] — split/merge: the user explicitly completes each
///   Capture, and only that completion stamps. A Capture stays in the Inbox
///   while Outcomes are incrementally carved out of it.
library;

enum ClarifyMode {
  oneToOne('oneToOne'),
  nToM('nToM');

  const ClarifyMode(this.wireValue);

  /// The string persisted in `user_preferences` under `clarify_mode`. Pinned
  /// separately from the enum name so a future Dart-side rename cannot orphan
  /// every already-synced row.
  final String wireValue;

  /// The default mode for a user who has never chosen one.
  static const ClarifyMode defaultMode = ClarifyMode.oneToOne;

  /// Decodes a persisted [wireValue]. An absent, null, or unrecognised value
  /// resolves to [defaultMode] — a device running an older build must degrade
  /// to the quick flow rather than crash on a mode it cannot render.
  static ClarifyMode fromWireValue(String? value) {
    for (final mode in ClarifyMode.values) {
      if (mode.wireValue == value) return mode;
    }
    return defaultMode;
  }
}
