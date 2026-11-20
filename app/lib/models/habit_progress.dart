/// The streak engine's first half: which commitment judges which days, and how
/// each judged unit (a due day, a week or a month) turned out.
///
/// The engine is pure. It reads a [HabitHistory] (rows the caller already
/// loaded) and a `today`, and never touches the database or the clock.
/// Every day is a UTC calendar day (see `habit_days.dart`).
library;

import '../database/gtd_database.dart'
    show Habit, HabitCheckIn, HabitInactivePeriod;
import 'habit_commitment.dart';
import 'habit_days.dart';

/// Everything the engine needs to know about one Habit.
class HabitHistory {
  HabitHistory({
    required this.habit,
    required Iterable<HabitCommitment> commitments,
    Iterable<HabitInactivePeriod> inactivePeriods = const [],
    Iterable<HabitCheckIn> checkIns = const [],
  })  : commitments = List.unmodifiable(commitments),
        inactivePeriods = List.unmodifiable(inactivePeriods),
        checkIns = List.unmodifiable(checkIns);

  /// The Habit row.
  final Habit habit;

  /// Every commitment the Habit has ever had.
  final List<HabitCommitment> commitments;

  /// Its paused and archived stretches.
  final List<HabitInactivePeriod> inactivePeriods;

  /// Its Check-ins, on any day.
  final List<HabitCheckIn> checkIns;
}

/// A maximal range of consecutive days judged by one commitment.
class HabitCommitmentRun {
  const HabitCommitmentRun({
    required this.commitment,
    required this.firstDay,
    required this.lastDay,
  });

  /// The commitment in force on every day of the run.
  final HabitCommitment commitment;

  /// The first day, a UTC calendar day.
  final DateTime firstDay;

  /// The last day, a UTC calendar day, included.
  final DateTime lastDay;

  @override
  String toString() =>
      'HabitCommitmentRun(${commitment.id}, $firstDay..$lastDay)';
}

/// What a judged unit is: a due day, a week or a month.
enum HabitUnitKind { day, week, month }

/// How a judged unit turned out.
enum HabitUnitResult {
  /// A due day that was achieved.
  done,

  /// A week or month that reached its count (or, when partial, reached N).
  met,

  /// A finished unit that was not achieved.
  missed,

  /// Not judged: an inactive day, or a partial period that fell short.
  skipped,

  /// The day or period that contains today and is not yet achieved.
  inProgress,
}

/// One judged unit of a Habit.
class HabitJudgedUnit {
  const HabitJudgedUnit({
    required this.kind,
    required this.firstDay,
    required this.lastDay,
    required this.commitment,
    required this.result,
    this.count,
    this.isPartial = false,
  });

  final HabitUnitKind kind;

  /// The first day of the unit, clipped to its run and to the first judged
  /// day. A UTC calendar day.
  final DateTime firstDay;

  /// The last day of the unit, clipped likewise, included.
  final DateTime lastDay;

  /// The commitment that judges the unit.
  final HabitCommitment commitment;

  final HabitUnitResult result;

  /// For a week or month: Check-ins in the span (binary) or days that reached
  /// the target (measurable). Null for a day.
  final int? count;

  /// Whether a week or month is clipped, or contains an inactive day.
  final bool isPartial;

  @override
  String toString() =>
      'HabitJudgedUnit($kind $firstDay..$lastDay ${result.name}'
      '${count == null ? '' : ' count=$count'}${isPartial ? ' partial' : ''})';
}

DateTime _utcDay(DateTime date) => DateTime.utc(date.year, date.month, date.day);

DateTime _nextDay(DateTime day) => DateTime.utc(day.year, day.month, day.day + 1);

