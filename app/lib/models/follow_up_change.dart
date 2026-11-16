/// A change to the follow-up date of a Waiting For Outcome, carried on the
/// routing write. The follow-up date is the `from` date of the current Action's
/// TimeContext; it is not stored anywhere else.
///
/// "Untouched" is a `null` [FollowUpChange] at the call site, not a value.
class FollowUpChange {
  /// Follow up from this calendar date (time part ignored).
  const FollowUpChange.set(DateTime this.date);

  /// Drop the follow-up date, keeping any weekly window.
  const FollowUpChange.remove() : date = null;

  /// The new date, or null when this change removes the follow-up.
  final DateTime? date;

  bool get isRemoval => date == null;
}
