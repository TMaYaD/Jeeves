/// When a Timeboxed Action's limit passed (issue #923).
///
/// The rule under test is the whole of `limitPassedAt`: the limit is measured
/// against all time logged on the Action, so the instant it passed is derived
/// from the stints, not stored.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/utils/timeboxed_limit.dart';

DateTime _at(int hour, int minute) => DateTime(2026, 11, 16, hour, minute);

void main() {
  group('limitPassedAt', () {
    test('is null when nothing was logged', () {
      expect(limitPassedAt(30, const []), isNull);
    });

    test('is the start plus the limit, when one stint outlasts it', () {
      final passed = limitPassedAt(20, [
        TimeLogInterval(
          startedAt: _at(9, 0).toIso8601String(),
          endedAt: _at(9, 30).toIso8601String(),
        ),
      ]);

      expect(passed, _at(9, 20).toUtc());
    });

    test('falls in the stint that carried the day over the limit', () {
      final passed = limitPassedAt(20, [
        TimeLogInterval(
          startedAt: _at(9, 0).toIso8601String(),
          endedAt: _at(9, 15).toIso8601String(),
        ),
        TimeLogInterval(
          startedAt: _at(9, 20).toIso8601String(),
          endedAt: _at(9, 35).toIso8601String(),
        ),
      ]);

      // 15 minutes were logged in the first stint; the limit fell 5 minutes
      // into the second.
      expect(passed, _at(9, 25).toUtc());
    });

    test('counts every stint, whatever order they arrive in', () {
      final passed = limitPassedAt(20, [
        TimeLogInterval(
          startedAt: _at(9, 20).toIso8601String(),
          endedAt: _at(9, 35).toIso8601String(),
        ),
        TimeLogInterval(
          startedAt: _at(9, 0).toIso8601String(),
          endedAt: _at(9, 15).toIso8601String(),
        ),
      ]);

      expect(passed, _at(9, 25).toUtc());
    });

    test('an open stint runs on, so the limit can still be ahead', () {
      final passed = limitPassedAt(20, [
        TimeLogInterval(startedAt: _at(9, 0).toIso8601String()),
      ]);

      expect(passed, _at(9, 20).toUtc());
    });

    test('a stint that ends before it starts counts for nothing', () {
      final passed = limitPassedAt(20, [
        // Clock skew: the end is before the start.
        TimeLogInterval(
          startedAt: _at(9, 10).toIso8601String(),
          endedAt: _at(9, 0).toIso8601String(),
        ),
        TimeLogInterval(
          startedAt: _at(9, 0).toIso8601String(),
          endedAt: _at(9, 10).toIso8601String(),
        ),
      ]);

      expect(
        passed,
        isNull,
        reason: '10 minutes is short of a 20 minute limit',
      );
    });

    test('a stint whose start does not parse is skipped, not fatal', () {
      final passed = limitPassedAt(20, [
        TimeLogInterval(
          startedAt: 'not a timestamp',
          endedAt: _at(9, 30).toIso8601String(),
        ),
        TimeLogInterval(
          startedAt: _at(9, 0).toIso8601String(),
          endedAt: _at(9, 30).toIso8601String(),
        ),
      ]);

      expect(passed, _at(9, 20).toUtc());
    });

    test('is null when the logged time never reached the limit', () {
      final passed = limitPassedAt(45, [
        TimeLogInterval(
          startedAt: _at(9, 0).toIso8601String(),
          endedAt: _at(9, 30).toIso8601String(),
        ),
      ]);

      expect(passed, isNull);
    });
  });
}
