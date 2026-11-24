import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/time_window_hours.dart';

void main() {
  // 2026-11-09 is a Monday, 2026-11-14 a Saturday, 2026-11-15 a Sunday.
  final mondayNoon = DateTime(2026, 11, 9, 12, 0);

  group('create', () {
    test('refuses an empty set of days', () {
      expect(TimeWindowHours.create({}), isNull);
    });

    test('refuses a day outside Monday to Sunday', () {
      expect(
        TimeWindowHours.create({
          0: (startMinute: 9 * 60, endMinute: 17 * 60),
        }),
        isNull,
      );
      expect(
        TimeWindowHours.create({
          8: (startMinute: 9 * 60, endMinute: 17 * 60),
        }),
        isNull,
      );
    });

    test('refuses a day that starts and ends at the same minute', () {
      expect(
        TimeWindowHours.create({
          1: (startMinute: 9 * 60, endMinute: 9 * 60),
        }),
        isNull,
      );
    });

    test('refuses a clock outside the day', () {
      expect(
        TimeWindowHours.create({
          1: (startMinute: -1, endMinute: 17 * 60),
        }),
        isNull,
      );
      expect(
        TimeWindowHours.create({
          1: (startMinute: 9 * 60, endMinute: 24 * 60 + 1),
        }),
        isNull,
      );
    });

    test('allows a window that ends at midnight and one that runs past it', () {
      expect(
        TimeWindowHours.create({
          1: (startMinute: 9 * 60, endMinute: 24 * 60),
        }),
        isNotNull,
      );
      expect(
        TimeWindowHours.create({
          1: (startMinute: 22 * 60, endMinute: 2 * 60),
        }),
        isNotNull,
      );
    });
  });

  group('encode / tryParse', () {
    test('canonical round-trip with fixed key order', () {
      final hours = TimeWindowHours.create({
        1: (startMinute: 11 * 60, endMinute: 20 * 60),
        6: (startMinute: 10 * 60, endMinute: 14 * 60),
      })!;
      expect(
        hours.encode(),
        '[{"day":1,"start":"11:00","end":"20:00"},'
        '{"day":6,"start":"10:00","end":"14:00"}]',
      );
      final parsed = TimeWindowHours.tryParse(hours.encode())!;
      expect(parsed.encode(), hours.encode());
      expect(parsed, hours);
    });

    test('the same days in another order encode to the same bytes', () {
      final one = TimeWindowHours.create({
        6: (startMinute: 10 * 60, endMinute: 14 * 60),
        1: (startMinute: 11 * 60, endMinute: 20 * 60),
      })!;
      final other = TimeWindowHours.create({
        1: (startMinute: 11 * 60, endMinute: 20 * 60),
        6: (startMinute: 10 * 60, endMinute: 14 * 60),
      })!;
      expect(one.encode(), other.encode());
    });

    test('a window past midnight round-trips', () {
      final hours = TimeWindowHours.create({
        1: (startMinute: 22 * 60, endMinute: 2 * 60),
      })!;
      expect(hours.encode(), '[{"day":1,"start":"22:00","end":"02:00"}]');
      expect(TimeWindowHours.tryParse(hours.encode())!.encode(), hours.encode());
    });

    test('tryParse refuses anything it cannot read', () {
      for (final bad in [
        null,
        '',
        'nope',
        '{}',
        '[]',
        '[{"day":1,"start":"09:00","end":"17:00","extra":1}]',
        '[{"day":1,"start":"09:00","end":"17:00"},'
            '{"day":1,"start":"10:00","end":"18:00"}]',
        '[{"day":0,"start":"09:00","end":"17:00"}]',
        '[{"day":8,"start":"09:00","end":"17:00"}]',
        '[{"day":1,"start":"09:00","end":"09:00"}]',
        '[{"day":1,"start":"25:00","end":"17:00"}]',
        '[{"day":1,"start":"09:00","end":"25:00"}]',
        '[{"day":1,"start":"9:00","end":"17:00"}]',
        '[{"day":"1","start":"09:00","end":"17:00"}]',
        '[{"day":1,"start":"09:00"}]',
        '[{"day":1,"end":"17:00"}]',
        '[{"day":1,"start":"09:00","end":"17:00"',
        '[1,2]',
      ]) {
        expect(TimeWindowHours.tryParse(bad), isNull, reason: '$bad');
      }
    });
  });

  group('isOpenAt', () {
    test('store hours: open from the first minute, closed at the last', () {
      final store = TimeWindowHours.create({
        1: (startMinute: 11 * 60, endMinute: 20 * 60),
        2: (startMinute: 11 * 60, endMinute: 20 * 60),
        3: (startMinute: 11 * 60, endMinute: 20 * 60),
        4: (startMinute: 11 * 60, endMinute: 20 * 60),
        5: (startMinute: 11 * 60, endMinute: 20 * 60),
        6: (startMinute: 10 * 60, endMinute: 14 * 60),
      })!;

      expect(store.isOpenAt(mondayNoon), isTrue);
      expect(store.isOpenAt(DateTime(2026, 11, 9, 11, 0)), isTrue);
      expect(store.isOpenAt(DateTime(2026, 11, 9, 19, 59)), isTrue);
      expect(store.isOpenAt(DateTime(2026, 11, 9, 20, 0)), isFalse);
      expect(store.isOpenAt(DateTime(2026, 11, 10, 10, 59)), isFalse);
      expect(store.isOpenAt(DateTime(2026, 11, 15, 12, 0)), isFalse);
      expect(store.isOpenAt(DateTime(2026, 11, 14, 13, 59)), isTrue);
      expect(store.isOpenAt(DateTime(2026, 11, 14, 14, 0)), isFalse);
    });

    test('night shift: open across midnight, closed at the end', () {
      final night = TimeWindowHours.create({
        1: (startMinute: 22 * 60, endMinute: 2 * 60),
      })!;

      expect(night.isOpenAt(DateTime(2026, 11, 9, 23, 0)), isTrue);
      expect(night.isOpenAt(DateTime(2026, 11, 10, 1, 59)), isTrue);
      expect(night.isOpenAt(DateTime(2026, 11, 10, 2, 0)), isFalse);
      expect(night.isOpenAt(DateTime(2026, 11, 15, 23, 0)), isFalse);
    });

    test('a window that runs past midnight belongs to the day it starts', () {
      final night = TimeWindowHours.create({
        1: (startMinute: 22 * 60, endMinute: 2 * 60),
      })!;

      // Tuesday has no entry, so Wednesday 01:00 is closed.
      expect(night.isOpenAt(DateTime(2026, 11, 11, 1, 0)), isFalse);
      expect(night.isOpenAt(DateTime(2026, 11, 10, 22, 0)), isFalse);
    });
  });

  group('nextTransitionAfter', () {
    final work = TimeWindowHours.create({
      for (var day = 1; day <= 5; day++)
        day: (startMinute: 9 * 60, endMinute: 17 * 60),
    })!;

    test('a weekday window opens at its start and closes at its end', () {
      // Monday 08:00 — closed; the window opens at 09:00.
      expect(
        work.nextTransitionAfter(DateTime(2026, 11, 9, 8, 0)),
        DateTime(2026, 11, 9, 9, 0),
      );
      // Monday 12:00 — open; it closes at 17:00.
      expect(
        work.nextTransitionAfter(DateTime(2026, 11, 9, 12, 0)),
        DateTime(2026, 11, 9, 17, 0),
      );
      // Monday 17:00 exactly — closed; it opens again on Tuesday.
      expect(
        work.nextTransitionAfter(DateTime(2026, 11, 9, 17, 0)),
        DateTime(2026, 11, 10, 9, 0),
      );
    });

    test('the end of the week wraps to Monday', () {
      expect(
        work.nextTransitionAfter(DateTime(2026, 11, 13, 18, 0)),
        DateTime(2026, 11, 16, 9, 0),
      );
    });

    test('a day with no hours is closed and never opens', () {
      // Saturday has no hours: the window stays closed until Monday.
      expect(
        work.nextTransitionAfter(DateTime(2026, 11, 14, 10, 0)),
        DateTime(2026, 11, 16, 9, 0),
      );
    });

    test('an overnight window opens on its day and closes the next morning', () {
      final night = TimeWindowHours.create({
        1: (startMinute: 22 * 60, endMinute: 2 * 60),
      })!;

      // Monday 20:00 — closed; it opens at 22:00.
      expect(
        night.nextTransitionAfter(DateTime(2026, 11, 9, 20, 0)),
        DateTime(2026, 11, 9, 22, 0),
      );
      // Monday 23:00 — open; it closes on Tuesday at 02:00.
      expect(
        night.nextTransitionAfter(DateTime(2026, 11, 9, 23, 0)),
        DateTime(2026, 11, 10, 2, 0),
      );
      // Tuesday 01:00 — still open; the close is an hour away.
      expect(
        night.nextTransitionAfter(DateTime(2026, 11, 10, 1, 0)),
        DateTime(2026, 11, 10, 2, 0),
      );
      // Tuesday 02:00 — closed; it opens again next Monday.
      expect(
        night.nextTransitionAfter(DateTime(2026, 11, 10, 2, 0)),
        DateTime(2026, 11, 16, 22, 0),
      );
    });

    test('a boundary that does not change the open state is not a transition',
        () {
      // Every day is open all day, so no hour boundary flips anything.
      final allDay = TimeWindowHours.create({
        for (var day = 1; day <= 7; day++)
          day: (startMinute: 0, endMinute: 24 * 60),
      })!;
      expect(allDay.nextTransitionAfter(DateTime(2026, 11, 9, 12, 0)), isNull);
    });

    test('a window that ends at midnight closes at the next midnight', () {
      final untilMidnight = TimeWindowHours.create({
        1: (startMinute: 9 * 60, endMinute: 24 * 60),
      })!;
      expect(
        untilMidnight.nextTransitionAfter(DateTime(2026, 11, 9, 12, 0)),
        DateTime(2026, 11, 10, 0, 0),
      );
    });
  });

  group('describe', () {
    test('a run of days with the same hours reads as a range', () {
      final work = TimeWindowHours.create({
        for (var day = 1; day <= 5; day++)
          day: (startMinute: 9 * 60, endMinute: 17 * 60),
      })!;

      expect(work.describe(), 'Mon\u2013Fri 09:00\u201317:00');
    });

    test('days with different hours read as separate groups', () {
      final store = TimeWindowHours.create({
        for (var day = 1; day <= 5; day++)
          day: (startMinute: 11 * 60, endMinute: 20 * 60),
        6: (startMinute: 10 * 60, endMinute: 14 * 60),
      })!;

      expect(store.describe(), 'Mon\u2013Fri 11:00\u201320:00 \u00b7 Sat 10:00\u201314:00');
    });

    test('one day reads by name', () {
      final monday = TimeWindowHours.create({
        1: (startMinute: 22 * 60, endMinute: 2 * 60),
      })!;

      expect(monday.describe(), 'Mon 22:00\u201302:00');
    });

    test('every day reads as Every day', () {
      final all = TimeWindowHours.create({
        for (var day = 1; day <= 7; day++)
          day: (startMinute: 9 * 60, endMinute: 17 * 60),
      })!;

      expect(all.describe(), 'Every day 09:00\u201317:00');
    });

    test('a window that ends at midnight says so', () {
      final untilMidnight = TimeWindowHours.create({
        1: (startMinute: 9 * 60, endMinute: 24 * 60),
      })!;

      expect(untilMidnight.describe(), 'Mon 09:00\u201324:00');
    });

    test('days that are not neighbours read as separate groups', () {
      // Monday and Wednesday share their hours, but Tuesday is closed: the
      // range "Mon\u2013Wed" would say otherwise.
      final store = TimeWindowHours.create({
        1: (startMinute: 9 * 60, endMinute: 17 * 60),
        3: (startMinute: 9 * 60, endMinute: 17 * 60),
      })!;

      expect(
        store.describe(),
        'Mon 09:00\u201317:00 \u00b7 Wed 09:00\u201317:00',
      );
    });

    test('a Monday and a Sunday are not every day', () {
      final week = TimeWindowHours.create({
        1: (startMinute: 9 * 60, endMinute: 17 * 60),
        7: (startMinute: 9 * 60, endMinute: 17 * 60),
      })!;

      expect(
        week.describe(),
        'Mon 09:00\u201317:00 \u00b7 Sun 09:00\u201317:00',
      );
    });
  });
}
