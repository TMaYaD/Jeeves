/// The planned day — the stretch of the day being planned, and when an
/// Outcome's time opens inside it (CONTEXT.md § Context).
///
/// The planned day runs from now to today's Evening Shutdown time, or to the
/// next midnight when the planning runs after that time. An Outcome whose time
/// opens inside the planned day can be picked, even though it cannot be done
/// yet.
library;

import 'package:flutter/material.dart' show TimeOfDay;

/// The end of the day being planned: today's Evening Shutdown time when that
/// is still ahead of [now], otherwise the next local midnight.
DateTime plannedDayEnd({
  required DateTime now,
  required TimeOfDay shutdownTime,
}) {
  final local = now.toLocal();
  final shutdown = DateTime(local.year, local.month, local.day,
      shutdownTime.hour, shutdownTime.minute);
  if (shutdown.isAfter(local)) return shutdown;
  return DateTime(local.year, local.month, local.day + 1);
}

/// The first instant in the planned day at which the Outcome's time is open,
/// or null when it does not open in that day.
///
/// [now] itself when the time is open now. Otherwise the first instant
/// between [now] and [dayEnd] at which it opens, found by walking
/// [nextTransitionAfter] from [now]: a transition is a moment at which "open
/// now" can change, and the first transition that is open is the moment the
/// Outcome becomes available. The walk is bounded so that a transition which
/// does not open cannot hide a later one that does.
///
/// [isOpenAt] and [nextTransitionAfter] are taken as functions, so a
/// TimeContext and a TimeWindowHours each answer for themselves and neither
/// needs to know about the other.
DateTime? firstOpenInPlannedDay({
  required bool Function(DateTime) isOpenAt,
  required DateTime? Function(DateTime) nextTransitionAfter,
  required DateTime now,
  required DateTime dayEnd,
}) {
  if (isOpenAt(now)) return now;
  var cursor = now;
  for (var step = 0; step < 4; step++) {
    final candidate = nextTransitionAfter(cursor);
    if (candidate == null) return null;
    if (!candidate.isAfter(cursor)) return null;
    if (!candidate.isBefore(dayEnd)) return null;
    if (isOpenAt(candidate)) return candidate;
    cursor = candidate;
  }
  return null;
}

/// The first stretch in [from]..[until] during which the Outcome's time is
/// open, or null when it does not open in that span.
///
/// The start is [firstOpenInPlannedDay]'s answer, so a placement inside the
/// stretch always agrees with the moment Up Next marks as "from 11:00". The
/// end is the first transition after the start at which the time is no longer
/// open, or [until] when it is still open there. The walk is bounded like
/// [firstOpenInPlannedDay]'s, and when it runs out while still open the end is
/// the last transition reached.
({DateTime start, DateTime end})? firstOpenStretchInPlannedDay({
  required bool Function(DateTime) isOpenAt,
  required DateTime? Function(DateTime) nextTransitionAfter,
  required DateTime from,
  required DateTime until,
}) {
  final start = firstOpenInPlannedDay(
    isOpenAt: isOpenAt,
    nextTransitionAfter: nextTransitionAfter,
    now: from,
    dayEnd: until,
  );
  if (start == null) return null;
  var cursor = start;
  for (var step = 0; step < 4; step++) {
    final candidate = nextTransitionAfter(cursor);
    if (candidate == null) return (start: start, end: until);
    if (!candidate.isAfter(cursor)) return (start: start, end: until);
    if (!candidate.isBefore(until)) return (start: start, end: until);
    if (!isOpenAt(candidate)) return (start: start, end: candidate);
    cursor = candidate;
  }
  return (start: start, end: cursor);
}
