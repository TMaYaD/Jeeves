/// In-memory retention for a Capture's in-progress clarify draft.
///
/// A Capture's title and notes are never written while a clarify surface is
/// open (ADR-0023), so nothing persists what the user has typed. Without
/// retention, stepping Back inside a Ceremony performance would re-seed the
/// card from the untouched row and the typing would be gone — the store is
/// what keeps ADR-0023 from being a regression rather than an enhancement.
///
/// **Not a Riverpod `Notifier`, deliberately.** A per-keystroke stash must not
/// publish state (every card in the ceremony would rebuild), and the card
/// stashes from `dispose()`, where `ref` is already unusable — the element is
/// marked defunct before `State.dispose()` runs and Riverpod asserts on
/// exactly that (#529). A plain object handed down the constructor can be
/// reached from there; a provider read cannot.
///
/// **Capture-only.** An Outcome's edits persist as they happen, so there is
/// nothing to retain. Surfaces with no in-flow navigation — the standalone
/// `/inbox/:id/clarify` screen and the Re-clarify route — are given no store
/// at all, so the absence is structural rather than a flag someone can flip.
library;

/// One Capture's in-progress clarify draft, plus the row values it was typed
/// against.
///
/// The baselines are what make re-seeding decidable per field: a field still
/// equal to its baseline is *clean*, so an incoming row value may replace it;
/// anything else is an edit in progress and wins.
class RetainedClarifyDraft {
  const RetainedClarifyDraft({
    required this.title,
    required this.notes,
    required this.baselineTitle,
    required this.baselineNotes,
    this.energyLevel,
    this.timeEstimateMinutes,
    this.dueDate,
  });

  /// What the user has typed. Untrimmed — it goes straight back into the
  /// controllers.
  final String title;
  final String notes;

  /// The trimmed row values [title] and [notes] were typed against. Compared
  /// against the *trimmed* draft, matching how the card's live binding decides
  /// clean from dirty.
  final String? baselineTitle;
  final String? baselineNotes;

  /// Draft-only attributes: a Capture has no column for any of them
  /// (ADR-0006), so they have no baseline and nothing to reconcile against —
  /// they are simply carried across the unmount, which is more than they
  /// survived before retention existed.
  final String? energyLevel;
  final int? timeEstimateMinutes;
  final DateTime? dueDate;

  /// Whether the title has been edited since it was last reconciled.
  bool get titleIsDirty => title.trim() != baselineTitle;

  /// Whether the notes have been edited since they were last reconciled.
  bool get notesIsDirty => notes.trim() != baselineNotes;

  /// Reconciles [retained] against the Capture row as local storage now holds
  /// it, per field. Pure — the whole conflict rule, decidable without a widget
  /// or a stream.
  ///
  /// | retained | incoming | result |
  /// |---|---|---|
  /// | no entry | `v` | field = `v`, baseline = `v` |
  /// | clean | `v` | incoming adopted: field = `v`, baseline = `v` |
  /// | dirty | `v` | draft wins: field = draft, **baseline stays stale** |
  ///
  /// Keeping the stale baseline is load-bearing rather than an oversight: it
  /// restores the field's dirty *state*, so the card's live listener keeps
  /// leaving that field alone for the rest of its life. Advancing the baseline
  /// to `v` would make the field read clean and let the very next incoming
  /// change silently overwrite the typing.
  ///
  /// There is no merge, ever. Field-granular last-writer with local-dirty-wins
  /// is already the card's documented contract.
  static RetainedClarifyDraft seedFrom(
    RetainedClarifyDraft? retained, {
    required String incomingTitle,
    required String? incomingNotes,
  }) {
    final incomingNotesText = incomingNotes ?? '';
    if (retained == null) {
      return RetainedClarifyDraft(
        title: incomingTitle,
        notes: incomingNotesText,
        baselineTitle: incomingTitle.trim(),
        baselineNotes: incomingNotesText.trim(),
      );
    }
    final titleDirty = retained.titleIsDirty;
    final notesDirty = retained.notesIsDirty;
    return RetainedClarifyDraft(
      title: titleDirty ? retained.title : incomingTitle,
      baselineTitle: titleDirty ? retained.baselineTitle : incomingTitle.trim(),
      notes: notesDirty ? retained.notes : incomingNotesText,
      baselineNotes:
          notesDirty ? retained.baselineNotes : incomingNotesText.trim(),
      // Draft-only attributes always come from the draft: the row cannot hold
      // them, so there is no incoming value that could win.
      energyLevel: retained.energyLevel,
      timeEstimateMinutes: retained.timeEstimateMinutes,
      dueDate: retained.dueDate,
    );
  }
}

/// The store itself: retained drafts keyed by Capture id.
///
/// Lifetime is a Ceremony performance. An entry survives Back and forward
/// across items and across step boundaries, and it survives abandoning a
/// performance and resuming it — retention that died on unmount would be
/// narrower than the cursor it accompanies ("it remembered where I was but not
/// what I typed"). It does not survive process death, which
/// [ClarifyRetention] makes no attempt to hide: an in-progress draft was never
/// a persisted thing.
///
/// **Skip does not discard.** Retention is cleared at a Capture's verdict and
/// at performance completion or reset, and nowhere else — so Skip, then Back,
/// still finds the typing.
///
/// One store is shared by both ceremonies, so a draft abandoned mid-clarify in
/// the Daily Planning Ritual seeds the same Capture in the Weekly Review. That
/// is the same user, mid-clarify of the same fragment, so it is accepted; two
/// providers at the injection sites would split them if it ever is not.
class ClarifyRetention {
  final _drafts = <String, RetainedClarifyDraft>{};

  RetainedClarifyDraft? read(String captureId) => _drafts[captureId];

  void stash(String captureId, RetainedClarifyDraft draft) {
    _drafts[captureId] = draft;
  }

  /// Drops one Capture's draft — called when it reaches a verdict, at which
  /// point the interpretation has landed on an Outcome and the draft is spent.
  void discard(String captureId) => _drafts.remove(captureId);

  /// Drops every draft, at performance completion or reset.
  ///
  /// This is also the only thing that bounds the store: a Capture the user
  /// typed into and then abandoned without a verdict keeps its entry until a
  /// ceremony resets. The entries are two strings apiece and a performance
  /// walks a snapshot of the Inbox, so the ceiling is the Inbox, not the
  /// session.
  void clearAll() => _drafts.clear();
}
