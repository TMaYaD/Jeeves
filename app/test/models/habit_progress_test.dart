import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart'
    show Habit, HabitCheckIn, HabitInactivePeriod;
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/models/habit_progress.dart';

// Calendar used throughout: Monday 2026-11-02 starts a week; Monday
// 2026-11-16 is a week start too.
final habitRow = Habit(
  id: 'habit-1',
  userId: 'user-1',
  title: 'Read',
  anchorKind: 'none',
  createdAt: '2026-11-02T09:00:00.000Z',
);

var _sequence = 0;

HabitCommitment commitment({
  String id = 'c1',
  required String chosenOn,
  DateTime? createdAt,
  HabitRepeatKind repeatKind = HabitRepeatKind.everyDay,
  List<int>? chosenWeekdays,
  int? timesPerPeriod,
  int? intervalDays,
  String? unitLabel,
  double? dailyTargetAmount,
}) {
  return HabitCommitment(
    id: id,
    habitId: 'habit-1',
    chosenOn: chosenOn,
    createdAt: createdAt ?? DateTime.utc(2026, 11, 2, 9, 0, _sequence++),
    repeatKind: repeatKind,
    chosenWeekdays: chosenWeekdays,
    timesPerPeriod: timesPerPeriod,
    intervalDays: intervalDays,
    unitLabel: unitLabel,
    dailyTargetAmount: dailyTargetAmount,
  );
}

HabitCheckIn checkIn(String day, {double? amount}) => HabitCheckIn(
      id: 'ci-${_sequence++}',
      userId: 'user-1',
      habitId: 'habit-1',
      countsForDay: day,
      checkedInAt: '${day}T12:00:00.000Z',
      measuredAmount: amount,
    );

HabitInactivePeriod inactive(String kind, String startsOn, String? endsBefore) =>
    HabitInactivePeriod(
      id: 'ip-${_sequence++}',
      userId: 'user-1',
      habitId: 'habit-1',
      kind: kind,
      startsOn: startsOn,
      endsBefore: endsBefore,
    );

HabitHistory history(
  List<HabitCommitment> commitments, {
  List<HabitCheckIn> checkIns = const [],
  List<HabitInactivePeriod> inactivePeriods = const [],
}) =>
    HabitHistory(
      habit: habitRow,
      commitments: commitments,
      checkIns: checkIns,
      inactivePeriods: inactivePeriods,
    );

DateTime day(int month, int dayOfMonth) => DateTime.utc(2026, month, dayOfMonth);

List<HabitUnitResult> results(List<HabitJudgedUnit> units) =>
    [for (final unit in units) unit.result];


String key(int month, int dayOfMonth) =>
    '2026-${month.toString().padLeft(2, '0')}-${dayOfMonth.toString().padLeft(2, '0')}';

/// Check-ins on every day from [fromDay] to [toDay] (November), bar [except].
List<HabitCheckIn> everyDayCheckIns(int fromDay, int toDay,
        {Set<int> except = const {}}) =>
    [
      for (var d = fromDay; d <= toDay; d++)
        if (!except.contains(d)) checkIn(key(11, d)),
    ];

