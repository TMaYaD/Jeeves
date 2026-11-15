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
    this.sessionIsOpen = false,
  }) : _startedTodayOverride = null;

  /// Adapter for the live provider's per-day database query. These facts apply
  /// only to the instant whose calendar day the query describes. Future
  /// projections must use the timestamp constructor instead.
  const DprFacts.forCurrentPeriod({
    required this.planningHour,
    required this.planningMinute,
    required this.shutdownHour,
    required this.shutdownMinute,
    required this.hasAnyItem,
    required this.hasInboxOrNext,
    required bool qualifyingSessionExists,
    this.sessionIsOpen = false,
  }) : _startedTodayOverride = qualifyingSessionExists,
       latestSessionStartedAt = null;

  final int planningHour;
  final int planningMinute;
  final int shutdownHour;
  final int shutdownMinute;
  final bool hasAnyItem;
  final bool hasInboxOrNext;
  final DateTime? latestSessionStartedAt;

  /// Whether any session is open, whenever it started.
  final bool sessionIsOpen;
  final bool? _startedTodayOverride;
}

/// Available time assumed when none was recorded: eight hours.
const int kDefaultEveningSessionAvailableMinutes = 480;

class EsFacts {
  const EsFacts({
    required this.shutdownHour,
    required this.shutdownMinute,
    required this.sessionIsOpen,
    this.planningHour = 8,
    this.planningMinute = 0,
    this.openSessionStartedAt,
    this.availableMinutes = kDefaultEveningSessionAvailableMinutes,
  });

  final int shutdownHour;
  final int shutdownMinute;
  final bool sessionIsOpen;

  /// Daily Planning time: an open session that is overdue is raised again at
  /// each planning time.
  final int planningHour;
  final int planningMinute;

  /// Start of the open session; null is read as "started before today's
  /// Evening Shutdown time".
  final DateTime? openSessionStartedAt;

  /// The available time the open session was planned with.
  final int availableMinutes;
}

class WrFacts {
  const WrFacts({this.dueAt, this.contentFiringEdge});

  /// When the Weekly Review falls due; null when nothing is due (no items).
  final DateTime? dueAt;

  /// Null when the content-state Trigger is not firing.
  final DateTime? contentFiringEdge;
}

DateTime _todayAt(DateTime instant, int hour, int minute) =>
    DateTime(instant.year, instant.month, instant.day, hour, minute);

/// Daily Planning is offered from today's planning time until the Evening
/// Shutdown time, and only when no session is open and none started today.
DateTime? dprFiringEdgeAt(DateTime instant, DprFacts facts) {
  if (!facts.hasAnyItem || !facts.hasInboxOrNext) return null;
  if (facts.sessionIsOpen) return null;
  final planningAnchor = _todayAt(
    instant,
    facts.planningHour,
    facts.planningMinute,
  );
  if (instant.isBefore(planningAnchor)) return null;
  final startedToday =
      facts._startedTodayOverride ??
      (facts.latestSessionStartedAt != null &&
          !facts.latestSessionStartedAt!.isBefore(_todayAt(instant, 0, 0)));
  if (startedToday) return null;
  final shutdownToday = _todayAt(
    instant,
    facts.shutdownHour,
    facts.shutdownMinute,
  );
  // From the Evening Shutdown time until the next planning time it is idle.
  if (shutdownToday.isAfter(planningAnchor) &&
      !instant.isBefore(shutdownToday)) {
    return null;
  }
  return planningAnchor;
}

/// The instant from which Evening Shutdown is due for the open session.
///
/// A session started before that day's Evening Shutdown time is due at it. A
/// session started in the Evening is due after its available time, but no later
/// than the next planning time.
DateTime eveningShutdownDueAt(DateTime startedAt, EsFacts facts) {
  final shutdownOnStartDay = _todayAt(
    startedAt,
    facts.shutdownHour,
    facts.shutdownMinute,
  );
  if (startedAt.isBefore(shutdownOnStartDay)) return shutdownOnStartDay;
  final availableTimeUp = startedAt.add(
    Duration(minutes: facts.availableMinutes),
  );
  final planningOnStartDay = _todayAt(
    startedAt,
    facts.planningHour,
    facts.planningMinute,
  );
  final nextPlanning = startedAt.isBefore(planningOnStartDay)
      ? planningOnStartDay
      : DateTime(
          startedAt.year,
          startedAt.month,
          startedAt.day + 1,
          facts.planningHour,
          facts.planningMinute,
        );
  return availableTimeUp.isBefore(nextPlanning) ? availableTimeUp : nextPlanning;
}

/// Evening Shutdown is raised from the due instant, and raised again at every
/// planning time and every Evening Shutdown time until the session is closed.
DateTime? esFiringEdgeAt(DateTime instant, EsFacts facts) {
  if (!facts.sessionIsOpen) return null;
  final startedAt =
      facts.openSessionStartedAt ?? _todayAt(instant, 0, 0);
  final dueAt = eveningShutdownDueAt(startedAt, facts);
  if (instant.isBefore(dueAt)) return null;
  var edge = dueAt;
  for (final (hour, minute) in [
    (facts.shutdownHour, facts.shutdownMinute),
    (facts.planningHour, facts.planningMinute),
  ]) {
    var anchor = _todayAt(instant, hour, minute);
    if (anchor.isAfter(instant)) {
      anchor = DateTime(instant.year, instant.month, instant.day - 1, hour, minute);
    }
    if (anchor.isAfter(edge)) edge = anchor;
  }
  return edge;
}

/// Most recent active Weekly Review Trigger edge. Content edges are already
/// tracked by the live provider and remain frozen during a projection.
///
/// While the review is due the Cadence Trigger fires afresh every day: its
/// edge is the later of the due instant and the start of today, so a swipe
/// holds for the rest of the day and the Banner is back tomorrow.
DateTime? wrFiringEdgeAt(DateTime instant, WrFacts facts) {
  final dueAt = facts.dueAt;
  DateTime? cadenceEdge;
  if (dueAt != null && !instant.isBefore(dueAt)) {
    final startOfDay = _todayAt(instant, 0, 0);
    cadenceEdge = dueAt.isAfter(startOfDay) ? dueAt : startOfDay;
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
