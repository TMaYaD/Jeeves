import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/time_context.dart';

void main() {
  group('encode / tryParse', () {
    test('canonical round-trip with fixed key order', () {
      final tc = TimeContext.create(
        fromDate: DateTime(2026, 11, 30, 15),
        days: {4, 2},
        startMinute: 9 * 60,
        endMinute: 17 * 60,
      )!;
      expect(tc.encode(),
          '{"from":"2026-11-30","days":[2,4],"start":"09:00","end":"17:00"}');
      expect(TimeContext.tryParse(tc.encode()), tc);
    });

    test('from only and days only', () {
      expect(TimeContext.create(fromDate: DateTime(2026, 1, 2))!.encode(),
          '{"from":"2026-01-02"}');
      expect(TimeContext.create(days: {6, 7})!.encode(), '{"days":[6,7]}');
    });

    test('rejections', () {
      expect(TimeContext.create(), isNull);
      expect(TimeContext.create(days: {}), isNull);
      expect(TimeContext.create(days: {0}), isNull);
      expect(TimeContext.create(days: {8}), isNull);
      expect(TimeContext.create(days: {1}, startMinute: 60), isNull);
      expect(
          TimeContext.create(days: {1}, startMinute: 600, endMinute: 600),
          isNull);
      expect(
          TimeContext.create(days: {1}, startMinute: 700, endMinute: 600),
          isNull);
      expect(TimeContext.create(startMinute: 60, endMinute: 120), isNull);
      for (final bad in [
        null,
        '',
        'nope',
        '[]',
        '{}',
        '{"from":"2026-13-01"}',
        '{"from":"2026-02-30"}',
        '{"from":"30/11/2026"}',
        '{"days":[]}',
        '{"days":[1,1]}',
        '{"days":["mon"]}',
        '{"days":[1],"start":"09:00"}',
        '{"days":[1],"start":"17:00","end":"09:00"}',
        '{"days":[1],"start":"9:00","end":"17:00"}',
        '{"days":[1],"extra":1}',
      ]) {
        expect(TimeContext.tryParse(bad), isNull, reason: '$bad');
      }
    });
  });

  group('isSatisfiedAt', () {
    test('from date: midnight boundary', () {
      final tc = TimeContext.create(fromDate: DateTime(2026, 11, 30))!;
      expect(tc.isSatisfiedAt(DateTime(2026, 11, 29, 23, 59)), isFalse);
      expect(tc.isSatisfiedAt(DateTime(2026, 11, 30)), isTrue);
      expect(tc.isSatisfiedAt(DateTime(2027, 1, 1)), isTrue);
    });

    test('window: inclusive start, exclusive end, weekday', () {
      final tc = TimeContext.create(
          days: {2, 4}, startMinute: 540, endMinute: 1020)!;
      // 2026-11-10 is a Tuesday, 11 a Wednesday.
      expect(tc.isSatisfiedAt(DateTime(2026, 11, 10, 8, 59)), isFalse);
      expect(tc.isSatisfiedAt(DateTime(2026, 11, 10, 9)), isTrue);
      expect(tc.isSatisfiedAt(DateTime(2026, 11, 10, 16, 59)), isTrue);
      expect(tc.isSatisfiedAt(DateTime(2026, 11, 10, 17)), isFalse);
      expect(tc.isSatisfiedAt(DateTime(2026, 11, 11, 10)), isFalse);
    });

    test('from and window combine', () {
      final tc = TimeContext.create(
          fromDate: DateTime(2026, 11, 16), days: {2})!;
      expect(tc.isSatisfiedAt(DateTime(2026, 11, 10, 10)), isFalse);
      expect(tc.isSatisfiedAt(DateTime(2026, 11, 17, 10)), isTrue);
    });
  });

  group('nextTransitionAfter', () {
    test('from date ahead, none once passed', () {
      final tc = TimeContext.create(fromDate: DateTime(2026, 11, 30))!;
      expect(tc.nextTransitionAfter(DateTime(2026, 11, 10, 12)),
          DateTime(2026, 11, 30));
      expect(tc.nextTransitionAfter(DateTime(2026, 12, 1)), isNull);
    });

    test('window start and end across a week', () {
      final tc = TimeContext.create(
          days: {2, 4}, startMinute: 540, endMinute: 1020)!;
      // Wed -> Thu 09:00, Thu 10:00 -> Thu 17:00, Thu 18:00 -> next Tue 09:00.
      expect(tc.nextTransitionAfter(DateTime(2026, 11, 11, 12)),
          DateTime(2026, 11, 12, 9));
      expect(tc.nextTransitionAfter(DateTime(2026, 11, 12, 10)),
          DateTime(2026, 11, 12, 17));
      expect(tc.nextTransitionAfter(DateTime(2026, 11, 12, 18)),
          DateTime(2026, 11, 17, 9));
    });

    test('all-day days: transitions at midnight', () {
      final tc = TimeContext.create(days: {6, 7})!;
      expect(tc.nextTransitionAfter(DateTime(2026, 11, 13, 12)),
          DateTime(2026, 11, 14));
      expect(tc.nextTransitionAfter(DateTime(2026, 11, 14, 12)),
          DateTime(2026, 11, 15));
    });

    test('is stable across a DST change (local wall clock)', () {
      // US DST ended 2026-11-01; Sunday. Window Sun 09:00-17:00.
      final tc = TimeContext.create(
          days: {7}, startMinute: 540, endMinute: 1020)!;
      expect(tc.nextTransitionAfter(DateTime(2026, 10, 31, 12)),
          DateTime(2026, 11, 1, 9));
    });
  });

  test('describe', () {
    expect(
        TimeContext.create(
                fromDate: DateTime(2026, 11, 30),
                days: {2, 4},
                startMinute: 540,
                endMinute: 1020)!
            .describe(),
        'From 30 Nov · Tue, Thu 09:00–17:00');
    expect(TimeContext.create(days: {1, 2, 3, 4, 5, 6, 7})!.describe(),
        'Every day');
  });
}
