/// Pure Nudge predicates shared by live providers and future projections.
library;

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
      snoozedUntil: clearSnoozedUntil
          ? null
          : (snoozedUntil ?? this.snoozedUntil),
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

/// Frozen Daily Planning facts. Use session timestamps for projections.
class DprFacts {
  const DprFacts({
    required this.planningHour,
    required this.planningMinute,
    required this.shutdownHour,
    required this.shutdownMinute,
    required this.hasAnyItem,
    required this.hasInboxOrNext,
    this.latestSessionStartedAt,
  }) : _qualifyingSessionExists = null;

  /// Adapter for the live provider's existing per-anchor database query.
  /// These facts apply only to the instant whose period the query describes.
  /// Future projections must use the timestamp constructor instead.
  const DprFacts.forCurrentPeriod({
    required this.planningHour,
    required this.planningMinute,
    required this.shutdownHour,
    required this.shutdownMinute,
    required this.hasAnyItem,
    required this.hasInboxOrNext,
    required bool qualifyingSessionExists,
  }) : _qualifyingSessionExists = qualifyingSessionExists,
       latestSessionStartedAt = null;

  final int planningHour;
  final int planningMinute;
  final int shutdownHour;
  final int shutdownMinute;
  final bool hasAnyItem;
  final bool hasInboxOrNext;
  final DateTime? latestSessionStartedAt;
  final bool? _qualifyingSessionExists;
}

class EsFacts {
  const EsFacts({
    required this.shutdownHour,
    required this.shutdownMinute,
    required this.sessionIsOpen,
  });

  final int shutdownHour;
  final int shutdownMinute;
  final bool sessionIsOpen;
}

class WrFacts {
  const WrFacts({
    required this.hasAnyItem,
    this.lastCompleted,
    this.contentFiringEdge,
  });

  final bool hasAnyItem;
  final DateTime? lastCompleted;

  /// Null when the content-state Trigger is not firing.
  final DateTime? contentFiringEdge;
}

DateTime _todayAt(DateTime instant, int hour, int minute) =>
    DateTime(instant.year, instant.month, instant.day, hour, minute);

DateTime? dprFiringEdgeAt(DateTime instant, DprFacts facts) {
  if (!facts.hasAnyItem || !facts.hasInboxOrNext) return null;
  final planningAnchor = _todayAt(
    instant,
    facts.planningHour,
    facts.planningMinute,
  );
  if (instant.isBefore(planningAnchor)) return null;
  final shutdownToday = _todayAt(
    instant,
    facts.shutdownHour,
    facts.shutdownMinute,
  );
  final lastShutdownAnchor = instant.isBefore(shutdownToday)
      ? DateTime(
          instant.year,
          instant.month,
          instant.day - 1,
          facts.shutdownHour,
          facts.shutdownMinute,
        )
      : shutdownToday;
  final qualifying =
      facts._qualifyingSessionExists ??
      (facts.latestSessionStartedAt != null &&
          !facts.latestSessionStartedAt!.isBefore(lastShutdownAnchor));
  if (qualifying) return null;
  return planningAnchor.isAfter(lastShutdownAnchor)
      ? planningAnchor
      : lastShutdownAnchor;
}

DateTime? esFiringEdgeAt(DateTime instant, EsFacts facts) {
  if (!facts.sessionIsOpen) return null;
  final anchor = _todayAt(instant, facts.shutdownHour, facts.shutdownMinute);
  return instant.isBefore(anchor) ? null : anchor;
}

/// Most recent active Weekly Review Trigger edge. Content edges are already
/// tracked by the live provider and remain frozen during a projection.
DateTime? wrFiringEdgeAt(DateTime instant, WrFacts facts) {
  if (!facts.hasAnyItem) return null;
  final lastCompleted = facts.lastCompleted;
  // Each elapsed seven-day period is a fresh firing (releasing a dismissal
  // from the previous one): the edge is lastCompleted + 7d·k for the largest
  // k whose edge is not after the instant. Before the first boundary there is
  // no cadence edge.
  final DateTime? cadenceEdge;
  if (lastCompleted == null) {
    cadenceEdge = _todayAt(instant, 0, 0);
  } else {
    final elapsedPeriods = instant.difference(lastCompleted).inDays ~/ 7;
    cadenceEdge = elapsedPeriods < 1
        ? null
        : lastCompleted.add(Duration(days: 7 * elapsedPeriods));
  }
  final contentEdge = facts.contentFiringEdge;
  if (cadenceEdge == null) return contentEdge;
  if (contentEdge == null) return cadenceEdge;
  return contentEdge.isAfter(cadenceEdge) ? contentEdge : cadenceEdge;
}

/// In-progress suppression applies to the firing at performance entry; a
/// frozen performance cannot hide a later projected firing.
bool nudgeVisibleAt(
  DateTime instant,
  DateTime? edge,
  NudgeState state,
  DateTime? inProgressEdge,
) {
  if (edge == null) return false;
  if (inProgressEdge != null && edge.isAtSameMomentAs(inProgressEdge)) {
    return false;
  }
  if (state.snoozedUntil != null && instant.isBefore(state.snoozedUntil!)) {
    return false;
  }
  return state.dismissedAt == null || state.dismissedAt!.isBefore(edge);
}
