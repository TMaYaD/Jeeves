/// Day and period arithmetic for Habits.
///
/// A day is a UTC calendar day (`DateTime.utc(y, m, d)`, midnight): never a
/// local `DateTime`, so a clock change cannot make a day 23 or 25 hours long
/// or shift it to its neighbour. The day key (`YYYY-MM-DD`) is the stored form
/// and `habitDayKey` / `effectiveStartOf` in `habit_commitment.dart` own the
/// rest of the vocabulary; this file adds only what the streak engine needs on
/// top of them.
library;

import 'habit_commitment.dart';

/// The UTC calendar day of [dayKey], or null when it is not `YYYY-MM-DD`.
///
/// The inverse of `habitDayKey`.
DateTime? parseHabitDay(String dayKey) {
  final local = habitDateFromDayKey(dayKey);
  if (local == null) return null;
  return DateTime.utc(local.year, local.month, local.day);
}

/// The UTC calendar day with the same year, month and day as [date],
/// whatever its time zone or time of day.
DateTime _asUtcDay(DateTime date) => DateTime.utc(date.year, date.month, date.day);

/// The first day of the week [day] is in: the [habitWeekStartsOn] day.
DateTime weekStart(DateTime day) {
  final offset = (day.weekday - habitWeekStartsOn + 7) % 7;
  // Calendar arithmetic on the parts: DateTime.utc rolls a day below 1 into
  // the previous month.
  return DateTime.utc(day.year, day.month, day.day - offset);
}

/// The first day of the month [day] is in.
DateTime monthStart(DateTime day) => DateTime.utc(day.year, day.month);

/// Whole calendar days from [from] to [to], negative when [to] is earlier.
int _daysBetween(DateTime from, DateTime to) =>
    _asUtcDay(to).difference(_asUtcDay(from)).inDays;

/// Whether [commitment] makes [day] a due day.
///
/// Only the three day-based kinds have due days; a per-week or per-month
/// commitment is judged over a period (see [periodSpan]), so asking it throws
/// an [ArgumentError] rather than quietly answering "no".
///
/// A day before the commitment's effective start is not due.
bool isDueOn(HabitCommitment commitment, DateTime day) {
  final start = _asUtcDay(effectiveStartOf(commitment));
  final target = _asUtcDay(day);
  switch (commitment.repeatKind) {
    case HabitRepeatKind.everyDay:
      return !target.isBefore(start);
    case HabitRepeatKind.chosenWeekdays:
      return !target.isBefore(start) &&
          commitment.chosenWeekdays!.contains(target.weekday);
    case HabitRepeatKind.everyNDays:
      final elapsedDays = _daysBetween(start, target);
      return elapsedDays >= 0 && elapsedDays % commitment.intervalDays! == 0;
    case HabitRepeatKind.timesPerWeek:
    case HabitRepeatKind.timesPerMonth:
      throw ArgumentError.value(
          commitment.repeatKind,
          'commitment',
          'A per-week or per-month commitment has no due days; use periodSpan.');
  }
}

/// A run of consecutive days, [start] and [end] both included.
class HabitPeriodSpan {
  const HabitPeriodSpan({required this.start, required this.end});

  /// The first day, a UTC calendar day.
  final DateTime start;

  /// The last day, a UTC calendar day, included.
  final DateTime end;

  /// How many days the span holds.
  int get dayCount => _daysBetween(start, end) + 1;

  /// Whether [day] falls inside the span.
  bool contains(DateTime day) {
    final target = _asUtcDay(day);
    return !target.isBefore(start) && !target.isAfter(end);
  }

  @override
  bool operator ==(Object other) =>
      other is HabitPeriodSpan && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'HabitPeriodSpan($start..$end)';
}

/// The whole week or month of [commitment] that [day] is in, or null for a
/// day-based commitment.
///
/// The span is the full calendar week (Monday to Sunday) or month; clipping it
/// to a commitment run or to the first judged day is the engine's job.
HabitPeriodSpan? periodSpan(HabitCommitment commitment, DateTime day) {
  switch (commitment.repeatKind) {
    case HabitRepeatKind.timesPerWeek:
      final start = weekStart(day);
      return HabitPeriodSpan(
          start: start,
          end: DateTime.utc(start.year, start.month, start.day + 6));
    case HabitRepeatKind.timesPerMonth:
      // Day 0 of the next month is the last day of this one.
      return HabitPeriodSpan(
          start: monthStart(day),
          end: DateTime.utc(day.year, day.month + 1, 0));
    case HabitRepeatKind.everyDay:
    case HabitRepeatKind.chosenWeekdays:
    case HabitRepeatKind.everyNDays:
      return null;
  }
}
