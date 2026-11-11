/// TimeContext — the time predicate on an Action (CONTEXT.md § Context).
///
/// "When can this Action be done?": from a calendar date, in a weekly window, or
/// both. Stored as one canonical JSON text in `actions.time_context`.
///
/// **Everything is local wall-clock time**: "Tue 9–5" and "after 30 Nov" mean the
/// clock and calendar where the user is when the value is evaluated. A window
/// does not cross midnight (`end` is after `start` on the same day, exclusive).
///
/// Closed shape, not an RRULE: the accepted language is exactly these three
/// fields, and nothing outside the app reads the value.
library;

import 'dart:convert';

class TimeContext {
  /// Satisfied from 00:00 local on this calendar date (time part ignored).
  final DateTime? fromDate;

  /// ISO weekdays, 1 = Monday … 7 = Sunday. Null: any day.
  final Set<int>? days;

  /// Minutes after local midnight; both set or both null; need [days].
  final int? startMinute;
  final int? endMinute;

  const TimeContext._({
    this.fromDate,
    this.days,
    this.startMinute,
    this.endMinute,
  });

  /// Builds a TimeContext, or returns null when the combination is invalid.
  static TimeContext? create({
    DateTime? fromDate,
    Set<int>? days,
    int? startMinute,
    int? endMinute,
  }) {
    final dayOnly =
        fromDate == null ? null : DateTime(fromDate.year, fromDate.month, fromDate.day);
    if (days != null) {
      if (days.isEmpty || days.any((d) => d < 1 || d > 7)) return null;
    }
    if ((startMinute == null) != (endMinute == null)) return null;
    if (startMinute != null) {
      if (days == null) return null;
      if (startMinute < 0 || endMinute! > 24 * 60) return null;
      if (endMinute <= startMinute) return null;
    }
    if (dayOnly == null && days == null) return null;
    return TimeContext._(
      fromDate: dayOnly,
      days: days == null ? null : Set.unmodifiable(days),
      startMinute: startMinute,
      endMinute: endMinute,
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _clock(int minuteOfDay) =>
      '${_two(minuteOfDay ~/ 60)}:${_two(minuteOfDay % 60)}';
  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

  /// The canonical JSON text. Fixed key order `from, days, start, end`, absent
  /// keys omitted, so two devices writing the same value write the same bytes.
  String encode() {
    final from = fromDate;
    final days = this.days;
    final start = startMinute;
    final end = endMinute;
    return jsonEncode(<String, Object?>{
      'from': ?(from == null ? null : _date(from)),
      'days': ?(days == null ? null : (days.toList()..sort())),
      'start': ?(start == null ? null : _clock(start)),
      'end': ?(end == null ? null : _clock(end)),
    });
  }

  static final _datePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
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

  /// Parses a stored value. Null for null, blank or anything that is not a valid
  /// canonical shape (unknown key, bad date, empty days, lone start/end, …) — a
  /// value the app cannot read must never hide an Outcome.
  static TimeContext? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    const known = {'from', 'days', 'start', 'end'};
    if (decoded.keys.any((k) => !known.contains(k))) return null;

    DateTime? from;
    final rawFrom = decoded['from'];
    if (decoded.containsKey('from')) {
      if (rawFrom is! String) return null;
      final m = _datePattern.firstMatch(rawFrom);
      if (m == null) return null;
      final y = int.parse(m.group(1)!);
      final mo = int.parse(m.group(2)!);
      final d = int.parse(m.group(3)!);
      from = DateTime(y, mo, d);
      if (from.year != y || from.month != mo || from.day != d) return null;
    }

    Set<int>? days;
    if (decoded.containsKey('days')) {
      final rawDays = decoded['days'];
      if (rawDays is! List || rawDays.any((d) => d is! int)) return null;
      days = rawDays.cast<int>().toSet();
      if (days.length != rawDays.length) return null;
    }

    int? start;
    int? end;
    if (decoded.containsKey('start')) {
      start = _parseClock(decoded['start']);
      if (start == null) return null;
    }
    if (decoded.containsKey('end')) {
      end = _parseClock(decoded['end']);
      if (end == null) return null;
    }
    return create(
        fromDate: from, days: days, startMinute: start, endMinute: end);
  }

  /// Whether the Action can be done at [now] (read in local time).
  bool isSatisfiedAt(DateTime now) {
    final local = now.toLocal();
    if (fromDate != null &&
        DateTime(local.year, local.month, local.day).isBefore(fromDate!)) {
      return false;
    }
    final days = this.days;
    if (days != null) {
      if (!days.contains(local.weekday)) return false;
      if (startMinute != null) {
        final minuteOfDay = local.hour * 60 + local.minute;
        if (minuteOfDay < startMinute! || minuteOfDay >= endMinute!) {
          return false;
        }
      }
    }
    return true;
  }

  /// The earliest instant after [now] at which [isSatisfiedAt] can change, or
  /// null when it cannot (a `from` already passed with no weekly window).
  DateTime? nextTransitionAfter(DateTime now) {
    final local = now.toLocal();
    final from = fromDate;
    if (from != null && from.isAfter(local)) return from;
    if (days == null) return null;
    DateTime at(DateTime day, int minuteOfDay) =>
        DateTime(day.year, day.month, day.day, 0, minuteOfDay);
    DateTime? best;
    for (var offset = 0; offset <= 8; offset++) {
      final day = DateTime(local.year, local.month, local.day + offset);
      if (!days!.contains(day.weekday)) continue;
      final candidates = startMinute == null
          ? [at(day, 0), at(DateTime(day.year, day.month, day.day + 1), 0)]
          : [at(day, startMinute!), at(day, endMinute!)];
      for (final c in candidates) {
        if (c.isAfter(local) && (best == null || c.isBefore(best))) best = c;
      }
      if (best != null) break;
    }
    return best;
  }

  static const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// Chip text, e.g. `From 30 Nov · Tue, Thu 09:00–17:00`.
  String describe() {
    final parts = <String>[];
    if (fromDate != null) {
      parts.add('From ${fromDate!.day} ${_monthNames[fromDate!.month - 1]}');
    }
    if (days != null) {
      final sorted = days!.toList()..sort();
      final names = sorted.length == 7
          ? 'Every day'
          : sorted.map((d) => _dayNames[d - 1]).join(', ');
      final window = startMinute == null
          ? ''
          : ' ${_clock(startMinute!)}–${_clock(endMinute!)}';
      parts.add('$names$window');
    }
    return parts.join(' · ');
  }

  @override
  bool operator ==(Object other) =>
      other is TimeContext && other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;

  @override
  String toString() => 'TimeContext(${encode()})';
}
