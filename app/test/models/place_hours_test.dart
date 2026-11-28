/// The hours a Place resolves to (issue #1074).
///
/// One rule: a Place has one source of hours — a named time window, or hours
/// of its own — and they are read on the Place's own clock. A value the app
/// cannot read resolves to nothing, and a Place with nothing hides nothing.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/models/action_place_and_time_window.dart';
import 'package:jeeves/models/time_window_hours.dart';

void main() {
  /// Mon–Fri 11:00–20:00 — the hardware store's hours.
  final monToFri = TimeWindowHours.create({
    for (var day = 1; day <= 5; day++)
      day: (startMinute: 11 * 60, endMinute: 20 * 60),
  })!;

  group('a place that names a time window', () {
    test('takes the window\'s hours and keeps the window\'s name', () {
      final resolved = resolvePlaceHours(
        timeWindowId: 'w1',
        timeWindowName: 'Weekday hours',
        timeWindowHoursText: monToFri.encode(),
        ownHoursText: null,
        timeZoneName: null,
      );

      expect(resolved, isNotNull);
      expect(resolved!.timeWindowId, 'w1');
      expect(resolved.timeWindowName, 'Weekday hours');
      expect(resolved.hours, monToFri);
    });

    test('a window row that is gone resolves to nothing', () {
      expect(
        resolvePlaceHours(
          timeWindowId: 'w1',
          timeWindowName: 'Weekday hours',
          timeWindowHoursText: null,
          ownHoursText: null,
          timeZoneName: null,
        ),
        isNull,
      );
    });

    test('a window whose hours do not parse resolves to nothing', () {
      expect(
        resolvePlaceHours(
          timeWindowId: 'w1',
          timeWindowName: 'Weekday hours',
          timeWindowHoursText: 'not hours',
          ownHoursText: null,
          timeZoneName: null,
        ),
        isNull,
      );
    });

    test('the window wins over hours of the place\'s own', () {
      // Both at once is a state the DAO refuses to write, but two devices
      // that edited apart can leave it. The rule is fixed: the window.
      final resolved = resolvePlaceHours(
        timeWindowId: 'w1',
        timeWindowName: 'Weekday hours',
        timeWindowHoursText: monToFri.encode(),
        ownHoursText: 'not hours',
        timeZoneName: null,
      );

      expect(resolved, isNotNull);
      expect(resolved!.timeWindowId, 'w1');
      expect(resolved.hours, monToFri);
    });
  });

  group('a place with hours of its own', () {
    test('takes its own hours', () {
      final resolved = resolvePlaceHours(
        timeWindowId: null,
        timeWindowName: null,
        timeWindowHoursText: null,
        ownHoursText: monToFri.encode(),
        timeZoneName: null,
      );

      expect(resolved, isNotNull);
      expect(resolved!.timeWindowId, isNull);
      expect(resolved.timeWindowName, isNull);
      expect(resolved.hours, monToFri);
    });

    test('hours that do not parse resolve to nothing', () {
      expect(
        resolvePlaceHours(
          timeWindowId: null,
          timeWindowName: null,
          timeWindowHoursText: null,
          ownHoursText: '{"day":1}',
          timeZoneName: null,
        ),
        isNull,
      );
    });
  });

  group('the clock the hours are read on', () {
    test('no zone means the phone\'s clock', () {
      final resolved = resolvePlaceHours(
        timeWindowId: null,
        timeWindowName: null,
        timeWindowHoursText: null,
        ownHoursText: monToFri.encode(),
        timeZoneName: null,
      );

      expect(resolved, isNotNull);
      expect(resolved!.location, isNull);
    });

    test('a known zone is the place\'s own clock', () {
      final resolved = resolvePlaceHours(
        timeWindowId: null,
        timeWindowName: null,
        timeWindowHoursText: null,
        ownHoursText: monToFri.encode(),
        timeZoneName: 'Europe/Berlin',
      );

      expect(resolved, isNotNull);
      expect(resolved!.location, isNotNull);
      expect(resolved.location!.name, 'Europe/Berlin');
    });

    test('a zone the tz database does not know resolves to nothing', () {
      expect(
        resolvePlaceHours(
          timeWindowId: null,
          timeWindowName: null,
          timeWindowHoursText: null,
          ownHoursText: monToFri.encode(),
          timeZoneName: 'Nowhere/Special',
        ),
        isNull,
      );
    });

    test('the hours open on the place\'s clock, not the phone\'s', () {
      // 10:00 UTC is 11:00 in Berlin in winter: the store is open there, and
      // the instant is the same whatever clock the phone reads it on.
      final resolved = resolvePlaceHours(
        timeWindowId: null,
        timeWindowName: null,
        timeWindowHoursText: null,
        ownHoursText: monToFri.encode(),
        timeZoneName: 'Europe/Berlin',
      );

      expect(resolved, isNotNull);
      expect(
        resolved!.hours.isOpenAt(
          DateTime.utc(2026, 1, 14, 10),
          location: resolved.location,
        ),
        isTrue,
      );
      expect(
        resolved.hours.isOpenAt(
          DateTime.utc(2026, 1, 14, 9, 59),
          location: resolved.location,
        ),
        isFalse,
      );
    });
  });

  test('a place with no hours at all resolves to nothing', () {
    expect(
      resolvePlaceHours(
        timeWindowId: null,
        timeWindowName: null,
        timeWindowHoursText: null,
        ownHoursText: null,
        timeZoneName: null,
      ),
      isNull,
    );
  });
}
