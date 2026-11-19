/// The calendar's effect on the day, as pure functions: where the day ends when
/// a calendar is connected, and which events block time inside it.
library;

import 'package:flutter/material.dart' show TimeOfDay;

import '../services/calendar/calendar_types.dart';
import 'autoflow.dart';

/// The moment the working day ends when a calendar is connected: the Evening
/// Shutdown time on [flowOrigin]'s day. Null when the day has already ended (the
/// origin is at or after it); the caller then falls back to the available time
/// the user types.
DateTime? calendarDayEnd({
  required DateTime flowOrigin,
  required TimeOfDay shutdownTime,
}) {
  final end = DateTime(flowOrigin.year, flowOrigin.month, flowOrigin.day,
      shutdownTime.hour, shutdownTime.minute);
  return end.isAfter(flowOrigin) ? end : null;
}

/// The timed events that block time inside [from]..[to], clipped to it.
/// All-day events do not block and are dropped.
List<BusyInterval> busyIntervalsWithin(
  Iterable<CalendarEvent> events,
  DateTime from,
  DateTime to,
) {
  final busy = <BusyInterval>[];
  for (final event in events) {
    if (event.isAllDay) continue;
    final start = event.start.isBefore(from) ? from : event.start;
    final end = event.end.isAfter(to) ? to : event.end;
    if (end.isAfter(start)) busy.add(BusyInterval(start: start, end: end));
  }
  return busy;
}

/// The timed events that fall inside [from]..[to], for listing, in start order.
List<CalendarEvent> timedEventsWithin(
  Iterable<CalendarEvent> events,
  DateTime from,
  DateTime to,
) =>
    [
      for (final event in events)
        if (!event.isAllDay &&
            event.end.isAfter(from) &&
            event.start.isBefore(to))
          event,
    ]..sort((a, b) => a.start.compareTo(b.start));

/// Minutes of [from]..[to] not covered by [busy].
int freeMinutesBetween(DateTime from, DateTime to, List<BusyInterval> busy) {
  final sorted = [...busy]..sort((a, b) => a.start.compareTo(b.start));
  var cursor = from;
  var free = 0;
  for (final interval in sorted) {
    if (interval.start.isAfter(cursor)) {
      free += interval.start.difference(cursor).inMinutes;
    }
    if (interval.end.isAfter(cursor)) cursor = interval.end;
  }
  if (to.isAfter(cursor)) free += to.difference(cursor).inMinutes;
  return free;
}
