import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/habit_commitment.dart';

/// Builds a commitment with the given rule, so each test reads as the rule it
/// is about.
HabitCommitment commitment({
  required String id,
  HabitRepeatKind repeatKind = HabitRepeatKind.everyDay,
  String habitId = 'habit-1',
  String chosenOn = '2026-11-16',
  DateTime? createdAt,
  List<int>? chosenWeekdays,
  int? timesPerPeriod,
  int? intervalDays,
  List<int>? preferredDays,
  String? unitLabel,
  double? dailyTargetAmount,
}) {
  return HabitCommitment(
    id: id,
    habitId: habitId,
    chosenOn: chosenOn,
    createdAt: createdAt ?? DateTime.utc(2026, 11, 16, 9),
    repeatKind: repeatKind,
    chosenWeekdays: chosenWeekdays,
    timesPerPeriod: timesPerPeriod,
    intervalDays: intervalDays,
    preferredDays: preferredDays,
    unitLabel: unitLabel,
    dailyTargetAmount: dailyTargetAmount,
  );
}

void main() {
  group('the repeat kinds', () {
    test('carry the strings they are stored as', () {
      expect(HabitRepeatKind.everyDay.storedValue, 'every_day');
      expect(HabitRepeatKind.chosenWeekdays.storedValue, 'chosen_weekdays');
      expect(HabitRepeatKind.timesPerWeek.storedValue, 'times_per_week');
      expect(HabitRepeatKind.timesPerMonth.storedValue, 'times_per_month');
      expect(HabitRepeatKind.everyNDays.storedValue, 'every_n_days');
    });

    test('read a stored string back', () {
      for (final kind in HabitRepeatKind.values) {
        expect(HabitRepeatKind.tryParse(kind.storedValue), kind);
      }
    });

    test('tolerate a stored string it does not know', () {
      expect(HabitRepeatKind.tryParse('every_fortnight'), isNull);
      expect(HabitRepeatKind.tryParse(''), isNull);
    });
  });

  group('validation', () {
    test('a chosen weekday is 1 to 7', () {
      expect(
        () => commitment(
            id: 'c', repeatKind: HabitRepeatKind.chosenWeekdays, chosenWeekdays: [1, 7]),
        returnsNormally,
      );
      expect(
        () => commitment(
            id: 'c', repeatKind: HabitRepeatKind.chosenWeekdays, chosenWeekdays: [1, 0]),
        throwsArgumentError,
      );
      expect(
        () => commitment(
            id: 'c', repeatKind: HabitRepeatKind.chosenWeekdays, chosenWeekdays: [8]),
        throwsArgumentError,
      );
    });

    test('a chosen-weekdays commitment has at least one weekday', () {
      expect(
        () => commitment(
            id: 'c', repeatKind: HabitRepeatKind.chosenWeekdays, chosenWeekdays: []),
        throwsArgumentError,
      );
      expect(
        () => commitment(id: 'c', repeatKind: HabitRepeatKind.chosenWeekdays),
        throwsArgumentError,
      );
    });

    test('only a chosen-weekdays commitment has chosen weekdays', () {
      expect(
        () => commitment(id: 'c', chosenWeekdays: [1, 2]),
        throwsArgumentError,
      );
      expect(
        () => commitment(
            id: 'c',
            repeatKind: HabitRepeatKind.timesPerWeek,
            timesPerPeriod: 3,
            chosenWeekdays: [1, 2]),
        throwsArgumentError,
      );
    });

    test('N is 1 or more, with no upper limit', () {
      expect(
        () => commitment(
            id: 'c', repeatKind: HabitRepeatKind.timesPerWeek, timesPerPeriod: 0),
        throwsArgumentError,
      );
      expect(
        () => commitment(
            id: 'c', repeatKind: HabitRepeatKind.timesPerMonth, timesPerPeriod: -2),
        throwsArgumentError,
      );
      expect(
        () => commitment(
            id: 'c', repeatKind: HabitRepeatKind.timesPerWeek, timesPerPeriod: 100000),
        returnsNormally,
      );
    });

    test('a counted commitment has its N', () {
      expect(
        () => commitment(id: 'c', repeatKind: HabitRepeatKind.timesPerWeek),
        throwsArgumentError,
      );
      expect(
        () => commitment(id: 'c', repeatKind: HabitRepeatKind.timesPerMonth),
        throwsArgumentError,
      );
    });

    test('only a counted commitment has N', () {
      expect(
        () => commitment(id: 'c', timesPerPeriod: 3),
        throwsArgumentError,
      );
      expect(
        () => commitment(
            id: 'c',
            repeatKind: HabitRepeatKind.everyNDays,
            intervalDays: 2,
            timesPerPeriod: 3),
        throwsArgumentError,
      );
    });

    test('the interval is 1 day or more', () {
      expect(
        () => commitment(
            id: 'c', repeatKind: HabitRepeatKind.everyNDays, intervalDays: 0),
        throwsArgumentError,
      );
      expect(
        () => commitment(
            id: 'c', repeatKind: HabitRepeatKind.everyNDays, intervalDays: -1),
        throwsArgumentError,
      );
    });

    test('an every-N-days commitment has its interval', () {
      expect(
        () => commitment(id: 'c', repeatKind: HabitRepeatKind.everyNDays),
        throwsArgumentError,
      );
    });

    test('only an every-N-days commitment has an interval', () {
      expect(() => commitment(id: 'c', intervalDays: 2), throwsArgumentError);
    });

    test('only a per-week or per-month commitment has preferred days', () {
      expect(
        () => commitment(id: 'c', preferredDays: [1, 2]),
        throwsArgumentError,
      );
      expect(
        () => commitment(
            id: 'c',
            repeatKind: HabitRepeatKind.chosenWeekdays,
            chosenWeekdays: [1],
            preferredDays: [1]),
        throwsArgumentError,
      );
    });

    test('a preferred weekday is 1 to 7', () {
      expect(
        () => commitment(
            id: 'c',
            repeatKind: HabitRepeatKind.timesPerWeek,
            timesPerPeriod: 3,
            preferredDays: [0]),
        throwsArgumentError,
      );
      expect(
        () => commitment(
            id: 'c',
            repeatKind: HabitRepeatKind.timesPerWeek,
            timesPerPeriod: 3,
            preferredDays: [8]),
        throwsArgumentError,
      );
    });

    test('a preferred date is 1 to 31', () {
      expect(
        () => commitment(
            id: 'c',
            repeatKind: HabitRepeatKind.timesPerMonth,
            timesPerPeriod: 4,
            preferredDays: [0]),
        throwsArgumentError,
      );
      expect(
        () => commitment(
            id: 'c',
            repeatKind: HabitRepeatKind.timesPerMonth,
            timesPerPeriod: 4,
            preferredDays: [32]),
        throwsArgumentError,
      );
      expect(
        () => commitment(
            id: 'c',
            repeatKind: HabitRepeatKind.timesPerMonth,
            timesPerPeriod: 4,
            preferredDays: [31]),
        returnsNormally,
      );
    });

    test('an empty list of preferred days is refused', () {
      expect(
        () => commitment(
            id: 'c',
            repeatKind: HabitRepeatKind.timesPerWeek,
            timesPerPeriod: 3,
            preferredDays: []),
        throwsArgumentError,
      );
    });

    test('the unit and the target stand or fall together', () {
      expect(
        () => commitment(id: 'c', unitLabel: 'pages'),
        throwsArgumentError,
      );
      expect(
        () => commitment(id: 'c', dailyTargetAmount: 10),
        throwsArgumentError,
      );
      expect(
        () => commitment(id: 'c', unitLabel: 'pages', dailyTargetAmount: 10),
        returnsNormally,
      );
      expect(() => commitment(id: 'c'), returnsNormally);
    });

    test('the target is finite', () {
      expect(
        () => commitment(
            id: 'c', unitLabel: 'pages', dailyTargetAmount: double.infinity),
        throwsArgumentError,
      );
      expect(
        () => commitment(
            id: 'c', unitLabel: 'pages', dailyTargetAmount: double.nan),
        throwsArgumentError,
      );
    });

    test('the target is more than zero', () {
      expect(
        () => commitment(id: 'c', unitLabel: 'pages', dailyTargetAmount: 0),
        throwsArgumentError,
      );
      expect(
        () => commitment(id: 'c', unitLabel: 'pages', dailyTargetAmount: -1),
        throwsArgumentError,
      );
    });

    test('the chosen day is a day key', () {
      expect(() => commitment(id: 'c', chosenOn: '2026-11'), throwsArgumentError);
      expect(() => commitment(id: 'c', chosenOn: '16-11-2026'), throwsArgumentError);
      expect(() => commitment(id: 'c', chosenOn: '2026-02-30'), throwsArgumentError);
    });

    test('the commitment needs an id and a Habit', () {
      expect(() => commitment(id: ''), throwsArgumentError);
      expect(() => commitment(id: 'c', habitId: ''), throwsArgumentError);
    });
  });

  group('the canonical day lists', () {
    test('are sorted and deduplicated', () {
      expect(canonicalDayListJson([3, 1, 3, 2]), '[1,2,3]');
      expect(canonicalDayListJson([7, 1]), '[1,7]');
      expect(canonicalDayListJson(<int>[]), '[]');
    });

    test('are what a commitment stores', () {
      final value = commitment(
        id: 'c',
        repeatKind: HabitRepeatKind.chosenWeekdays,
        chosenWeekdays: [5, 1, 3],
      );
      expect(value.chosenWeekdaysJson, '[1,3,5]');
      expect(value.preferredDaysJson, isNull);
    });

    test('read back the same days', () {
      expect(parseDayListJson('[1,3,5]'), [1, 3, 5]);
      expect(parseDayListJson('[5,1,3,1]'), [1, 3, 5]);
      expect(parseDayListJson('[]'), isEmpty);
    });

    test('tolerate a text that is not a day list', () {
      expect(parseDayListJson(null), isNull);
      expect(parseDayListJson('not json'), isNull);
      expect(parseDayListJson('{"days":1}'), isNull);
      expect(parseDayListJson('[1,"two"]'), isNull);
    });
  });

  group('the day key', () {
    test('is the local calendar day', () {
      expect(habitDayKey(DateTime(2026, 11, 5)), '2026-11-05');
      expect(habitDayKey(DateTime(2026, 1, 5)), '2026-01-05');
      expect(habitDayKey(DateTime(2026, 11, 18, 23, 59)), '2026-11-18');
    });

    test('reads back as a date', () {
      expect(habitDateFromDayKey('2026-11-05'), DateTime(2026, 11, 5));
      expect(habitDateFromDayKey('2026-11-31'), isNull);
      expect(habitDateFromDayKey('2026-13-01'), isNull);
      expect(habitDateFromDayKey('not a day'), isNull);
      expect(habitDateFromDayKey('2026-+1-+2'), isNull);
    });
  });

  group('the effective start of a commitment', () {
    test('is the chosen day for the daily kinds', () {
      expect(
        effectiveStartOf(commitment(id: 'c', chosenOn: '2026-11-18')),
        DateTime(2026, 11, 18),
      );
      expect(
        effectiveStartOf(commitment(
            id: 'c',
            repeatKind: HabitRepeatKind.chosenWeekdays,
            chosenOn: '2026-11-18',
            chosenWeekdays: [3])),
        DateTime(2026, 11, 18),
      );
      expect(
        effectiveStartOf(commitment(
            id: 'c',
            repeatKind: HabitRepeatKind.everyNDays,
            chosenOn: '2026-11-18',
            intervalDays: 3)),
        DateTime(2026, 11, 18),
      );
    });

    test('is the Monday of the chosen week for a weekly commitment', () {
      expect(
        effectiveStartOf(commitment(
            id: 'c',
            repeatKind: HabitRepeatKind.timesPerWeek,
            chosenOn: '2026-11-18',
            timesPerPeriod: 3)),
        DateTime(2026, 11, 16),
      );
    });

    test('is the Monday before a chosen Sunday', () {
      expect(
        effectiveStartOf(commitment(
            id: 'c',
            repeatKind: HabitRepeatKind.timesPerWeek,
            chosenOn: '2026-11-22',
            timesPerPeriod: 3)),
        DateTime(2026, 11, 16),
      );
    });

    test('is the first of the chosen month for a monthly commitment', () {
      expect(
        effectiveStartOf(commitment(
            id: 'c',
            repeatKind: HabitRepeatKind.timesPerMonth,
            chosenOn: '2026-11-18',
            timesPerPeriod: 10)),
        DateTime(2026, 11, 1),
      );
    });

    test('is the first of the month when the first day was chosen', () {
      expect(
        effectiveStartOf(commitment(
            id: 'c',
            repeatKind: HabitRepeatKind.timesPerMonth,
            chosenOn: '2026-11-01',
            timesPerPeriod: 10)),
        DateTime(2026, 11, 1),
      );
      expect(
        effectiveStartOf(commitment(
            id: 'c',
            repeatKind: HabitRepeatKind.timesPerMonth,
            chosenOn: '2026-03-01',
            timesPerPeriod: 10)),
        DateTime(2026, 3, 1),
      );
    });

    test('is the first of the month when the last day was chosen', () {
      expect(
        effectiveStartOf(commitment(
            id: 'c',
            repeatKind: HabitRepeatKind.timesPerMonth,
            chosenOn: '2026-11-30',
            timesPerPeriod: 10)),
        DateTime(2026, 11, 1),
      );
    });
  });

  group('the commitment in force on a day', () {
    test('a weekly change governs the whole week', () {
      final everyDay = commitment(
        id: 'c1',
        chosenOn: '2026-11-16',
        createdAt: DateTime.utc(2026, 11, 16, 9),
      );
      final threeTimesAWeek = commitment(
        id: 'c2',
        repeatKind: HabitRepeatKind.timesPerWeek,
        timesPerPeriod: 3,
        chosenOn: '2026-11-18',
        createdAt: DateTime.utc(2026, 11, 18, 9),
      );
      final commitments = [everyDay, threeTimesAWeek];

      expect(commitmentInForceOn(commitments, '2026-11-16'), threeTimesAWeek);
      expect(commitmentInForceOn(commitments, '2026-11-17'), threeTimesAWeek);
      expect(commitmentInForceOn(commitments, '2026-11-18'), threeTimesAWeek);
      expect(commitmentInForceOn(commitments, '2026-11-19'), threeTimesAWeek);
    });

    test('a daily change made on a Thursday leaves Monday to Wednesday alone', () {
      final threeTimesAWeek = commitment(
        id: 'c1',
        repeatKind: HabitRepeatKind.timesPerWeek,
        timesPerPeriod: 3,
        chosenOn: '2026-11-16',
        createdAt: DateTime.utc(2026, 11, 16, 9),
      );
      final everyDay = commitment(
        id: 'c2',
        chosenOn: '2026-11-19',
        createdAt: DateTime.utc(2026, 11, 19, 9),
      );
      final commitments = [threeTimesAWeek, everyDay];

      expect(commitmentInForceOn(commitments, '2026-11-16'), threeTimesAWeek);
      expect(commitmentInForceOn(commitments, '2026-11-17'), threeTimesAWeek);
      expect(commitmentInForceOn(commitments, '2026-11-18'), threeTimesAWeek);
      expect(commitmentInForceOn(commitments, '2026-11-19'), everyDay);
      expect(commitmentInForceOn(commitments, '2026-11-20'), everyDay);
    });

    test('a later change within the same week wins', () {
      final first = commitment(
        id: 'c1',
        repeatKind: HabitRepeatKind.timesPerWeek,
        timesPerPeriod: 3,
        chosenOn: '2026-11-16',
        createdAt: DateTime.utc(2026, 11, 16, 9),
      );
      final second = commitment(
        id: 'c2',
        repeatKind: HabitRepeatKind.timesPerWeek,
        timesPerPeriod: 5,
        chosenOn: '2026-11-17',
        createdAt: DateTime.utc(2026, 11, 17, 9),
      );
      final commitments = [first, second];

      expect(commitmentInForceOn(commitments, '2026-11-16'), second);
      expect(commitmentInForceOn(commitments, '2026-11-22'), second);
    });

    test('two commitments written at the same instant are separated by the id', () {
      final writtenAt = DateTime.utc(2026, 11, 16, 9);
      final first = commitment(
        id: 'aaa',
        chosenOn: '2026-11-16',
        createdAt: writtenAt,
      );
      final second = commitment(
        id: 'bbb',
        chosenOn: '2026-11-16',
        createdAt: writtenAt,
      );

      expect(commitmentInForceOn([first, second], '2026-11-16'), second);
      expect(commitmentInForceOn([second, first], '2026-11-16'), second);
    });

    test('a finished week keeps the commitment it was judged by', () {
      final first = commitment(
        id: 'c1',
        repeatKind: HabitRepeatKind.timesPerWeek,
        timesPerPeriod: 3,
        chosenOn: '2026-11-16',
        createdAt: DateTime.utc(2026, 11, 16, 9),
      );
      final second = commitment(
        id: 'c2',
        repeatKind: HabitRepeatKind.timesPerWeek,
        timesPerPeriod: 5,
        chosenOn: '2026-11-23',
        createdAt: DateTime.utc(2026, 11, 23, 9),
      );
      final commitments = [first, second];

      expect(commitmentInForceOn(commitments, '2026-11-16'), first);
      expect(commitmentInForceOn(commitments, '2026-11-20'), first);
      expect(commitmentInForceOn(commitments, '2026-11-22'), first);
      expect(commitmentInForceOn(commitments, '2026-11-23'), second);
    });

    test('a finished month keeps the commitment it was judged by', () {
      final first = commitment(
        id: 'c1',
        repeatKind: HabitRepeatKind.timesPerMonth,
        timesPerPeriod: 10,
        chosenOn: '2026-11-02',
        createdAt: DateTime.utc(2026, 11, 2, 9),
      );
      final second = commitment(
        id: 'c2',
        repeatKind: HabitRepeatKind.timesPerMonth,
        timesPerPeriod: 20,
        chosenOn: '2026-12-03',
        createdAt: DateTime.utc(2026, 12, 3, 9),
      );
      final commitments = [first, second];

      expect(commitmentInForceOn(commitments, '2026-11-01'), first);
      expect(commitmentInForceOn(commitments, '2026-11-30'), first);
      expect(commitmentInForceOn(commitments, '2026-12-01'), second);
      expect(commitmentInForceOn(commitments, '2026-12-03'), second);
    });

    test('a finished week keeps its weekly commitment when a monthly one follows',
        () {
      final weekly = commitment(
        id: 'c1',
        repeatKind: HabitRepeatKind.timesPerWeek,
        timesPerPeriod: 3,
        chosenOn: '2026-11-16',
        createdAt: DateTime.utc(2026, 11, 16, 9),
      );
      final monthly = commitment(
        id: 'c2',
        repeatKind: HabitRepeatKind.timesPerMonth,
        timesPerPeriod: 10,
        chosenOn: '2026-11-25',
        createdAt: DateTime.utc(2026, 11, 25, 9),
      );
      final commitments = [weekly, monthly];

      // The week of 16-22 November finished before the change.
      expect(commitmentInForceOn(commitments, '2026-11-22'), weekly);
      // The current week, and the month, take the monthly rule.
      expect(commitmentInForceOn(commitments, '2026-11-23'), monthly);
      expect(commitmentInForceOn(commitments, '2026-11-25'), monthly);
      // Days before the weekly rule began are reached by the monthly one.
      expect(commitmentInForceOn(commitments, '2026-11-10'), monthly);
      expect(effectiveStartsOf(commitments)['c2'], DateTime(2026, 11, 23));
    });

    test('a day before the first commitment has none', () {
      final only = commitment(
        id: 'c1',
        chosenOn: '2026-11-16',
        createdAt: DateTime.utc(2026, 11, 16, 9),
      );

      expect(commitmentInForceOn([only], '2026-11-15'), isNull);
      expect(commitmentInForceOn(<HabitCommitment>[], '2026-11-16'), isNull);
    });

    test('a day that is not a day key has none', () {
      final only = commitment(id: 'c1');

      expect(commitmentInForceOn([only], 'not a day'), isNull);
    });
  });
}
