/// The "about N sprints" hint is a hint, not a target (issue #912).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/utils/sprint_hint.dart';

void main() {
  group('sprintHintLabel', () {
    test('a 60-minute estimate at 20 minutes a Sprint reads "about 3 sprints"',
        () {
      expect(
        sprintHintLabel(timeEstimateMinutes: 60, sprintDurationMinutes: 20),
        'about 3 sprints',
      );
    });

    test('the count is rounded up', () {
      expect(
        sprintHintLabel(timeEstimateMinutes: 61, sprintDurationMinutes: 20),
        'about 4 sprints',
      );
    });

    test('an estimate of one Sprint or less still reads "about 1 sprint"', () {
      expect(
        sprintHintLabel(timeEstimateMinutes: 20, sprintDurationMinutes: 20),
        'about 1 sprint',
      );
      expect(
        sprintHintLabel(timeEstimateMinutes: 15, sprintDurationMinutes: 20),
        'about 1 sprint',
      );
    });

    test('no estimate has no hint', () {
      expect(
        sprintHintLabel(timeEstimateMinutes: null, sprintDurationMinutes: 20),
        isNull,
      );
    });

    test('a Sprint length of zero has no hint rather than dividing by zero',
        () {
      expect(
        sprintHintLabel(timeEstimateMinutes: 60, sprintDurationMinutes: 0),
        isNull,
      );
    });
  });
}
