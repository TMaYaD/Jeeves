/// TimeWindowHours — the hours of a time window (CONTEXT.md § Context).
///
/// "When is this window open?": hours that can differ by day, stored as one
/// canonical JSON text in `time_windows.hours`.
///
/// A window belongs to the day it **starts**: Monday 22:00–02:00 is open from
/// Monday 22:00 until Tuesday 02:00. A day with no entry is closed.
///
/// **Everything is wall-clock time**: "open 11:00" means the clock where the
/// value is evaluated — the phone's clock, or the clock of the place the
/// hours belong to when they are read on a time zone.
library;

import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

/// The hours of one ISO weekday (1 = Monday … 7 = Sunday): minutes after local
/// midnight. [endMinute] may be 24:00 (the next midnight); when it is smaller
/// than [startMinute] the window runs past midnight into the next day.
typedef DayHours = ({int startMinute, int endMinute});

class TimeWindowHours {
  /// ISO weekdays, 1 = Monday … 7 = Sunday, to the hours of that day.
  final Map<int, DayHours> _byDay;

  const TimeWindowHours._(this._byDay);

  /// Builds the hours of a time window, or returns null when the combination
  /// is invalid: no days at all, a day outside Monday to Sunday, a clock
  /// outside the day, or a day that starts and ends at the same minute.
  static TimeWindowHours? create(Map<int, DayHours> hours) {
    if (hours.isEmpty) return null;
    for (final entry in hours.entries) {
      if (entry.key < 1 || entry.key > 7) return null;
      final start = entry.value.startMinute;
      final end = entry.value.endMinute;
      if (start < 0 || start >= 24 * 60) return null;
      if (end < 0 || end > 24 * 60) return null;
      if (end == start) return null;
    }
    final sorted = hours.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return TimeWindowHours._(
      Map<int, DayHours>.unmodifiable(
        Map<int, DayHours>.fromEntries(sorted),
      ),
    );
  }

  /// The hours of [day] (ISO weekday), or null when the window is closed that
  /// day.
  DayHours? hoursForDay(int day) => _byDay[day];

  /// The days the window has hours for, in week order.
  List<int> get days => _byDay.keys.toList();

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _clock(int minuteOfDay) =>
      '${_two(minuteOfDay ~/ 60)}:${_two(minuteOfDay % 60)}';

  /// The canonical JSON text. A JSON array sorted by day, each element
  /// `{"day":<1-7>,"start":"HH:MM","end":"HH:MM"}` in that fixed key order, so
  /// two devices writing the same hours write the same bytes.
  String encode() {
    final elements = <Map<String, Object?>>[];
    for (final day in _byDay.keys) {
      final hours = _byDay[day]!;
      elements.add(<String, Object?>{
        'day': day,
        'start': _clock(hours.startMinute),
        'end': _clock(hours.endMinute),
      });
    }
    return jsonEncode(elements);
  }

  static final _clockPattern = RegExp(r'^(\d{2}):(\d{2})$');

  static int? _parseClock(Object? raw) {
    if (raw is! String) return null;
    final m = _clockPattern.firstMatch(raw);
    if (m == null) return null;
    final h = int.parse(m.group(1)!);
    final min = int.parse(m.group(2)!);
    if (min > 59 || h > 24 || (h == 24 && min != 0)) return null;
    return h * 60 + min;
  }

