/// The coming-week line of the Weekly Review (GitHub #1073).
///
/// A pure function over the time of an Outcome's current Action: the line the
/// review shows when that time opens in the seven days starting on the day of
/// the review.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/models/action_place_and_time_window.dart';
import 'package:jeeves/models/coming_week_time.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/models/time_window_hours.dart';

/// Sunday 2026-11-29, noon. The coming week is Sun 29 Nov … Sat 5 Dec.
final DateTime _sundayNoon = DateTime(2026, 11, 29, 12);

/// A named window with the given name and hours.
ActionTimeWindow _window(String name, Map<int, DayHours> hours) => (
      id: 'window-1',
      hours: TimeWindowHours.create(hours)!,
      name: name,
    );

void main() {
  group('a named window', () {
    test('names the window and the day it opens', () {
      expect(
        comingWeekTimeLine(
          window: _window('Dance class', {
            3: (startMinute: 16 * 60, endMinute: 20 * 60),
          }),
          now: _sundayNoon,
        ),
        'Dance class · Wed 16:00–20:00',
      );
    });

    test('groups neighbouring days and lists the rest on their own', () {
      expect(
        comingWeekTimeLine(
          window: _window('Store hours', {
            for (var day = 1; day <= 5; day++)
              day: (startMinute: 11 * 60, endMinute: 20 * 60),
            6: (startMinute: 10 * 60, endMinute: 14 * 60),
          }),
          now: _sundayNoon,
        ),
        'Store hours · Mon–Fri 11:00–20:00 · Sat 10:00–14:00',
      );
    });

    test('says nothing when today\'s opening has already ended', () {
      final window = _window('Morning', {
        7: (startMinute: 9 * 60, endMinute: 11 * 60),
      });
      expect(
        comingWeekTimeLine(window: window, now: DateTime(2026, 11, 29, 12)),
        isNull,
        reason: 'the only opening ended before the review',
      );
      expect(
        comingWeekTimeLine(window: window, now: DateTime(2026, 11, 29, 10)),
        'Morning · Sun 09:00–11:00',
      );
    });

    test('reads seven equal days as "Every day"', () {
      final window = _window('All day', {
        for (var day = 1; day <= 7; day++)
          day: (startMinute: 9 * 60, endMinute: 17 * 60),
      });
      expect(
        comingWeekTimeLine(window: window, now: DateTime(2026, 11, 29, 8)),
        'All day · Every day 09:00–17:00',
      );
      expect(
        comingWeekTimeLine(window: window, now: DateTime(2026, 12, 2, 8)),
        'All day · Every day 09:00–17:00',
        reason: 'the week runs from today, so it wraps the week end',
      );
    });

    test('gives a window that runs past midnight to the day it starts', () {
      final window = _window('Late', {
        6: (startMinute: 22 * 60, endMinute: 2 * 60),
      });
      expect(
        comingWeekTimeLine(window: window, now: _sundayNoon),
        'Late · Sat 22:00–02:00',
      );
      expect(
        comingWeekTimeLine(window: window, now: DateTime(2026, 11, 29, 1)),
        'Late · Sat 22:00–02:00',
        reason: 'the opening running now belongs to yesterday, and the '
            'coming week has a Saturday of its own',
      );
    });
  });

  group('a Time context', () {
    test('names the day and the hours it opens', () {
      expect(
        comingWeekTimeLine(
          timeContext: TimeContext.create(
            days: {3},
            startMinute: 16 * 60,
            endMinute: 20 * 60,
          ),
          now: _sundayNoon,
        ),
        'Wed 16:00–20:00',
      );
    });

    test('names days without hours on their own', () {
      expect(
        comingWeekTimeLine(
          timeContext: TimeContext.create(days: {2, 4}),
          now: _sundayNoon,
        ),
        'Tue · Thu',
      );
    });

    test('skips a day before the from-date', () {
      expect(
        comingWeekTimeLine(
          timeContext: TimeContext.create(
            fromDate: DateTime(2026, 12, 3),
            days: {2, 4},
            startMinute: 9 * 60,
            endMinute: 17 * 60,
          ),
          now: _sundayNoon,
        ),
        'Thu 09:00–17:00',
      );
    });

    test('says when the time starts when the context is only a from-date', () {
      expect(
        comingWeekTimeLine(
          timeContext: TimeContext.create(fromDate: DateTime(2026, 12, 2)),
          now: _sundayNoon,
        ),
        'From Wed 2 Dec',
      );
      expect(
        comingWeekTimeLine(
          timeContext: TimeContext.create(fromDate: DateTime(2026, 12, 10)),
          now: _sundayNoon,
        ),
        isNull,
        reason: 'the from-date is beyond the coming week',
      );
      expect(
        comingWeekTimeLine(
          timeContext: TimeContext.create(fromDate: DateTime(2026, 11, 20)),
          now: _sundayNoon,
        ),
        isNull,
        reason: 'the from-date is past',
      );
    });
  });

  test('says nothing when the Outcome has no time', () {
    expect(comingWeekTimeLine(now: _sundayNoon), isNull);
  });
}
