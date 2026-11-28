/// Whether a Habit is for a given day — the one rule the Habit notification
/// and the arrival notification share, so the two cannot disagree.
library;

import '../database/gtd_database.dart' show HabitInactivePeriod;
import 'habit_commitment.dart';
import 'habit_days.dart';
import 'habit_progress.dart';

/// Whether an inactive period covers the day with [dayKey].
///
/// A period covers a day from its first day up to — but not including — the
/// day the Habit is active again.
bool isHabitInactiveOn(List<HabitInactivePeriod> periods, String dayKey) {
  for (final period in periods) {
    if (period.startsOn.compareTo(dayKey) > 0) continue;
    final endsBefore = period.endsBefore;
    if (endsBefore == null || dayKey.compareTo(endsBefore) < 0) return true;
  }
  return false;
}

/// Whether [history]'s Habit is still for [day].
///
/// A paused or archived Habit is for no day it covers. Today the streak
/// engine's own answer decides: done, not due and paused do not count. A later
/// day is judged by the commitment in force then — due for the day-based
/// kinds, and its period not yet met for the per-week and per-month ones.
/// [todayProgress] is [history]'s progress on [today]; both days are UTC
/// calendar days.
bool isHabitForDay(
  HabitHistory history,
  HabitProgress todayProgress, {
  required DateTime day,
  required DateTime today,
}) {
  final dayKey = habitDayKey(day);
  if (isHabitInactiveOn(history.inactivePeriods, dayKey)) return false;
  if (day == today) {
    return todayProgress.todayState == HabitTodayState.notYet;
  }
  // A Check-in already made for that day means the day is done.
  for (final checkIn in history.checkIns) {
    if (checkIn.countsForDay == dayKey) return false;
  }
  final commitment = commitmentInForceOn(history.commitments, dayKey);
  if (commitment == null) return false;
  switch (commitment.repeatKind) {
    case HabitRepeatKind.everyDay:
    case HabitRepeatKind.chosenWeekdays:
    case HabitRepeatKind.everyNDays:
      return isDueOn(commitment, day);
    case HabitRepeatKind.timesPerWeek:
    case HabitRepeatKind.timesPerMonth:
      return _periodStillOpen(todayProgress, commitment, day, today);
  }
}

/// Whether a per-week or per-month Habit's period is still open on [day].
///
/// The period is open while the Habit has not reached N yet. A day in a later
/// period than today's is open — nothing has been done in it yet — and a day
/// in today's period is open while today's count is below N.
bool _periodStillOpen(
  HabitProgress todayProgress,
  HabitCommitment commitment,
  DateTime day,
  DateTime today,
) {
  final target = commitment.timesPerPeriod;
  if (target == null) return false;
  final span = periodSpan(commitment, day);
  if (span == null) return false;
  final todaySpan = periodSpan(commitment, today);
  if (todaySpan == null) return false;
  if (span.start.isAfter(todaySpan.start)) return true;
  if (span.start.isBefore(todaySpan.start)) return false;
  final count = todayProgress.periodCount ?? 0;
  return count < target;
}
