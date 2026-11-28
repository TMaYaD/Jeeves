import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/models/time_opens_on_day.dart';
import 'package:jeeves/models/time_window_hours.dart';

// 2026-11-23 is a Monday.
final _monday = DateTime(2026, 11, 23);
final _tuesday = DateTime(2026, 11, 24);
final _wednesday = DateTime(2026, 11, 25);

TimeWindowHours _hours(Map<int, DayHours> byDay) =>
    TimeWindowHours.create(byDay)!;

void main() {
  group('timeOpensOnDay', () {
    test('an Outcome with no time opens on every day', () {
      expect(timeOpensOnDay(day: _tuesday), isTrue);
    });

    test('a named window opens on a day it has hours for', () {
      final hours = _hours({3: (startMinute: 16 * 60, endMinute: 20 * 60)});
      expect(timeOpensOnDay(windowHours: hours, day: _wednesday), isTrue);
      expect(timeOpensOnDay(windowHours: hours, day: _tuesday), isFalse);
    });

    test('a window that runs past midnight belongs to the day it starts', () {
      final hours = _hours({1: (startMinute: 22 * 60, endMinute: 2 * 60)});
      expect(timeOpensOnDay(windowHours: hours, day: _monday), isTrue);
      expect(timeOpensOnDay(windowHours: hours, day: _tuesday), isFalse);
    });

    test('a Time context opens only on its weekly days', () {
      final context = TimeContext.create(days: {3})!;
      expect(timeOpensOnDay(timeContext: context, day: _wednesday), isTrue);
      expect(timeOpensOnDay(timeContext: context, day: _tuesday), isFalse);
    });

    test('a Time context opens from its from-date on', () {
      final context = TimeContext.create(fromDate: _tuesday)!;
      expect(timeOpensOnDay(timeContext: context, day: _monday), isFalse);
      expect(timeOpensOnDay(timeContext: context, day: _tuesday), isTrue);
      expect(timeOpensOnDay(timeContext: context, day: _wednesday), isTrue);
    });

    test('the day after 31 December is read across the year boundary', () {
      // 2026-12-31 is a Thursday; 2027-01-01 a Friday.
      final context = TimeContext.create(days: {5})!;
      final newYearsDay = DateTime(2026, 12, 31 + 1);
      expect(timeOpensOnDay(timeContext: context, day: newYearsDay), isTrue);
      expect(
          timeOpensOnDay(timeContext: context, day: DateTime(2026, 12, 31)),
          isFalse);
    });
  });
}
