/// Jeeves' advice before a Sprint past a Timeboxed limit, and the limit
/// itself (issue #923).
///
/// The tone grows firmer with each further Sprint past the limit, and the
/// number is said in words rather than left to the reader to count.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/models/timeboxed.dart';

void main() {
  group('the limit', () {
    final passed = DateTime.utc(2026, 11, 16, 9, 30);

    TimeboxedLimitStatus status({DateTime? limitPassedAt}) {
      return TimeboxedLimitStatus(
        limitMinutes: 30,
        limitPassedAt: limitPassedAt,
        sprintsBeforeLimit: 0,
        sprintsPastLimit: 0,
        sprintStarts: const [],
      );
    }

    test('a limit that has not been reached has not passed', () {
      expect(status().hasPassedAt(passed), isFalse);
    });

    test('a limit passed an hour ago has passed', () {
      expect(
        status(limitPassedAt: passed.subtract(const Duration(hours: 1)))
            .hasPassedAt(passed),
        isTrue,
      );
    });

    test('a limit that has not arrived yet has not passed', () {
      // An open stint runs on, so the limit is reached inside it — at an
      // instant that has not come yet. Nothing may say it has passed.
      expect(
        status(limitPassedAt: passed.add(const Duration(minutes: 5)))
            .hasPassedAt(passed),
        isFalse,
      );
    });

    test('the moment itself counts as passed', () {
      expect(status(limitPassedAt: passed).hasPassedAt(passed), isTrue);
    });
  });

  group('the advice', () {
    test('the first Sprint past the limit states the fact', () {
      final advice = timeboxedAdviceFor(1);

      expect(advice.headline, contains('run its course'));
      expect(advice.detail, contains('first beyond it'));
    });

    test('the second past the limit notes the habit', () {
      final advice = timeboxedAdviceFor(2);

      expect(advice.headline, contains('second past the limit'));
      expect(advice.detail, contains('habit'));
    });

    test('the third and beyond say the day is moving on', () {
      final advice = timeboxedAdviceFor(3);

      expect(advice.headline, contains('third past the limit'));
      expect(advice.detail, contains('beginning to notice'));
    });

    test('each further Sprint names its own number', () {
      expect(timeboxedAdviceFor(4).headline, contains('fourth past the limit'));
      expect(timeboxedAdviceFor(5).headline, contains('fifth past the limit'));
    });

    test('a count of one or less is the first past the limit', () {
      // The caller does not ask before the limit has passed, but the advice
      // must still say something sensible if it is asked.
      expect(timeboxedAdviceFor(0).headline, contains('run its course'));
    });
  });

  group('the ordinal', () {
    test('says the usual ones', () {
      expect(englishOrdinal(1), '1st');
      expect(englishOrdinal(2), '2nd');
      expect(englishOrdinal(3), '3rd');
      expect(englishOrdinal(4), '4th');
    });

    test('says the teens with "th"', () {
      expect(englishOrdinal(11), '11th');
      expect(englishOrdinal(12), '12th');
      expect(englishOrdinal(13), '13th');
    });

    test('says the twenties with the usual endings', () {
      expect(englishOrdinal(21), '21st');
      expect(englishOrdinal(22), '22nd');
      expect(englishOrdinal(23), '23rd');
    });
  });
}