  /// Parses a stored value. Null for null, blank or anything that is not a
  /// valid shape (unknown key, duplicate day, bad clock, no days) — a value
  /// the app cannot read must never hide anything.
  static TimeWindowHours? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! List) return null;
    if (decoded.isEmpty) return null;
    const known = {'day', 'start', 'end'};
    final hours = <int, DayHours>{};
    for (final element in decoded) {
      if (element is! Map) return null;
      if (element.keys.any((k) => !known.contains(k))) return null;
      if (!element.containsKey('day') ||
          !element.containsKey('start') ||
          !element.containsKey('end')) {
        return null;
      }
      final day = element['day'];
      if (day is! int) return null;
      if (day < 1 || day > 7) return null;
      final start = _parseClock(element['start']);
      final end = _parseClock(element['end']);
      if (start == null || end == null) return null;
      if (hours.containsKey(day)) return null;
      hours[day] = (startMinute: start, endMinute: end);
    }
    return create(hours);
  }

  /// Whether the window is open at [now].
  ///
  /// The hours are read on the phone's clock, or on [location]'s clock when a
  /// place carries its own hours and its own time zone.
  ///
  /// Today's entry governs the hours from midnight to midnight; an entry that
  /// runs past midnight keeps the window open into the next morning, and
  /// yesterday's entry opens it again after midnight.
  bool isOpenAt(DateTime now, {tz.Location? location}) {
    final local = _wallClock(now, location);
    final minuteOfDay = local.hour * 60 + local.minute;

    final today = _byDay[local.weekday];
    if (today != null) {
      if (today.endMinute > today.startMinute) {
        if (minuteOfDay >= today.startMinute &&
            minuteOfDay < today.endMinute) {
          return true;
        }
      } else if (minuteOfDay >= today.startMinute) {
        return true;
      }
    }

    // A window that started yesterday and runs past midnight stays open until
    // it ends this morning.
    final yesterday = _byDay[_previousWeekday(local)];
    if (yesterday != null && yesterday.endMinute < yesterday.startMinute) {
      if (minuteOfDay < yesterday.endMinute) return true;
    }
    return false;
  }

  /// The clock [now] reads on: the phone's when [location] is null, the
  /// place's own clock when it is not.
  static DateTime _wallClock(DateTime now, tz.Location? location) =>
      location == null ? now.toLocal() : tz.TZDateTime.from(now, location);

  /// The wall-clock instant [minuteOfDay] past midnight of [day], on
  /// [location]'s clock, or on the phone's when [location] is null.
  static DateTime _wallAt(
    DateTime day,
    int minuteOfDay,
    tz.Location? location,
  ) {
    if (location == null) {
      return DateTime(day.year, day.month, day.day, 0, minuteOfDay);
    }
    return tz.TZDateTime(
      location,
      day.year,
      day.month,
      day.day,
      0,
      minuteOfDay,
    );
  }

  /// The ISO weekday of the calendar day before [local].
  ///
  /// Read on the UTC calendar: a calendar date has the same weekday in every
  /// time zone, and UTC has no daylight-saving gap to shift the date.
  static int _previousWeekday(DateTime local) =>
      DateTime.utc(local.year, local.month, local.day - 1).weekday;

  static const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  /// A short description of the hours, e.g. `Mon–Fri 09:00–17:00` or
  /// `Mon–Fri 11:00–20:00 · Sat 10:00–14:00`.
  ///
  /// Days that share hours are grouped, but only neighbours: Monday and
  /// Wednesday with the same hours are two groups, because Tuesday is closed
  /// between them. A window that runs past midnight shows its end clock as it
  /// is — the editor is where "next day" is spelled out.
  String describe() {
    final groups = <String>[];
    final numbers = days;
    var index = 0;
    while (index < numbers.length) {
      final hours = _byDay[numbers[index]]!;
      var last = index;
      while (last + 1 < numbers.length &&
          numbers[last + 1] == numbers[last] + 1 &&
          _sameHours(_byDay[numbers[last + 1]]!, hours)) {
        last++;
      }
      groups.add(
        '${_dayLabel(numbers[index], numbers[last])} ${_hoursLabel(hours)}',
      );
      index = last + 1;
    }
    return groups.join(' · ');
  }

  /// The days of one group, as they read: one day by name, a run of days as a
  /// range, and the whole week as "Every day".
  static String _dayLabel(int first, int last) {
    if (first == 1 && last == 7) return 'Every day';
    if (first == last) return _dayNames[first - 1];
    return '${_dayNames[first - 1]}–${_dayNames[last - 1]}';
  }

  static String _hoursLabel(DayHours hours) =>
      '${_clock(hours.startMinute)}–${_clock(hours.endMinute)}';

  static bool _sameHours(DayHours a, DayHours b) =>
      a.startMinute == b.startMinute && a.endMinute == b.endMinute;

  /// The next instant after [now] at which the window flips between open
  /// and closed, or null when it cannot flip again.
  ///
  /// The hours are read on the phone's clock, or on [location]'s clock when a
  /// place carries its own hours and its own time zone. The returned instant
  /// is on that clock, so it is formatted there — never call `toLocal()` on
  /// it before comparing instants.
  ///
  /// Every hour boundary is a candidate, and a candidate counts only when the
  /// open state really differs across it — two overlapping days can meet at a
  /// boundary without the window closing there.
  ///
  /// A day that opens at 09:00 and closes at 17:00 flips twice; an overnight
  /// day (22:00–02:00) opens on its own day and closes the next morning.
  DateTime? nextTransitionAfter(DateTime now, {tz.Location? location}) {
    final local = _wallClock(now, location);
    DateTime? best;
    for (var offset = -1; offset <= 8; offset++) {
      final day = DateTime.utc(local.year, local.month, local.day + offset);
      final hours = _byDay[day.weekday];
      if (hours == null) continue;
      final start = _wallAt(day, hours.startMinute, location);
      // An end at or before the start belongs to the next day.
      final end = hours.endMinute > hours.startMinute
          ? _wallAt(day, hours.endMinute, location)
          : _wallAt(
              DateTime.utc(day.year, day.month, day.day + 1),
              hours.endMinute,
              location,
            );
      for (final candidate in [start, end]) {
        if (!candidate.isAfter(local)) continue;
        if (best != null && !candidate.isBefore(best)) continue;
        final before = candidate.subtract(const Duration(minutes: 1));
        if (isOpenAt(candidate, location: location) ==
            isOpenAt(before, location: location)) {
          continue;
        }
        best = candidate;
      }
    }
    return best;
  }

  @override
  bool operator ==(Object other) =>
      other is TimeWindowHours && other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;

  @override
  String toString() => 'TimeWindowHours(${encode()})';
}
