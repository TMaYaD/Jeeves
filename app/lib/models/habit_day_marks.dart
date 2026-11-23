/// What one day of a Habit's history looks like: the state of the day, its
/// numbers against that day's own commitment, and whether the streak engine
/// counted it.
///
/// Pure, like the engine it reads. Which days are due and which were missed
/// comes only from `isDueOn` and `judgeUnits`; this file writes no due-day
/// rule of its own.
library;

import '../database/gtd_database.dart' show HabitCheckIn, HabitInactivePeriod;
import 'habit_commitment.dart';
import 'habit_days.dart';
import 'habit_progress.dart';

/// How a day is drawn.
enum HabitDayState {
  /// The day reached its target (a Check-in for a binary Habit, the total for
  /// a measurable one). Holds on a rest day and on a paused or archived day.
  done,

  /// A measurable day with some progress, below the target.
  partial,

  /// A due day that was judged missed.
  missed,

  /// Today, due and not achieved yet.
  openToday,

  /// Nothing is asked of the Habit on the day.
  notDue,

  /// A paused period covers the day.
  paused,

  /// An archived period covers the day.
  archived,

  /// The day is before the Habit's first judged day.
  beforeHabit,

  /// The day is after today.
  future,
}

/// The two ways a Habit is inactive.
enum HabitInactiveKind { paused, archived }

/// One day of a Habit's history.
class HabitDayMark {
  const HabitDayMark({
    required this.day,
    required this.state,
    this.checkIns = const [],
    this.totalAmount,
    this.targetAmount,
    this.unitLabel,
    this.commitmentStartsHere = false,
    this.counted = true,
  });

  /// The day, a UTC calendar day.
  final DateTime day;

  final HabitDayState state;

  /// The Check-ins that count for the day, for the day sheet.
  final List<HabitCheckIn> checkIns;

  /// The number of Check-ins on the day.
  int get checkInCount => checkIns.length;

  /// For a day judged by a measurable commitment: the total of its Check-ins.
  /// Null when the day's commitment is binary or the day is not judged.
  final double? totalAmount;

  /// The target of the day's own commitment, or null for a binary day.
  final double? targetAmount;

  /// The unit of [targetAmount], or null for a binary day.
  final String? unitLabel;

  /// Whether a new repeat rule or target starts to apply on this day.
  final bool commitmentStartsHere;

  /// False when the streak engine left the day out: a rest day or an inactive
  /// day. A `done` mark that is not counted still shows what happened.
  final bool counted;

  @override
  String toString() =>
      'HabitDayMark(${habitDayKey(day)} ${state.name}'
      '${counted ? '' : ' uncounted'}${commitmentStartsHere ? ' starts' : ''})';
}

/// Which inactive period covers [day], or null when the Habit is live then.
///
/// A period covers the day when `startsOn <= day` and (`endsBefore` is null or
/// `day < endsBefore`). Archived wins over paused.
HabitInactiveKind? inactiveKindOn(
    Iterable<HabitInactivePeriod> periods, DateTime day) {
  final dayKey = habitDayKey(day);
  HabitInactiveKind? kind;
  for (final period in periods) {
    if (period.startsOn.compareTo(dayKey) > 0) continue;
    final endsBefore = period.endsBefore;
    if (endsBefore != null && dayKey.compareTo(endsBefore) >= 0) continue;
    if (period.kind == 'archived') return HabitInactiveKind.archived;
    if (period.kind == 'paused') kind = HabitInactiveKind.paused;
  }
  return kind;
}

/// Whether two commitments differ in repeat rule or target. The preferred
/// days are a hint and do not count.
bool _rulesDiffer(HabitCommitment a, HabitCommitment b) =>
    a.repeatKind != b.repeatKind ||
    a.timesPerPeriod != b.timesPerPeriod ||
    a.intervalDays != b.intervalDays ||
    a.unitLabel != b.unitLabel ||
    a.dailyTargetAmount != b.dailyTargetAmount ||
    !_sameList(a.chosenWeekdays, b.chosenWeekdays);

