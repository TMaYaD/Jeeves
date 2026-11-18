import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/autoflow.dart';
import 'package:jeeves/models/calendar_day.dart';
import 'package:jeeves/services/calendar/calendar_types.dart';

DateTime _at(int hour, [int minute = 0]) => DateTime(2030, 3, 15, hour, minute);

CalendarEvent _event(DateTime start, DateTime end, {bool allDay = false}) =>
    CalendarEvent(id: '$start', title: 't', start: start, end: end, isAllDay: allDay);

void main() {
  const shutdown = TimeOfDay(hour: 18, minute: 0);

  test('the day ends at the Evening Shutdown time', () {
    expect(calendarDayEnd(flowOrigin: _at(9), shutdownTime: shutdown), _at(18));
  });

  test('after the Evening Shutdown time there is no calendar window', () {
    expect(calendarDayEnd(flowOrigin: _at(18), shutdownTime: shutdown), isNull);
    expect(calendarDayEnd(flowOrigin: _at(20), shutdownTime: shutdown), isNull);
  });

  test('only timed events block time, clipped to the window', () {
    final busy = busyIntervalsWithin([
      _event(_at(8), _at(10)),
      _event(_at(0), _at(23, 59), allDay: true),
      _event(_at(19), _at(20)),
    ], _at(9), _at(18));
    expect(busy.length, 1);
    expect(busy.single.start, _at(9));
    expect(busy.single.end, _at(10));
  });

  test('free minutes are the window less the union of overlapping events', () {
    final free = freeMinutesBetween(_at(9), _at(18), [
      BusyInterval(start: _at(9), end: _at(11)),
      BusyInterval(start: _at(10), end: _at(12)),
      BusyInterval(start: _at(15), end: _at(16)),
    ]);
    expect(free, 540 - 180 - 60);
  });
}
