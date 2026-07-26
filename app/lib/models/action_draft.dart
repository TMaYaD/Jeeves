/// The editable attributes of an **Action** as a UI/service-boundary value.
///
/// Names what the user is describing when they say what the next physical,
/// visible step is: the phrase itself plus the two effort attributes that
/// belong to the *action of doing* rather than to the Outcome (ADR-0001).
/// It travels from a clarify surface or the Plan section's sheet down to
/// [ClarificationService] / `TaskDetailNotifier`, and stops there.
///
/// **No DAO takes this type.** `ActionDao` and `TodoDao` keep their scalar
/// parameters, so the D1–D4 metadata machinery (`docs/ARCHITECTURE.md`
/// § Action metadata) is untouched by the existence of this type and cannot
/// regress because of it. The boundary unpacks the draft into those scalars.
///
/// **Its values do not always land on an Action row.** While an Outcome is
/// Actionless the effort values live on the `todos` columns as draft storage
/// (D3), and seed the birth Action when one is first created. That is why a
/// clarify surface can collect energy and estimate for a Capture that has no
/// Action yet.
class ActionDraft {
  const ActionDraft({
    required this.text,
    this.energyLevel,
    this.timeEstimateMinutes,
  });

  /// The Action's phrase.
  ///
  /// Normally non-blank: "is there an Action here at all?" is answered one
  /// level up, by the *draft* being null, and the clarify surfaces and the
  /// Plan sheet null the whole draft rather than carry a blank phrase beside
  /// live effort values. It is not an enforced invariant, though — a caller
  /// that already holds a non-null phrase can pass an empty one
  /// (`FocusSessionPlanningNotifier` does, when the inbox row's text is
  /// empty). That is safe rather than merely tolerated: every write path
  /// beneath normalises blank text, `TodoDao.applyRouting` turning it into a
  /// supersede-to-Actionless.
  final String text;

  /// `'low' | 'medium' | 'high'`, or null when unset.
  final String? energyLevel;

  /// Estimated minutes to do the Action, or null when unset.
  final int? timeEstimateMinutes;

  /// Returns a copy with the named fields replaced. `null` means "keep";
  /// use [clearEnergyLevel] / [clearTimeEstimate] to null a value, matching
  /// the `clear*` convention of `TodoDao.updateFields` and
  /// `ActionDao.editAction`.
  ActionDraft copyWith({
    String? text,
    String? energyLevel,
    int? timeEstimateMinutes,
    bool clearEnergyLevel = false,
    bool clearTimeEstimate = false,
  }) {
    return ActionDraft(
      text: text ?? this.text,
      energyLevel: clearEnergyLevel ? null : (energyLevel ?? this.energyLevel),
      timeEstimateMinutes: clearTimeEstimate
          ? null
          : (timeEstimateMinutes ?? this.timeEstimateMinutes),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActionDraft &&
          other.text == text &&
          other.energyLevel == energyLevel &&
          other.timeEstimateMinutes == timeEstimateMinutes;

  @override
  int get hashCode => Object.hash(text, energyLevel, timeEstimateMinutes);

  @override
  String toString() => 'ActionDraft(text: $text, energyLevel: $energyLevel, '
      'timeEstimateMinutes: $timeEstimateMinutes)';
}
