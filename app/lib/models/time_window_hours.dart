/// TimeWindowHours — the hours of a time window (CONTEXT.md § Context).
///
/// "When is this window open?": hours that can differ by day, stored as one
/// canonical JSON text in `time_windows.hours`.
///
/// A window belongs to the day it **starts**: Monday 22:00–02:00 is open from
/// Monday 22:00 until Tuesday 02:00. A day with no entry is closed.
///
/// **Everything is local wall-clock time**: "open 11:00" means the clock where
/// the user is when the value is evaluated.
library;

import 'dart:convert';

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

  /// Whether the window is open at [now] (read in local time).
  ///
  /// Today's entry governs the hours from midnight to midnight; an entry that
  /// runs past midnight keeps the window open into the next morning, and
  /// yesterday's entry opens it again after midnight.
  bool isOpenAt(DateTime now) {
    final local = now.toLocal();
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

  /// The ISO weekday of the calendar day before [local].
  static int _previousWeekday(DateTime local) =>
      DateTime(local.year, local.month, local.day - 1).weekday;

  @override
  bool operator ==(Object other) =>
      other is TimeWindowHours && other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;

  @override
  String toString() => 'TimeWindowHours(${encode()})';
}