void main() {
  final today = day(11, 20); // a Friday

  group('streaks', () {
    test('an unfinished today does not break the streak (6.3)', () {
      final progress = computeHabitProgress(
          history([commitment(chosenOn: '2026-11-02')],
              checkIns: everyDayCheckIns(2, 19)),
          today);
      expect(progress.mainStreakKind, HabitUnitKind.day);
      expect(progress.currentStreak, 18);
      expect(progress.bestStreak, 18);
      expect(progress.brokenStreakLength, isNull);
      expect(progress.todayState, HabitTodayState.notYet);
    });

    test('a done today adds to the streak', () {
      final progress = computeHabitProgress(
          history([commitment(chosenOn: '2026-11-02')],
              checkIns: everyDayCheckIns(2, 20)),
          today);
      expect(progress.currentStreak, 19);
      expect(progress.todayState, HabitTodayState.done);
    });

    test('a miss ends the streak; best keeps the longer earlier run', () {
      final progress = computeHabitProgress(
          history([commitment(chosenOn: '2026-11-02')],
              checkIns: everyDayCheckIns(2, 19, except: {11, 17})),
          today);
      // Done 2-10 (9), miss 11, done 12-16 (5), miss 17, done 18-19 (2).
      expect(progress.currentStreak, 2);
      expect(progress.bestStreak, 9);
    });

    test('a pause skips days without breaking the streak (AC 4)', () {
      final progress = computeHabitProgress(
          history([commitment(chosenOn: '2026-11-02')],
              checkIns: everyDayCheckIns(2, 19, except: {10, 11, 12}),
              inactivePeriods: [inactive('paused', '2026-11-10', '2026-11-13')]),
          today);
      // 18 days, 3 of them paused and so not counted.
      expect(progress.currentStreak, 15);
      expect(progress.bestStreak, 15);
      expect(progress.brokenStreakLength, isNull);
    });

    test('a day streak counts done due days, across every_day then '
        'chosen_weekdays (6.3)', () {
      final progress = computeHabitProgress(
          history([
            commitment(id: 'daily', chosenOn: '2026-11-02'),
            commitment(
                id: 'weekdays',
                chosenOn: '2026-11-10',
                repeatKind: HabitRepeatKind.chosenWeekdays,
                chosenWeekdays: [DateTime.monday, DateTime.wednesday, DateTime.friday]),
          ], checkIns: [
            ...everyDayCheckIns(2, 9),
            checkIn(key(11, 11)),
            checkIn(key(11, 13)),
            checkIn(key(11, 16)),
            checkIn(key(11, 18)),
          ]),
          today);
      // 8 daily days, then Wed 11, Fri 13, Mon 16, Wed 18; Tue and Thu are
      // rest days. Friday 20 is still open.
      expect(progress.mainStreakKind, HabitUnitKind.day);
      expect(progress.currentStreak, 12);
      expect(progress.bestStreak, 12);
    });

    test('a streak resets across every_day then times_per_week (6.3)', () {
      final progress = computeHabitProgress(
          history([
            commitment(id: 'daily', chosenOn: '2026-11-02'),
            commitment(
                id: 'weekly',
                chosenOn: '2026-11-09',
                repeatKind: HabitRepeatKind.timesPerWeek,
                timesPerPeriod: 3),
          ], checkIns: [
            ...everyDayCheckIns(2, 8),
            checkIn(key(11, 9)),
            checkIn(key(11, 11)),
            checkIn(key(11, 13)),
            checkIn(key(11, 17)),
          ]),
          today);
      expect(progress.mainStreakKind, HabitUnitKind.week);
      // Week of the 9th met (3 of 3); the week of the 16th is still open.
      expect(progress.currentStreak, 1);
      expect(progress.bestStreak, 1);
      expect(progress.periodCount, 1);
      expect(progress.periodTarget, 3);
      expect(progress.todayState, HabitTodayState.notYet);
    });
  });

  group('broken streak', () {
    test('is the length the latest miss ended (6.4)', () {
      final progress = computeHabitProgress(
          history([commitment(chosenOn: '2026-11-02')],
              checkIns: everyDayCheckIns(2, 18)),
          today);
      // Yesterday (19) was missed after 17 done days; today is still open.
      expect(progress.currentStreak, 0);
      expect(progress.bestStreak, 17);
      expect(progress.brokenStreakLength, 17);
    });

    test('is null once a later unit is done', () {
      final progress = computeHabitProgress(
          history([commitment(chosenOn: '2026-11-02')],
              checkIns: everyDayCheckIns(2, 19, except: {19})),
          today);
      expect(progress.brokenStreakLength, 17);
      final recovered = computeHabitProgress(
          history([commitment(chosenOn: '2026-11-02')],
              checkIns: everyDayCheckIns(2, 20, except: {19})),
          today);
      expect(recovered.brokenStreakLength, isNull);
    });

    test('is null when no streak stood before the miss', () {
      final progress = computeHabitProgress(
          history([commitment(chosenOn: '2026-11-02')],
              checkIns: everyDayCheckIns(2, 10)),
          today);
      // 11-19 missed, but 11-18 was missed before it: run length was 0.
      expect(progress.brokenStreakLength, isNull);
    });

    test('is not reset by a skipped unit after the miss', () {
      final progress = computeHabitProgress(
          history([commitment(chosenOn: '2026-11-02')],
              checkIns: everyDayCheckIns(2, 16),
              inactivePeriods: [inactive('paused', '2026-11-18', '2026-11-20')]),
          today);
      // 17 missed after 15 done; 18 and 19 paused (skipped).
      expect(progress.brokenStreakLength, 15);
    });
  });

  group('rates', () {
    test('a day-based Habit uses 7, 30 and 90 days; done over done+missed '
        '(6.5)', () {
      final progress = computeHabitProgress(
          history([commitment(chosenOn: '2026-11-02')],
              checkIns: everyDayCheckIns(2, 19, except: {16})),
          today);
      expect([for (final rate in progress.rates) rate.windowLength],
          [7, 30, 90]);
      // Window 14..19: 5 done, 1 missed. Today is open and left out.
      expect(progress.rates[0].value, closeTo(5 / 6, 1e-9));
      expect(progress.rates[1].value, closeTo(17 / 18, 1e-9));
      expect(progress.rates[2].value, closeTo(17 / 18, 1e-9));
    });

    test('paused days are left out of the rate (AC 6)', () {
      final progress = computeHabitProgress(
          history([commitment(chosenOn: '2026-11-02')],
              checkIns: everyDayCheckIns(2, 19, except: {10, 11, 12}),
              inactivePeriods: [inactive('paused', '2026-11-10', '2026-11-13')]),
          today);
      expect(progress.rates[0].value, 1.0);
      expect(progress.rates[1].value, 1.0);
    });

    test('is null when there is nothing to count', () {
      final progress = computeHabitProgress(
          history([commitment(chosenOn: '2026-11-20')]), today);
      for (final rate in progress.rates) {
        expect(rate.value, isNull);
      }
      expect(progress.currentStreak, 0);
    });

    test('a weekly Habit uses finished weeks: sum of min(count, N) over '
        'sum of N', () {
      final progress = computeHabitProgress(
          history([
            commitment(
                chosenOn: '2026-11-02',
                repeatKind: HabitRepeatKind.timesPerWeek,
                timesPerPeriod: 3)
          ], checkIns: [
            checkIn(key(11, 2)),
            checkIn(key(11, 4)),
            checkIn(key(11, 6)),
            checkIn(key(11, 6)),
            checkIn(key(11, 10)),
          ]),
          today);
      expect([for (final rate in progress.rates) rate.windowLength],
          [4, 12, 26]);
      // Week of the 2nd: 4 check-ins, counts as 3 of 3. Week of the 9th: 1 of
      // 3. The open week of the 16th is left out.
      expect(progress.rates[0].value, closeTo(4 / 6, 1e-9));
      expect(progress.currentStreak, 0);
      expect(progress.bestStreak, 1);
    });
  });

  group('today', () {
    test('measurable: total, target, unit and over-target (6.6)', () {
      final progress = computeHabitProgress(
          history([
            commitment(
                chosenOn: '2026-11-02',
                unitLabel: 'pages',
                dailyTargetAmount: 10)
          ], checkIns: [
            checkIn(key(11, 20), amount: 8),
            checkIn(key(11, 20), amount: 5),
          ]),
          today);
      expect(progress.todayTotalAmount, 13);
      expect(progress.targetAmount, 10);
      expect(progress.unitLabel, 'pages');
      expect(progress.isOverTarget, isTrue);
      expect(progress.todayState, HabitTodayState.done);
    });

    test('measurable below the target is not done, and not over', () {
      final progress = computeHabitProgress(
          history([
            commitment(
                chosenOn: '2026-11-02',
                unitLabel: 'pages',
                dailyTargetAmount: 10)
          ], checkIns: [checkIn(key(11, 20), amount: 4)]),
          today);
      expect(progress.todayTotalAmount, 4);
      expect(progress.isOverTarget, isFalse);
      expect(progress.todayState, HabitTodayState.notYet);
    });

    test('a binary Habit exposes no amounts', () {
      final progress = computeHabitProgress(
          history([commitment(chosenOn: '2026-11-02')]), today);
      expect(progress.todayTotalAmount, isNull);
      expect(progress.targetAmount, isNull);
      expect(progress.unitLabel, isNull);
    });

    test('is paused when a pause covers today', () {
      final progress = computeHabitProgress(
          history([commitment(chosenOn: '2026-11-02')],
              inactivePeriods: [inactive('paused', '2026-11-19', null)]),
          today);
      expect(progress.todayState, HabitTodayState.paused);
    });

    test('is notDue on a rest day', () {
      final progress = computeHabitProgress(
          history([
            commitment(
                chosenOn: '2026-11-02',
                repeatKind: HabitRepeatKind.chosenWeekdays,
                chosenWeekdays: [DateTime.monday])
          ]),
          today);
      expect(progress.todayState, HabitTodayState.notDue);
    });

    test('a weekly Habit is notDue once its week is met, done with a '
        'Check-in today', () {
      final weekly = commitment(
          chosenOn: '2026-11-02',
          repeatKind: HabitRepeatKind.timesPerWeek,
          timesPerPeriod: 2);
      final met = computeHabitProgress(
          history([weekly],
              checkIns: [checkIn(key(11, 16)), checkIn(key(11, 17))]),
          today);
      expect(met.todayState, HabitTodayState.notDue);
      expect(met.periodCount, 2);
      final withToday = computeHabitProgress(
          history([weekly], checkIns: [checkIn(key(11, 16)), checkIn(key(11, 20))]),
          today);
      expect(withToday.todayState, HabitTodayState.done);
    });

    test('no commitment gives an empty progress', () {
      final progress = computeHabitProgress(history([]), today);
      expect(progress.currentStreak, 0);
      expect(progress.bestStreak, 0);
      expect(progress.todayState, HabitTodayState.notDue);
    });
  });
}