bool _sameList(List<int>? a, List<int>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

double _settled(double total) => (total * 1e6).round() / 1e6;

/// One [HabitDayMark] for each day from [fromDay] to [toDay], both included.
///
/// Empty when [toDay] is before [fromDay].
List<HabitDayMark> habitDayMarks(
  HabitHistory history,
  DateTime today,
  DateTime fromDay,
  DateTime toDay,
) {
  final todayDay = DateTime.utc(today.year, today.month, today.day);
  final first = DateTime.utc(fromDay.year, fromDay.month, fromDay.day);
  final last = DateTime.utc(toDay.year, toDay.month, toDay.day);
  if (last.isBefore(first)) return const [];

  final runs = commitmentRuns(history, todayDay);
  final firstJudgedDay = runs.isEmpty ? null : runs.first.firstDay;

  final missedDays = <DateTime>{
    for (final unit in judgeUnits(history, todayDay))
      if (unit.kind == HabitUnitKind.day &&
          unit.result == HabitUnitResult.missed)
        unit.firstDay,
  };
  final changeDays = <DateTime>{
    for (var i = 1; i < runs.length; i++)
      if (_rulesDiffer(runs[i - 1].commitment, runs[i].commitment))
        runs[i].firstDay,
  };
  final checkInsByDay = <String, List<HabitCheckIn>>{};
  for (final checkIn in history.checkIns) {
    (checkInsByDay[checkIn.countsForDay] ??= []).add(checkIn);
  }

  final marks = <HabitDayMark>[];
  var runIndex = 0;
  for (var day = first;
      !day.isAfter(last);
      day = DateTime.utc(day.year, day.month, day.day + 1)) {
    if (firstJudgedDay == null || day.isBefore(firstJudgedDay)) {
      marks.add(HabitDayMark(day: day, state: HabitDayState.beforeHabit));
      continue;
    }
    if (day.isAfter(todayDay)) {
      marks.add(HabitDayMark(day: day, state: HabitDayState.future));
      continue;
    }

    // Runs are in order and cover every day from the first judged day.
    while (runs[runIndex].lastDay.isBefore(day)) {
      runIndex++;
    }
    final commitment = runs[runIndex].commitment;
    final onDay = checkInsByDay[habitDayKey(day)] ?? const <HabitCheckIn>[];
    final measurable = commitment.isMeasurable;
    var total = 0.0;
    for (final checkIn in onDay) {
      total += checkIn.measuredAmount ?? 0;
    }
    total = _settled(total);
    final target = commitment.dailyTargetAmount;
    final reached = measurable ? total >= target! : onDay.isNotEmpty;

    final inactive = inactiveKindOn(history.inactivePeriods, day);
    final dayBased = commitment.repeatKind != HabitRepeatKind.timesPerWeek &&
        commitment.repeatKind != HabitRepeatKind.timesPerMonth;
    final due = dayBased && isDueOn(commitment, day);

    final HabitDayState state;
    if (reached) {
      state = HabitDayState.done;
    } else if (inactive != null) {
      state = inactive == HabitInactiveKind.archived
          ? HabitDayState.archived
          : HabitDayState.paused;
    } else if (measurable && total > 0) {
      state = HabitDayState.partial;
    } else if (due) {
      state = missedDays.contains(day)
          ? HabitDayState.missed
          : day == todayDay
              ? HabitDayState.openToday
              : HabitDayState.notDue;
    } else {
      state = HabitDayState.notDue;
    }

    marks.add(HabitDayMark(
      day: day,
      state: state,
      checkIns: onDay,
      totalAmount: measurable ? total : null,
      targetAmount: target,
      unitLabel: commitment.unitLabel,
      commitmentStartsHere: changeDays.contains(day),
      counted: inactive == null && (!dayBased || due),
    ));
  }
  return marks;
}
