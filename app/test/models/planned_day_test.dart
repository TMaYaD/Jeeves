import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/planned_day.dart';
import 'package:jeeves/models/time_context.dart';

/// November 2026: the 23rd is a Monday, the 25th a Wednesday.
DateTime _at(int day, int hour, [int minute = 0]) =>
    DateTime(2026, 11, day, hour, minute);

void main() {
  const shutdown = TimeOfDay(hour: 18, minute: 0);

  /// The first instant the time of [tc] is open in the day planned at [now].
  DateTime? firstOpen(TimeContext tc, DateTime now) => firstOpenInPlannedDay(
        isOpenAt: tc.isSatisfiedAt,
        nextTransitionAfter: tc.nextTransitionAfter,
        now: now,
        dayEnd: plannedDayEnd(now: now, shutdownTime: shutdown),
      );

  group('plannedDayEnd', () {
    test('the planned day ends at the Evening Shutdown time', () {
      expect(plannedDayEnd(now: _at(23, 9), shutdownTime: shutdown), _at(23, 18));
    });

    test('after the Evening Shutdown time the planned day ends at midnight',
        () {
      expect(plannedDayEnd(now: _at(23, 19), shutdownTime: shutdown), _at(24, 0));
    });
  });

  group('firstOpenInPlannedDay', () {
    test('a time that opens later today opens in the planned day', () {
      final everyDay =
          TimeContext.create(days: {1, 2, 3, 4, 5, 6, 7}, startMinute: 11 * 60, endMinute: 20 * 60)!;
      expect(firstOpen(everyDay, _at(23, 9)), _at(23, 11));
    });

    test('a time that is open now opens now', () {
      final everyDay =
          TimeContext.create(days: {1, 2, 3, 4, 5, 6, 7}, startMinute: 11 * 60, endMinute: 20 * 60)!;
      expect(firstOpen(everyDay, _at(23, 12)), _at(23, 12));
    });

    test('a time that opens on another day does not open in the planned day',
        () {
      final wednesdayOnly = TimeContext.create(days: {3})!;
      expect(firstOpen(wednesdayOnly, _at(23, 9)), isNull);
    });

    test('a time that opens after the Evening Shutdown time does not open',
        () {
      final late =
          TimeContext.create(days: {1, 2, 3, 4, 5, 6, 7}, startMinute: 19 * 60, endMinute: 21 * 60)!;
      expect(firstOpen(late, _at(23, 9)), isNull);
    });

    test('a time that closed earlier today does not open', () {
      final early =
          TimeContext.create(days: {1, 2, 3, 4, 5, 6, 7}, startMinute: 6 * 60, endMinute: 8 * 60)!;
      expect(firstOpen(early, _at(23, 9)), isNull);
    });

    test('a time that starts tomorrow does not open', () {
      final tomorrow = TimeContext.create(fromDate: DateTime(2026, 11, 24))!;
      expect(firstOpen(tomorrow, _at(23, 9)), isNull);
    });

    test('a time that starts today is open now', () {
      final today = TimeContext.create(fromDate: DateTime(2026, 11, 23))!;
      expect(firstOpen(today, _at(23, 9)), _at(23, 9));
    });
  });
}
