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

void main() {
  group('commitmentRuns', () {
    test('is empty without a commitment, or before the first day', () {
      expect(commitmentRuns(history([]), day(11, 20)), isEmpty);
      expect(
          commitmentRuns(
              history([commitment(chosenOn: '2026-11-25')]), day(11, 20)),
          isEmpty);
    });

    test('is one run from the creation day to today', () {
      final runs = commitmentRuns(
          history([commitment(chosenOn: '2026-11-02')]), day(11, 20));
      expect(runs, hasLength(1));
      expect(runs.single.firstDay, day(11, 2));
      expect(runs.single.lastDay, day(11, 20));
    });

    test('starts at the creation day, not the Monday of a weekly start', () {
      // Wednesday 2026-11-04: the weekly effective start is Monday the 2nd.
      final runs = commitmentRuns(
          history([
            commitment(
                chosenOn: '2026-11-04',
                repeatKind: HabitRepeatKind.timesPerWeek,
                timesPerPeriod: 3)
          ]),
          day(11, 20));
      expect(runs.single.firstDay, day(11, 4));
    });

    test('splits where a newer commitment takes over, and agrees with '
        'commitmentInForceOn on every day', () {
      final weekly = commitment(
          id: 'weekly',
          chosenOn: '2026-11-02',
          repeatKind: HabitRepeatKind.timesPerWeek,
          timesPerPeriod: 3);
      // Thursday 5th: a daily commitment governs from Thursday.
      final daily = commitment(id: 'daily', chosenOn: '2026-11-05');
      // Wednesday 11th: a weekly change governs from Monday the 9th.
      final weeklyFour = commitment(
          id: 'weekly4',
          chosenOn: '2026-11-11',
          repeatKind: HabitRepeatKind.timesPerWeek,
          timesPerPeriod: 4);
      final all = [weekly, daily, weeklyFour];
      final runs = commitmentRuns(history(all), day(11, 20));
      expect([for (final r in runs) r.commitment.id],
          ['weekly', 'daily', 'weekly4']);

      for (var d = day(11, 2); !d.isAfter(day(11, 20)); d = DateTime.utc(d.year, d.month, d.day + 1)) {
        final run = runs.singleWhere(
            (r) => !d.isBefore(r.firstDay) && !d.isAfter(r.lastDay));
        expect(run.commitment, commitmentInForceOn(all, habitDayKey(d)),
            reason: '$d');
      }
    });
  });

  group('judgeUnits: day-based kinds', () {
    test('every day: a Check-in is done, none is missed, today is in progress',
        () {
      final units = judgeUnits(
          history([commitment(chosenOn: '2026-11-16')], checkIns: [
            checkIn('2026-11-16'),
            checkIn('2026-11-18'),
          ]),
          day(11, 19));
      expect(units, hasLength(4));
      expect(results(units), [
        HabitUnitResult.done,
        HabitUnitResult.missed,
        HabitUnitResult.done,
        HabitUnitResult.inProgress,
      ]);
    });

    test('today with a Check-in is done', () {
      final units = judgeUnits(
          history([commitment(chosenOn: '2026-11-19')],
              checkIns: [checkIn('2026-11-19')]),
          day(11, 19));
      expect(results(units), [HabitUnitResult.done]);
    });

    test('chosen weekdays: only those days are units', () {
      // Mon 16 .. Sun 22; Mon, Wed, Fri.
      final units = judgeUnits(
          history([
            commitment(
                chosenOn: '2026-11-16',
                repeatKind: HabitRepeatKind.chosenWeekdays,
                chosenWeekdays: [1, 3, 5])
          ], checkIns: [
            checkIn('2026-11-16'),
            checkIn('2026-11-17'), // a rest day: ignored
          ]),
          day(11, 22));
      expect([for (final u in units) u.firstDay],
          [day(11, 16), day(11, 18), day(11, 20)]);
      expect(results(units),
          [HabitUnitResult.done, HabitUnitResult.missed, HabitUnitResult.missed]);
    });

    test('every 3 days: due on fixed days from the effective start', () {
      // Wednesday 2026-11-04, then 7, 10, 13.
      final units = judgeUnits(
          history([
            commitment(
                chosenOn: '2026-11-04',
                repeatKind: HabitRepeatKind.everyNDays,
                intervalDays: 3)
          ], checkIns: [
            checkIn('2026-11-07'),
          ]),
          day(11, 13));
      expect([for (final u in units) u.firstDay],
          [day(11, 4), day(11, 7), day(11, 10), day(11, 13)]);
      expect(results(units), [
        HabitUnitResult.missed,
        HabitUnitResult.done,
        HabitUnitResult.missed,
        HabitUnitResult.inProgress,
      ]);
    });

    test('a measurable day adds up its Check-ins to the target', () {
      final measurable = commitment(
          chosenOn: '2026-11-16',
          unitLabel: 'pages',
          dailyTargetAmount: 8);
      final units = judgeUnits(
          history([measurable], checkIns: [
            checkIn('2026-11-16', amount: 5),
            checkIn('2026-11-16', amount: 3), // 8: done
            checkIn('2026-11-17', amount: 5),
            checkIn('2026-11-17', amount: 2), // 7: missed
          ]),
          day(11, 18));
      expect(results(units), [
        HabitUnitResult.done,
        HabitUnitResult.missed,
        HabitUnitResult.inProgress,
      ]);
    });

    test('an inactive day is skipped, paused or archived, and a restored '
        'range ends before its end day', () {
      final units = judgeUnits(
          history([
            commitment(chosenOn: '2026-11-16')
          ], inactivePeriods: [
            inactive('paused', '2026-11-17', '2026-11-18'),
            inactive('archived', '2026-11-19', '2026-11-21'),
          ], checkIns: [
            checkIn('2026-11-17'), // on a paused day: still skipped
          ]),
          day(11, 21));
      expect(results(units), [
        HabitUnitResult.missed, // 16
        HabitUnitResult.skipped, // 17
        HabitUnitResult.missed, // 18
        HabitUnitResult.skipped, // 19
        HabitUnitResult.skipped, // 20
        HabitUnitResult.inProgress, // 21
      ]);
    });

    test('an open archived period skips every later day', () {
      final units = judgeUnits(
          history([commitment(chosenOn: '2026-11-16')],
              inactivePeriods: [inactive('archived', '2026-11-17', null)]),
          day(11, 19));
      expect(results(units), [
        HabitUnitResult.missed,
        HabitUnitResult.skipped,
        HabitUnitResult.skipped,
        HabitUnitResult.skipped,
      ]);
    });

    test('days after today are not judged', () {
      final units = judgeUnits(
          history([commitment(chosenOn: '2026-11-16')]), day(11, 16));
      expect(units, hasLength(1));
    });
  });

  group('judgeUnits: period-based kinds', () {
    HabitCommitment weekly(String chosenOn, {int n = 3, String id = 'w'}) =>
        commitment(
            id: id,
            chosenOn: chosenOn,
            repeatKind: HabitRepeatKind.timesPerWeek,
            timesPerPeriod: n);

    test('several binary Check-ins in one week count each (no day limit)', () {
      final units = judgeUnits(
          history([weekly('2026-11-02')], checkIns: [
            checkIn('2026-11-02'),
            checkIn('2026-11-02'),
            checkIn('2026-11-03'),
          ]),
          day(11, 15));
      // Week of 2nd finished: 3 Check-ins of 3. Week of 9th in progress? No:
      // today is Sunday the 15th, inside the week of the 9th.
      expect(units, hasLength(2));
      expect(units[0].result, HabitUnitResult.met);
      expect(units[0].count, 3);
      expect(units[0].isPartial, isFalse);
      expect(units[1].result, HabitUnitResult.inProgress);
      expect(units[1].count, 0);
    });

    test('a finished full week short of N is missed', () {
      final units = judgeUnits(
          history([weekly('2026-11-02')],
              checkIns: [checkIn('2026-11-02'), checkIn('2026-11-04')]),
          day(11, 10));
      expect(units[0].result, HabitUnitResult.missed);
      expect(units[0].count, 2);
    });

    test('the creation week is partial: met at N, otherwise skipped', () {
      // Created Thursday 5th.
      final short = judgeUnits(
          history([weekly('2026-11-05')], checkIns: [checkIn('2026-11-05')]),
          day(11, 10));
      expect(short.first.firstDay, day(11, 5));
      expect(short.first.lastDay, day(11, 8));
      expect(short.first.isPartial, isTrue);
      expect(short.first.result, HabitUnitResult.skipped);

      final enough = judgeUnits(
          history([
            weekly('2026-11-05')
          ], checkIns: [
            checkIn('2026-11-05'),
            checkIn('2026-11-06'),
            checkIn('2026-11-07'),
          ]),
          day(11, 10));
      expect(enough.first.result, HabitUnitResult.met);
    });

    test('a paused range inside a week makes it partial', () {
      final units = judgeUnits(
          history([weekly('2026-11-02')],
              inactivePeriods: [inactive('paused', '2026-11-04', '2026-11-06')],
              checkIns: [
                checkIn('2026-11-02'),
                checkIn('2026-11-04'), // paused day: ignored
              ]),
          day(11, 10));
      expect(units.first.isPartial, isTrue);
      expect(units.first.count, 1);
      expect(units.first.result, HabitUnitResult.skipped);
    });

    test('an archived-then-restored range inside a week is skipped, not '
        'missed (decision 10)', () {
      final units = judgeUnits(
          history([weekly('2026-11-02')],
              inactivePeriods: [inactive('archived', '2026-11-03', '2026-11-09')]),
          day(11, 10));
      expect(units.first.result, HabitUnitResult.skipped);
    });

    test('a measurable weekly Habit counts the days that reach the target',
        () {
      final measurable = commitment(
          chosenOn: '2026-11-02',
          repeatKind: HabitRepeatKind.timesPerWeek,
          timesPerPeriod: 2,
          unitLabel: 'km',
          dailyTargetAmount: 5);
      final units = judgeUnits(
          history([
            measurable
          ], checkIns: [
            checkIn('2026-11-02', amount: 3),
            checkIn('2026-11-02', amount: 2), // 5: a day that counts
            checkIn('2026-11-03', amount: 4), // short
            checkIn('2026-11-04', amount: 9), // counts
          ]),
          day(11, 10));
      expect(units.first.count, 2);
      expect(units.first.result, HabitUnitResult.met);
    });

    test('times per month: a calendar month is one unit', () {
      final monthly = commitment(
          chosenOn: '2026-10-01',
          repeatKind: HabitRepeatKind.timesPerMonth,
          timesPerPeriod: 2);
      final units = judgeUnits(
          history([
            monthly
          ], checkIns: [
            checkIn('2026-10-03'),
            checkIn('2026-10-20'),
            checkIn('2026-11-02'),
          ]),
          day(11, 10));
      expect(units, hasLength(2));
      expect(units[0].kind, HabitUnitKind.month);
      expect(units[0].result, HabitUnitResult.met);
      expect(units[0].isPartial, isFalse);
      expect(units[1].result, HabitUnitResult.inProgress);
      expect(units[1].count, 1);
    });
  });

  group('judgeUnits: a commitment change', () {
    test('the old target judges earlier days (AC 5)', () {
      final small = commitment(
          id: 'small',
          chosenOn: '2026-11-16',
          unitLabel: 'pages',
          dailyTargetAmount: 5);
      final big = commitment(
          id: 'big',
          chosenOn: '2026-11-18',
          unitLabel: 'pages',
          dailyTargetAmount: 10);
      final units = judgeUnits(
          history([small, big], checkIns: [
            checkIn('2026-11-16', amount: 6),
            checkIn('2026-11-17', amount: 6),
            checkIn('2026-11-18', amount: 6),
          ]),
          day(11, 19));
      expect(results(units), [
        HabitUnitResult.done, // 6 of 5
        HabitUnitResult.done, // 6 of 5
        HabitUnitResult.missed, // 6 of 10
        HabitUnitResult.inProgress,
      ]);
    });

    test('a Wednesday weekly change governs the whole week it is made in',
        () {
      final three = commitment(
          id: 'three',
          chosenOn: '2026-11-02',
          repeatKind: HabitRepeatKind.timesPerWeek,
          timesPerPeriod: 3);
      final five = commitment(
          id: 'five',
          chosenOn: '2026-11-11', // Wednesday of the week of the 9th
          repeatKind: HabitRepeatKind.timesPerWeek,
          timesPerPeriod: 5);
      final units = judgeUnits(
          history([
            three,
            five
          ], checkIns: [
            checkIn('2026-11-02'),
            checkIn('2026-11-03'),
            checkIn('2026-11-04'),
            checkIn('2026-11-09'),
            checkIn('2026-11-10'),
            checkIn('2026-11-11'),
          ]),
          day(11, 17));
      expect(units[0].commitment.id, 'three');
      expect(units[0].result, HabitUnitResult.met);
      expect(units[1].commitment.id, 'five'); // 3 of 5: the whole week
      expect(units[1].firstDay, day(11, 9));
      expect(units[1].result, HabitUnitResult.missed);
    });

    test('a Thursday daily change leaves Monday to Wednesday with the weekly '
        'rule, as a partial week', () {
      final weekly = commitment(
          id: 'weekly',
          chosenOn: '2026-11-02',
          repeatKind: HabitRepeatKind.timesPerWeek,
          timesPerPeriod: 3);
      final daily = commitment(id: 'daily', chosenOn: '2026-11-05');
      final units = judgeUnits(
          history([weekly, daily], checkIns: [checkIn('2026-11-02')]),
          day(11, 7));
      expect(units[0].commitment.id, 'weekly');
      expect(units[0].firstDay, day(11, 2));
      expect(units[0].lastDay, day(11, 4));
      expect(units[0].isPartial, isTrue);
      expect(units[0].count, 1);
      expect(units[0].result, HabitUnitResult.skipped);
      expect(
          [for (final u in units.skip(1)) u.commitment.id], ['daily', 'daily', 'daily']);
      expect(units[1].kind, HabitUnitKind.day);
    });
  });
}
