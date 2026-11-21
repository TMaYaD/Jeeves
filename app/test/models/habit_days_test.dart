import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/models/habit_days.dart';

HabitCommitment commitment({
  HabitRepeatKind repeatKind = HabitRepeatKind.everyDay,
  String chosenOn = '2026-11-16',
  List<int>? chosenWeekdays,
  int? timesPerPeriod,
  int? intervalDays,
}) {
  return HabitCommitment(
    id: 'c',
    habitId: 'habit-1',
    chosenOn: chosenOn,
    createdAt: DateTime.utc(2026, 11, 16, 9),
    repeatKind: repeatKind,
    chosenWeekdays: chosenWeekdays,
    timesPerPeriod: timesPerPeriod,
    intervalDays: intervalDays,
  );
}

DateTime utcDay(int year, int month, int day) => DateTime.utc(year, month, day);

void main() {
  group('parseHabitDay', () {
    test('is the inverse of habitDayKey', () {
      for (final key in ['2026-11-16', '2028-02-29', '2026-12-31', '0999-01-01']) {
        expect(habitDayKey(parseHabitDay(key)!), key);
      }
    });

    test('gives a UTC calendar day', () {
      final day = parseHabitDay('2026-03-29')!;
      expect(day.isUtc, isTrue);
      expect(day, DateTime.utc(2026, 3, 29));
    });

    test('is null for a text that is not a day key', () {
      for (final key in ['', '2026-2-3', '2026-02-30', '2026-13-01', '+026-01-01', 'x']) {
        expect(parseHabitDay(key), isNull, reason: key);
      }
    });
  });

  group('weekStart and monthStart', () {
    test('the week starts on the Monday, for every day of the week', () {
      // 2026-11-16 is a Monday.
      for (var offset = 0; offset < 7; offset++) {
        expect(weekStart(utcDay(2026, 11, 16 + offset)), utcDay(2026, 11, 16));
      }
      expect(weekStart(utcDay(2026, 11, 23)), utcDay(2026, 11, 23));
    });

    test('a week across a month edge starts in the earlier month', () {
      // Thursday 1 Oct 2026; its week began Monday 28 Sep.
      expect(weekStart(utcDay(2026, 10, 1)), utcDay(2026, 9, 28));
      // And across a year edge: Friday 1 Jan 2027.
      expect(weekStart(utcDay(2027, 1, 1)), utcDay(2026, 12, 28));
    });

    test('the month starts on the 1st', () {
      expect(monthStart(utcDay(2026, 11, 30)), utcDay(2026, 11, 1));
      expect(monthStart(utcDay(2026, 11, 1)), utcDay(2026, 11, 1));
    });
  });

  group('isDueOn', () {
    test('every day is due on every day from the day it was chosen', () {
      final c = commitment(chosenOn: '2026-11-18');
      expect(isDueOn(c, utcDay(2026, 11, 17)), isFalse);
      expect(isDueOn(c, utcDay(2026, 11, 18)), isTrue);
      expect(isDueOn(c, utcDay(2026, 12, 25)), isTrue);
    });

    test('chosen weekdays are due only on those weekdays', () {
      // Monday, Wednesday, Friday, chosen on a Monday.
      final c = commitment(
        repeatKind: HabitRepeatKind.chosenWeekdays,
        chosenWeekdays: [1, 3, 5],
      );
      final due = [
        for (var d = 16; d <= 22; d++)
          if (isDueOn(c, utcDay(2026, 11, d))) d,
      ];
      expect(due, [16, 18, 20]);
    });

    test('chosen weekdays are not due before the day it was chosen', () {
      final c = commitment(
        repeatKind: HabitRepeatKind.chosenWeekdays,
        chosenWeekdays: [1],
      );
      expect(isDueOn(c, utcDay(2026, 11, 9)), isFalse);
    });

    test('every 3 days from a Wednesday', () {
      // 2026-11-18 is a Wednesday.
      final c = commitment(
        repeatKind: HabitRepeatKind.everyNDays,
        chosenOn: '2026-11-18',
        intervalDays: 3,
      );
      final due = [
        for (var d = 16; d <= 30; d++)
          if (isDueOn(c, utcDay(2026, 11, d))) d,
      ];
      expect(due, [18, 21, 24, 27, 30]);
      // The next due day crosses into December.
      expect(isDueOn(c, utcDay(2026, 12, 3)), isTrue);
      expect(isDueOn(c, utcDay(2026, 12, 2)), isFalse);
    });

    test('every N days counts across a leap February', () {
      final c = commitment(
        repeatKind: HabitRepeatKind.everyNDays,
        chosenOn: '2028-02-27',
        intervalDays: 2,
      );
      expect(isDueOn(c, utcDay(2028, 2, 29)), isTrue);
      expect(isDueOn(c, utcDay(2028, 3, 2)), isTrue);
      expect(isDueOn(c, utcDay(2028, 3, 1)), isFalse);
    });

    test('a clock change does not shift a day', () {
      // Europe and the US change their clocks on 2026-03-08 and 2026-03-29;
      // days are UTC calendar days, so the 23-hour or 25-hour local day
      // stays one day.
      final c = commitment(
        repeatKind: HabitRepeatKind.everyNDays,
        chosenOn: '2026-03-07',
        intervalDays: 1,
      );
      for (var d = 7; d <= 31; d++) {
        expect(isDueOn(c, utcDay(2026, 3, d)), isTrue, reason: 'March $d');
      }
      final c7 = commitment(
        repeatKind: HabitRepeatKind.everyNDays,
        chosenOn: '2026-03-01',
        intervalDays: 7,
      );
      expect(isDueOn(c7, utcDay(2026, 3, 8)), isTrue);
      expect(isDueOn(c7, utcDay(2026, 3, 29)), isTrue);
    });

    test('a per-week or per-month commitment has no due days', () {
      final weekly = commitment(
          repeatKind: HabitRepeatKind.timesPerWeek, timesPerPeriod: 3);
      expect(() => isDueOn(weekly, utcDay(2026, 11, 16)), throwsArgumentError);
    });
  });

  group('periodSpan', () {
    test('a week is Monday to Sunday, both included', () {
      final c = commitment(
          repeatKind: HabitRepeatKind.timesPerWeek, timesPerPeriod: 3);
      final span = periodSpan(c, utcDay(2026, 11, 19))!;
      expect(span.start, utcDay(2026, 11, 16));
      expect(span.end, utcDay(2026, 11, 22));
      expect(span.dayCount, 7);
    });

    test('a week across a month edge', () {
      final c = commitment(
          repeatKind: HabitRepeatKind.timesPerWeek, timesPerPeriod: 3);
      final span = periodSpan(c, utcDay(2026, 10, 1))!;
      expect(span.start, utcDay(2026, 9, 28));
      expect(span.end, utcDay(2026, 10, 4));
      expect(span.contains(utcDay(2026, 9, 30)), isTrue);
      expect(span.contains(utcDay(2026, 10, 5)), isFalse);
    });

    test('a month runs from the 1st to its last day', () {
      final c = commitment(
          repeatKind: HabitRepeatKind.timesPerMonth, timesPerPeriod: 8);
      final span = periodSpan(c, utcDay(2026, 11, 19))!;
      expect(span.start, utcDay(2026, 11, 1));
      expect(span.end, utcDay(2026, 11, 30));
      expect(span.dayCount, 30);
    });

    test('a leap February has 29 days and a plain one 28', () {
      final c = commitment(
          repeatKind: HabitRepeatKind.timesPerMonth, timesPerPeriod: 8);
      final leap = periodSpan(c, utcDay(2028, 2, 10))!;
      expect(leap.end, utcDay(2028, 2, 29));
      expect(leap.dayCount, 29);
      final plain = periodSpan(c, utcDay(2027, 2, 10))!;
      expect(plain.end, utcDay(2027, 2, 28));
      expect(plain.dayCount, 28);
    });

    test('December ends on the 31st', () {
      final c = commitment(
          repeatKind: HabitRepeatKind.timesPerMonth, timesPerPeriod: 8);
      expect(periodSpan(c, utcDay(2026, 12, 5))!.end, utcDay(2026, 12, 31));
    });

    test('a week spanning a clock change is still seven days', () {
      final c = commitment(
          repeatKind: HabitRepeatKind.timesPerWeek, timesPerPeriod: 3);
      final span = periodSpan(c, utcDay(2026, 3, 29))!;
      expect(span.start, utcDay(2026, 3, 23));
      expect(span.end, utcDay(2026, 3, 29));
      expect(span.dayCount, 7);
    });

    test('a day-based commitment has no period', () {
      expect(periodSpan(commitment(), utcDay(2026, 11, 16)), isNull);
    });
  });
}
