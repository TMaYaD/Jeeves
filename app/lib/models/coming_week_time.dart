/// coming_week_time — when an Outcome's time opens in the coming seven days
/// (GitHub #1073).
///
/// "When does this Outcome open?": the seven calendar days that start on the
/// day of the review, in the phone's time zone. A time opens on a day when it
/// has an opening that starts on that day and has not already ended at the
/// review's clock. An opening that started the day before and runs past
/// midnight belongs to that day, so it does not open the coming week.
///
/// Pure: it reads no clock and no store. Nothing is stored and nothing syncs.
library;

import 'action_place_and_time_window.dart';
import 'time_context.dart';

/// The line the Weekly Review shows for an Outcome whose time opens in the
/// seven days starting on [now]'s local day, or null when its time does not
/// open in that week.
///
/// A named [window] wins over a [timeContext]: an Action carries one time, and
/// a window and a Time context are exclusive.
String? comingWeekTimeLine({
  ActionTimeWindow? window,
  TimeContext? timeContext,
  required DateTime now,
}) {
  final local = now.toLocal();
  final today = DateTime(local.year, local.month, local.day);

  if (window != null) {
    final openings = _windowOpenings(window, local, today);
    if (openings.isEmpty) return null;
    return '${window.name} · ${_describeOpenings(openings, today)}';
  }

  if (timeContext == null) return null;

  // A Time context with no weekly days is only a from-date: it has no opening
  // to list, so the line says when the time starts instead.
  if (timeContext.days == null) return _fromDateLine(timeContext, today);

  final openings = _contextOpenings(timeContext, local, today);
  if (openings.isEmpty) return null;
  return _describeOpenings(openings, today);
}

/// The openings of a named window on the seven days of the coming week.
List<_Opening> _windowOpenings(
  ActionTimeWindow window,
  DateTime now,
  DateTime today,
) {
  final openings = <_Opening>[];
  for (var dayOffset = 0; dayOffset < _comingWeekDays; dayOffset++) {
    final day = DateTime(today.year, today.month, today.day + dayOffset);
    final hours = window.hours.hoursForDay(day.weekday);
    if (hours == null) continue;
    final end = _openingEnd(day, hours.startMinute, hours.endMinute);
    if (!end.isAfter(now)) continue;
    openings.add(_Opening(
      dayOffset: dayOffset,
      startMinute: hours.startMinute,
      endMinute: hours.endMinute,
      allDay: false,
    ));
  }
  return openings;
}

/// The openings of a Time context on the seven days of the coming week.
///
/// The context decides which days it applies to — the from-date, the weekly
/// days and the window between hours — and every day it applies to it opens
/// for that window.
List<_Opening> _contextOpenings(
  TimeContext timeContext,
  DateTime now,
  DateTime today,
) {
  final openings = <_Opening>[];
  for (var dayOffset = 0; dayOffset < _comingWeekDays; dayOffset++) {
    final day = DateTime(today.year, today.month, today.day + dayOffset);
    if (timeContext.allowedIntervalOn(day) == null) continue;
    final startMinute = timeContext.startMinute ?? 0;
    final endMinute = timeContext.endMinute ?? _minutesInDay;
    final end = _openingEnd(day, startMinute, endMinute);
    if (!end.isAfter(now)) continue;
    openings.add(_Opening(
      dayOffset: dayOffset,
      startMinute: startMinute,
      endMinute: endMinute,
      allDay: timeContext.startMinute == null,
    ));
  }
  return openings;
}

/// The instant an opening that starts at [startMinute] on [day] ends.
///
/// A window that runs past midnight ends the next day; an end of 24:00 is the
/// next midnight.
DateTime _openingEnd(DateTime day, int startMinute, int endMinute) =>
    endMinute > startMinute
        ? DateTime(day.year, day.month, day.day, 0, endMinute)
        : DateTime(day.year, day.month, day.day + 1, 0, endMinute);

/// The line for a Time context that is only a from-date: `From Wed 2 Dec`.
///
/// Null when the date does not fall in the coming week — a from-date that is
/// past, or further out than the seven days, opens nothing the reviewer can
/// plan for.
String? _fromDateLine(TimeContext timeContext, DateTime today) {
  final fromDate = timeContext.fromDate;
  if (fromDate == null) return null;
  final lastDay = DateTime(today.year, today.month, today.day + _comingWeekDays - 1);
  if (fromDate.isBefore(today) || fromDate.isAfter(lastDay)) return null;
  final dayName = _dayNames[fromDate.weekday - 1];
  final monthName = _monthNames[fromDate.month - 1];
  return 'From $dayName ${fromDate.day} $monthName';
}

/// The line for the openings: the days they fall on, in calendar order from
/// today, grouped into ranges of neighbouring days that share hours.
String _describeOpenings(List<_Opening> openings, DateTime today) {
  final groups = _groupOpenings(openings);
  return groups.map((group) => _groupLabel(group, today)).join(' · ');
}

/// Splits the openings into runs of neighbouring days that share hours.
///
/// Only neighbours group: a window open on Monday and Wednesday with the same
/// hours is two groups, because Tuesday is closed between them.
List<List<_Opening>> _groupOpenings(List<_Opening> openings) {
  final groups = <List<_Opening>>[];
  for (final opening in openings) {
    if (groups.isNotEmpty) {
      final group = groups.last;
      final previous = group.last;
      if (previous.dayOffset + 1 == opening.dayOffset &&
          previous.startMinute == opening.startMinute &&
          previous.endMinute == opening.endMinute &&
          previous.allDay == opening.allDay) {
        group.add(opening);
        continue;
      }
    }
    groups.add([opening]);
  }
  return groups;
}

/// The label of one group of openings: its days, and its hours when it has
/// any.
String _groupLabel(List<_Opening> group, DateTime today) {
  final first = group.first;
  final last = group.last;
  final firstDay =
      DateTime(today.year, today.month, today.day + first.dayOffset);
  final lastDay = DateTime(today.year, today.month, today.day + last.dayOffset);

  final String label;
  if (group.length == _comingWeekDays) {
    label = 'Every day';
  } else if (group.length == 1) {
    label = _dayNames[firstDay.weekday - 1];
  } else {
    label =
        '${_dayNames[firstDay.weekday - 1]}–${_dayNames[lastDay.weekday - 1]}';
  }

  if (first.allDay) return label;
  return '$label ${_clock(first.startMinute)}–${_clock(first.endMinute)}';
}

/// One opening of a time on one day of the coming week.
class _Opening {
  const _Opening({
    required this.dayOffset,
    required this.startMinute,
    required this.endMinute,
    required this.allDay,
  });

  /// Days from the day of the review: 0 is today.
  final int dayOffset;

  /// Minutes after local midnight when the opening starts.
  final int startMinute;

  /// Minutes after local midnight when it ends. A value at or below
  /// [startMinute] means the next day.
  final int endMinute;

  /// Whether the opening is the whole day, with no hours of its own.
  final bool allDay;
}

/// The days of the coming week: today and the six days after it.
const int _comingWeekDays = 7;

/// Minutes in a day.
const int _minutesInDay = 24 * 60;

const List<String> _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

const List<String> _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _clock(int minuteOfDay) {
  final hours = (minuteOfDay ~/ 60).toString().padLeft(2, '0');
  final minutes = (minuteOfDay % 60).toString().padLeft(2, '0');
  return '$hours:$minutes';
}
