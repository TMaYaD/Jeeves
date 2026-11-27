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

    test('two stints that start together are read in the same order, '
        'whatever order they arrive in', () {
      final short = TimeLogInterval(
        startedAt: _at(9, 0).toIso8601String(),
        endedAt: _at(9, 10).toIso8601String(),
      );
      final long = TimeLogInterval(
        startedAt: _at(9, 0).toIso8601String(),
        endedAt: _at(9, 20).toIso8601String(),
      );

      // 10 minutes are logged by the stint that ends first, so the limit fell
      // 5 minutes into the other one.
      expect(limitPassedAt(15, [short, long]), _at(9, 5).toUtc());
      expect(limitPassedAt(15, [long, short]), _at(9, 5).toUtc());
    });

    test('an open stint that starts with a closed one is read last', () {
      final closed = TimeLogInterval(
        startedAt: _at(9, 0).toIso8601String(),
        endedAt: _at(9, 10).toIso8601String(),
      );
      final open = TimeLogInterval(startedAt: _at(9, 0).toIso8601String());

      expect(limitPassedAt(15, [closed, open]), _at(9, 5).toUtc());
      expect(limitPassedAt(15, [open, closed]), _at(9, 5).toUtc());
    });
  });

  group('loggedDurationOn', () {
    test('is nothing when nothing was logged', () {
      expect(loggedDurationOn(const [], _at(9, 0)), Duration.zero);
    });

    test('adds up the closed stints', () {
      final logged = loggedDurationOn([
        TimeLogInterval(
          startedAt: _at(9, 0).toIso8601String(),
          endedAt: _at(9, 15).toIso8601String(),
        ),
        TimeLogInterval(
          startedAt: _at(9, 20).toIso8601String(),
          endedAt: _at(9, 50).toIso8601String(),
        ),
      ], _at(10, 0));

      expect(logged, const Duration(minutes: 45));
    });

    test('an open stint counts on to now', () {
      final logged = loggedDurationOn([
        TimeLogInterval(
          startedAt: _at(9, 0).toIso8601String(),
          endedAt: _at(9, 15).toIso8601String(),
        ),
        TimeLogInterval(startedAt: _at(9, 20).toIso8601String()),
      ], _at(9, 50));

      // 15 minutes closed, and the open stint has run on for 30.
      expect(logged, const Duration(minutes: 45));
    });

    test('a stint that ends before it starts counts for nothing', () {
      final logged = loggedDurationOn([
        TimeLogInterval(
          startedAt: _at(9, 10).toIso8601String(),
          endedAt: _at(9, 0).toIso8601String(),
        ),
        TimeLogInterval(
          startedAt: _at(9, 0).toIso8601String(),
          endedAt: _at(9, 10).toIso8601String(),
        ),
      ], _at(9, 30));

      expect(logged, const Duration(minutes: 10));
    });

    test('a stint whose start does not parse is skipped, not fatal', () {
      final logged = loggedDurationOn([
        TimeLogInterval(
          startedAt: 'not a timestamp',
          endedAt: _at(9, 30).toIso8601String(),
        ),
        TimeLogInterval(
          startedAt: _at(9, 0).toIso8601String(),
          endedAt: _at(9, 30).toIso8601String(),
        ),
      ], _at(10, 0));

      expect(logged, const Duration(minutes: 30));
    });

    test('the time logged and the limit never disagree', () {
      final stintSets = <List<TimeLogInterval>>[
        // One closed stint.
        [
          TimeLogInterval(
            startedAt: _at(9, 0).toIso8601String(),
            endedAt: _at(9, 30).toIso8601String(),
          ),
        ],
        // A closed stint, then one still running.
        [
          TimeLogInterval(
            startedAt: _at(9, 0).toIso8601String(),
            endedAt: _at(9, 20).toIso8601String(),
          ),
          TimeLogInterval(startedAt: _at(9, 25).toIso8601String()),
        ],
        // A stint that ends before it starts, and one that does not parse.
        [
          TimeLogInterval(
            startedAt: _at(9, 10).toIso8601String(),
            endedAt: _at(9, 0).toIso8601String(),
          ),
          TimeLogInterval(startedAt: 'not a timestamp'),
          TimeLogInterval(
            startedAt: _at(9, 0).toIso8601String(),
            endedAt: _at(9, 40).toIso8601String(),
          ),
        ],
      ];
      final now = _at(10, 0);

      for (final intervals in stintSets) {
        for (final value in [5, 15, 30, 45, 55, 60, 90, 120]) {
          final logged = loggedDurationOn(intervals, now);
          final passed = limitPassedAt(value, intervals);
          expect(
            Duration(minutes: value) > logged,
            passed == null || passed.isAfter(now),
            reason:
                '$value minutes against $logged logged; the limit passed at '
                '$passed',
          );
        }
      }
    });
  });
}