DateTime _later(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

DateTime _earlier(DateTime a, DateTime b) => a.isBefore(b) ? a : b;

/// The first day that is judged: the earliest `chosenOn`, or null when there
/// is no commitment.
DateTime? _firstJudgedDay(List<HabitCommitment> commitments) {
  DateTime? first;
  for (final commitment in commitments) {
    final day = parseHabitDay(commitment.chosenOn);
    if (day == null) continue;
    if (first == null || day.isBefore(first)) first = day;
  }
  return first;
}

/// The commitment runs from the first judged day to [today].
///
/// Empty when the Habit has no commitment, or its first day is after today.
List<HabitCommitmentRun> commitmentRuns(HabitHistory history, DateTime today) {
  final lastDay = _utcDay(today);
  final firstDay = _firstJudgedDay(history.commitments);
  if (firstDay == null || firstDay.isAfter(lastDay)) return const [];

  final runs = <HabitCommitmentRun>[];
  HabitCommitment? runCommitment;
  DateTime? runFirstDay;
  DateTime? runLastDay;
  for (var day = firstDay; !day.isAfter(lastDay); day = _nextDay(day)) {
    final inForce = commitmentInForceOn(history.commitments, habitDayKey(day));
    if (inForce == null) continue;
    if (runCommitment != null && runCommitment.id == inForce.id) {
      runLastDay = day;
      continue;
    }
    if (runCommitment != null) {
      runs.add(HabitCommitmentRun(
          commitment: runCommitment,
          firstDay: runFirstDay!,
          lastDay: runLastDay!));
    }
    runCommitment = inForce;
    runFirstDay = day;
    runLastDay = day;
  }
  if (runCommitment != null) {
    runs.add(HabitCommitmentRun(
        commitment: runCommitment,
        firstDay: runFirstDay!,
        lastDay: runLastDay!));
  }
  return runs;
}

/// Whether a paused or archived period covers the day with [dayKey].
bool _isInactiveOn(List<HabitInactivePeriod> periods, String dayKey) {
  for (final period in periods) {
    if (period.startsOn.compareTo(dayKey) > 0) continue;
    final endsBefore = period.endsBefore;
    if (endsBefore == null || dayKey.compareTo(endsBefore) < 0) return true;
  }
  return false;
}

/// Judges every unit of the Habit from its first day to [today], oldest first.
///
/// Days after [today] are not judged. See the streak engine plan, §6.2.
List<HabitJudgedUnit> judgeUnits(HabitHistory history, DateTime today) {
  final todayDay = _utcDay(today);
  final runs = commitmentRuns(history, todayDay);
  if (runs.isEmpty) return const [];

  // Check-ins grouped by the day they count for.
  final checkInsByDay = <String, List<HabitCheckIn>>{};
  for (final checkIn in history.checkIns) {
    (checkInsByDay[checkIn.countsForDay] ??= []).add(checkIn);
  }

  bool inactive(DateTime day) =>
      _isInactiveOn(history.inactivePeriods, habitDayKey(day));

  // Whether the day is achieved under [commitment]: any Check-in for a binary
  // day, the target reached for a measurable one.
  bool achieved(HabitCommitment commitment, DateTime day) {
    final onDay = checkInsByDay[habitDayKey(day)] ?? const [];
    if (!commitment.isMeasurable) return onDay.isNotEmpty;
    var total = 0.0;
    for (final checkIn in onDay) {
      total += checkIn.measuredAmount ?? 0;
    }
    return total >= commitment.dailyTargetAmount!;
  }

  final units = <HabitJudgedUnit>[];
  for (final run in runs) {
    final commitment = run.commitment;
    final isWeekly = commitment.repeatKind == HabitRepeatKind.timesPerWeek;
    final isMonthly = commitment.repeatKind == HabitRepeatKind.timesPerMonth;

    if (!isWeekly && !isMonthly) {
      for (var day = run.firstDay;
          !day.isAfter(run.lastDay);
          day = _nextDay(day)) {
        if (!isDueOn(commitment, day)) continue;
        final HabitUnitResult result;
        if (inactive(day)) {
          result = HabitUnitResult.skipped;
        } else if (achieved(commitment, day)) {
          result = HabitUnitResult.done;
        } else if (day == todayDay) {
          result = HabitUnitResult.inProgress;
        } else {
          result = HabitUnitResult.missed;
        }
        units.add(HabitJudgedUnit(
          kind: HabitUnitKind.day,
          firstDay: day,
          lastDay: day,
          commitment: commitment,
          result: result,
        ));
      }
      continue;
    }

    // Each week or month that overlaps the run, clipped to it.
    var cursor = run.firstDay;
    while (!cursor.isAfter(run.lastDay)) {
      final fullSpan = periodSpan(commitment, cursor)!;
      final firstDay = _later(fullSpan.start, run.firstDay);
      final lastDay = _earlier(fullSpan.end, run.lastDay);
      cursor = _nextDay(fullSpan.end);

      var count = 0;
      var hasInactiveDay = false;
      for (var day = firstDay; !day.isAfter(lastDay); day = _nextDay(day)) {
        if (inactive(day)) {
          hasInactiveDay = true;
          continue;
        }
        if (commitment.isMeasurable) {
          if (achieved(commitment, day)) count++;
        } else {
          count += (checkInsByDay[habitDayKey(day)] ?? const []).length;
        }
      }

      // Open only while the unit runs up to today; a unit cut off by a later
      // commitment is finished even when its calendar week holds today.
      final containsToday = lastDay == todayDay;
      final isPartial = firstDay != fullSpan.start ||
          (lastDay != fullSpan.end && !containsToday) ||
          hasInactiveDay;
      final target = commitment.timesPerPeriod!;
      final HabitUnitResult result;
      if (containsToday) {
        result = HabitUnitResult.inProgress;
      } else if (count >= target) {
        result = HabitUnitResult.met;
      } else {
        result = isPartial ? HabitUnitResult.skipped : HabitUnitResult.missed;
      }
      units.add(HabitJudgedUnit(
        kind: isWeekly ? HabitUnitKind.week : HabitUnitKind.month,
        firstDay: firstDay,
        lastDay: lastDay,
        commitment: commitment,
        result: result,
        count: count,
        isPartial: isPartial,
      ));
    }
  }
  return units;
}
