/// The estimate ladder (issue #923).
///
/// One ladder, so an estimate means the same number of minutes wherever it was
/// set — and so the stepper the estimate sheet offers walks the same values
/// the clarify card lists.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/models/estimate.dart';

void main() {
  group('the ladder', () {
    test('the shared options come first, in order', () {
      expect(
        estimateLadderMinutes.sublist(0, kEstimateOptionsMinutes.length),
        kEstimateOptionsMinutes,
      );
    });

    test('the steps continue in half hours to the top', () {
      expect(estimateLadderMinutes, contains(150));
      expect(estimateLadderMinutes, contains(180));
      expect(estimateLadderMinutes, contains(210));
      expect(estimateLadderMinutes.last, kMaxEstimateMinutes);
      expect(
        estimateLadderMinutes.any((m) => m > kMaxEstimateMinutes),
        isFalse,
      );
    });

    test('the ladder never repeats a value', () {
      expect(
        estimateLadderMinutes.toSet(),
        hasLength(estimateLadderMinutes.length),
      );
    });
  });

  group('stepping down', () {
    test('steps to the next value below', () {
      expect(stepEstimateDown(30), 15);
      expect(stepEstimateDown(10), 5);
      expect(stepEstimateDown(120), 90);
    });

    test('below the shortest value there is no estimate', () {
      expect(stepEstimateDown(5), isNull);
      expect(stepEstimateDown(null), isNull);
    });

    test('a value off the ladder steps to the nearest one below it', () {
      expect(stepEstimateDown(25), 15);
      expect(stepEstimateDown(130), 120);
    });
  });

  group('stepping up', () {
    test('steps to the next value above', () {
      expect(stepEstimateUp(5), 10);
      expect(stepEstimateUp(15), 30);
      expect(stepEstimateUp(120), 150);
    });

    test('from no estimate the shortest value is one step up', () {
      expect(stepEstimateUp(null), 5);
    });

    test('at the top of the ladder there is nowhere to go', () {
      expect(stepEstimateUp(kMaxEstimateMinutes), isNull);
    });

    test('a value off the ladder steps to the nearest one above it', () {
      expect(stepEstimateUp(25), 30);
      expect(stepEstimateUp(130), 150);
    });
  });
}
