/// [longBreakDecision]: which Break after a Sprint is the long one (issue #911).
///
/// The rule is wall time: the number of Sprints before a long Break becomes a
/// time budget, and the Break that would end at or after the budget is the
/// long one. Every case below is one of the story's acceptance criteria.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/daos/sprint_dao.dart';
import 'package:jeeves/models/long_break.dart';

final DateTime _origin = DateTime.utc(2026, 7, 28, 9);

/// A Sprint on the default Action, [start] and [end] as offsets from the run's
/// first Sprint. A null [end] leaves it running.
SprintRecord _sprint(
  String id,
  Duration start, {
  Duration? end,
  String actionId = 'a1',
  int plannedDurationMinutes = 20,
}) {
  final startedAtUtc = _origin.add(start);
  final endedAtUtc = end == null ? null : _origin.add(end);
  return SprintRecord(
    id: id,
    userId: 'u',
    actionId: actionId,
    startedAtUtc: startedAtUtc,
    endedAtUtc: endedAtUtc,
    storedEndedAtUtc: endedAtUtc,
    plannedDurationMinutes: plannedDurationMinutes,
  );
}

/// The decision for the last Sprint of [sprints], at the default settings.
LongBreakDecision _decision(
  List<SprintRecord> sprints, {
  String? sprintId,
  int sprintMinutes = 20,
  int shortBreakMinutes = 3,
  int longBreakMinutes = 15,
  int sprintsBeforeLongBreak = 4,
}) =>
    longBreakDecision(
      sprints: sprints,
      sprintId: sprintId ?? sprints.last.id,
      sprintDurationMinutes: sprintMinutes,
      shortBreakDurationMinutes: shortBreakMinutes,
      longBreakDurationMinutes: longBreakMinutes,
      sprintsBeforeLongBreak: sprintsBeforeLongBreak,
    );

/// Whether the Break after the last Sprint of [sprints] is the long one.
bool _isLong(
  List<SprintRecord> sprints, {
  String? sprintId,
  int sprintMinutes = 20,
  int shortBreakMinutes = 3,
  int longBreakMinutes = 15,
  int sprintsBeforeLongBreak = 4,
}) =>
    _decision(
      sprints,
      sprintId: sprintId,
      sprintMinutes: sprintMinutes,
      shortBreakMinutes: shortBreakMinutes,
      longBreakMinutes: longBreakMinutes,
      sprintsBeforeLongBreak: sprintsBeforeLongBreak,
    ).isLong;

/// Four Sprints in a row at the default timings: 0–20, 23–43, 46–66, 69–89.
List<SprintRecord> _fourSprints() => [
      _sprint('s1', Duration.zero, end: const Duration(minutes: 20)),
      _sprint('s2', const Duration(minutes: 23), end: const Duration(minutes: 43)),
      _sprint('s3', const Duration(minutes: 46), end: const Duration(minutes: 66)),
      _sprint('s4', const Duration(minutes: 69), end: const Duration(minutes: 89)),
    ];

void main() {
  group('with the defaults', () {
    test('the Break after the 4th Sprint in a row is the long one', () {
      final sprints = _fourSprints();
      expect(_isLong(sprints, sprintId: 's4'), isTrue);
    });

    test('the Breaks after Sprints 1–3 are the short one', () {
      final sprints = _fourSprints();
      expect(_isLong(sprints, sprintId: 's1'), isFalse);
      expect(_isLong(sprints, sprintId: 's2'), isFalse);
      expect(_isLong(sprints, sprintId: 's3'), isFalse);
    });

    test('two Sprints stopped after 5 minutes each do not bring it closer', () {
      final sprints = [
        _sprint('s1', Duration.zero, end: const Duration(minutes: 5)),
        _sprint('s2', const Duration(minutes: 8), end: const Duration(minutes: 13)),
        _sprint('s3', const Duration(minutes: 16), end: const Duration(minutes: 36)),
      ];
      expect(_isLong(sprints), isFalse,
          reason: 'a Sprint stopped early spends less of the budget');
    });

    test('Sprints that run over bring the long Break after fewer Sprints', () {
      final sprints = [
        _sprint('s1', Duration.zero, end: const Duration(minutes: 20)),
        _sprint('s2', const Duration(minutes: 23), end: const Duration(minutes: 43)),
        // The third Sprint ran 30 minutes over its 20.
        _sprint('s3', const Duration(minutes: 46), end: const Duration(minutes: 96)),
      ];
      expect(_isLong(sprints, sprintId: 's2'), isFalse);
      expect(_isLong(sprints, sprintId: 's3'), isTrue,
          reason: '96 + 3 minutes is past the 92-minute budget');
    });

    test('three 30-minute Sprints make the third Break the long one', () {
      final sprints = [
        _sprint('s1', Duration.zero, end: const Duration(minutes: 30)),
        _sprint('s2', const Duration(minutes: 33), end: const Duration(minutes: 63)),
        _sprint('s3', const Duration(minutes: 66), end: const Duration(minutes: 96)),
      ];
      expect(_isLong(sprints), isTrue);
    });

    test('the Break ending exactly at the budget is the long one', () {
      // 89 + 3 = 92 minutes, the budget at the defaults.
      final sprints = _fourSprints();
      expect(_isLong(sprints), isTrue);
    });

    test('a Break ending 1 ms short of the budget is the short one', () {
      final sprints = [
        _sprint('s1', Duration.zero, end: const Duration(minutes: 20)),
        _sprint('s2', const Duration(minutes: 23), end: const Duration(minutes: 43)),
        _sprint('s3', const Duration(minutes: 46), end: const Duration(minutes: 66)),
        _sprint(
          's4',
          const Duration(minutes: 69),
          end: const Duration(minutes: 89) - const Duration(milliseconds: 1),
        ),
      ];
      expect(_isLong(sprints), isFalse);
    });
  });

  group('the run the long Break comes from', () {
    test('the run holds the Sprints since the count restarted', () {
      expect(_decision(_fourSprints()).sprintCount, 4);
    });

    test('a Sprint that ran over leaves the run short of the setting', () {
      // Three 30-minute Sprints: the long Break comes after the third, so
      // the run holds three Sprints and not the four the setting names.
      final sprints = [
        _sprint('s1', Duration.zero, end: const Duration(minutes: 30)),
        _sprint('s2', const Duration(minutes: 33), end: const Duration(minutes: 63)),
        _sprint('s3', const Duration(minutes: 66), end: const Duration(minutes: 96)),
      ];
      final decision = _decision(sprints);
      expect(decision.isLong, isTrue);
      expect(decision.sprintCount, 3,
          reason: 'the long Break came after three Sprints, not four');
    });

    test('a gap restarts the run', () {
      // A 15-minute gap: the long Break, taken to its end.
      final sprints = [
        _sprint('s1', Duration.zero, end: const Duration(minutes: 20)),
        _sprint('s2', const Duration(minutes: 23), end: const Duration(minutes: 43)),
        _sprint('s3', const Duration(minutes: 46), end: const Duration(minutes: 66)),
        _sprint('s4', const Duration(minutes: 81), end: const Duration(minutes: 101)),
      ];
      final decision = _decision(sprints, sprintId: 's4');
      expect(decision.isLong, isFalse);
      expect(decision.sprintCount, 1,
          reason: 'the count restarted at the fourth Sprint');
    });

    test('a Sprint that has not ended has no run', () {
      final decision = _decision([
        ..._fourSprints(),
        _sprint('s5', const Duration(minutes: 92)),
      ]);
      expect(decision.sprintCount, 0);
    });

    test('a long Break cut short leaves the run longer than the setting', () {
      // Four Sprints, then a long Break cut short after five minutes: the
      // gap is too short to restart the count, so the fifth Sprint joins the
      // run and the long Break comes after five.
      final sprints = [
        _sprint('s1', Duration.zero, end: const Duration(minutes: 20)),
        _sprint('s2', const Duration(minutes: 23), end: const Duration(minutes: 43)),
        _sprint('s3', const Duration(minutes: 46), end: const Duration(minutes: 66)),
        _sprint('s4', const Duration(minutes: 69), end: const Duration(minutes: 89)),
        _sprint('s5', const Duration(minutes: 94), end: const Duration(minutes: 114)),
      ];
      final decision = _decision(sprints, sprintId: 's5');
      expect(decision.isLong, isTrue,
          reason: 'the count never restarted, so the long Break is offered again');
      expect(decision.sprintCount, 5,
          reason: 'the run holds five Sprints, so the banner may not say four');
    });
  });

  group('the budget', () {
    test('a longer Sprint makes the budget longer', () {
      final sprints = [
        _sprint('s1', Duration.zero, end: const Duration(minutes: 25)),
        _sprint('s2', const Duration(minutes: 28), end: const Duration(minutes: 53)),
        _sprint('s3', const Duration(minutes: 56), end: const Duration(minutes: 81)),
        _sprint('s4', const Duration(minutes: 84), end: const Duration(minutes: 109)),
      ];
      expect(_isLong(sprints, sprintMinutes: 25), isTrue,
          reason: '4 x (25 + 3) = 112 minutes');
      expect(_isLong(sprints, sprintMinutes: 25, sprintId: 's3'), isFalse);
    });

    test('a longer short Break makes the budget longer', () {
      final sprints = [
        _sprint('s1', Duration.zero, end: const Duration(minutes: 20)),
        _sprint('s2', const Duration(minutes: 25), end: const Duration(minutes: 45)),
        _sprint('s3', const Duration(minutes: 50), end: const Duration(minutes: 70)),
        _sprint('s4', const Duration(minutes: 75), end: const Duration(minutes: 95)),
      ];
      expect(_isLong(sprints, shortBreakMinutes: 5), isTrue,
          reason: '4 x (20 + 5) = 100 minutes');
      expect(_isLong(sprints, shortBreakMinutes: 5, sprintId: 's3'), isFalse);
    });

    test('fewer Sprints before a long Break makes the budget shorter', () {
      final sprints = [
        _sprint('s1', Duration.zero, end: const Duration(minutes: 20)),
        _sprint('s2', const Duration(minutes: 23), end: const Duration(minutes: 43)),
      ];
      expect(_isLong(sprints, sprintsBeforeLongBreak: 2), isTrue,
          reason: '2 x (20 + 3) = 46 minutes');
      expect(_isLong(sprints, sprintsBeforeLongBreak: 2, sprintId: 's1'), isFalse);
    });

    test('the long Break length moves the gap threshold, not the budget', () {
      final sprints = _fourSprints();
      expect(_isLong(sprints, longBreakMinutes: 30), isTrue,
          reason: 'the 92-minute budget is unchanged');
    });
  });

  test('Sprints on different Actions count toward the same long Break', () {
    final sprints = [
      _sprint('s1', Duration.zero, end: const Duration(minutes: 20), actionId: 'a1'),
      _sprint('s2', const Duration(minutes: 23), end: const Duration(minutes: 43), actionId: 'a2'),
      _sprint('s3', const Duration(minutes: 46), end: const Duration(minutes: 66), actionId: 'a1'),
      _sprint('s4', const Duration(minutes: 69), end: const Duration(minutes: 89), actionId: 'a2'),
    ];
    expect(_isLong(sprints), isTrue);
  });

  group('a gap restarts the count', () {
    test('a gap of exactly the long Break length restarts it', () {
      final sprints = [
        _sprint('s1', Duration.zero, end: const Duration(minutes: 20)),
        _sprint('s2', const Duration(minutes: 23), end: const Duration(minutes: 43)),
        _sprint('s3', const Duration(minutes: 46), end: const Duration(minutes: 66)),
        // A 15-minute gap: the long Break, taken to its end.
        _sprint('s4', const Duration(minutes: 81), end: const Duration(minutes: 101)),
      ];
      expect(_isLong(sprints, sprintId: 's4'), isFalse,
          reason: 'the count restarted at the second Sprint');
    });

    test('a gap 1 ms shorter than the long Break does not restart it', () {
      final sprints = [
        _sprint('s1', Duration.zero, end: const Duration(minutes: 20)),
        _sprint('s2', const Duration(minutes: 23), end: const Duration(minutes: 43)),
        _sprint('s3', const Duration(minutes: 46), end: const Duration(minutes: 66)),
        _sprint(
          's4',
          const Duration(minutes: 81) - const Duration(milliseconds: 1),
          end: const Duration(minutes: 101) - const Duration(milliseconds: 1),
        ),
      ];
      expect(_isLong(sprints, sprintId: 's4'), isTrue,
          reason: 'the count never restarted, so the budget still applies');
    });

    test('taking the long Break restarts the count', () {
      final sprints = [
        _sprint('s1', Duration.zero, end: const Duration(minutes: 20)),
        _sprint('s2', const Duration(minutes: 23), end: const Duration(minutes: 43)),
        _sprint('s3', const Duration(minutes: 46), end: const Duration(minutes: 66)),
        _sprint('s4', const Duration(minutes: 69), end: const Duration(minutes: 89)),
        // The long Break, taken to its end: a 15-minute gap.
        _sprint('s5', const Duration(minutes: 104), end: const Duration(minutes: 124)),
      ];
      expect(_isLong(sprints, sprintId: 's5'), isFalse);
    });

    test('a long Break cut short does not restart the count', () {
      final sprints = [
        _sprint('s1', Duration.zero, end: const Duration(minutes: 20)),
        _sprint('s2', const Duration(minutes: 23), end: const Duration(minutes: 43)),
        _sprint('s3', const Duration(minutes: 46), end: const Duration(minutes: 66)),
        _sprint('s4', const Duration(minutes: 69), end: const Duration(minutes: 89)),
        // The long Break, cut short after 5 minutes: not a full long Break.
        _sprint('s5', const Duration(minutes: 94), end: const Duration(minutes: 114)),
      ];
      expect(_isLong(sprints, sprintId: 's5'), isTrue,
          reason: 'the count never restarted, so the long Break is offered again');
    });
  });

  test('an open Sprint closed by its successor keeps the run', () {
    // The first Sprint was left open on one device and reads as ending 1 ms
    // before the second Sprint starts.
    final sprints = [
      SprintRecord(
        id: 's1',
        userId: 'u',
        actionId: 'a1',
        startedAtUtc: _origin,
        endedAtUtc: _origin.add(const Duration(minutes: 23) -
            const Duration(milliseconds: 1)),
        storedEndedAtUtc: null,
        plannedDurationMinutes: 20,
      ),
      _sprint('s2', const Duration(minutes: 23), end: const Duration(minutes: 43)),
      _sprint('s3', const Duration(minutes: 46), end: const Duration(minutes: 66)),
      _sprint('s4', const Duration(minutes: 69), end: const Duration(minutes: 89)),
    ];
    expect(_isLong(sprints, sprintId: 's4'), isTrue);
  });

  test('a Sprint that has not ended has no long Break after it', () {
    final sprints = _fourSprints();
    expect(
      _isLong([
        ...sprints,
        _sprint('s5', const Duration(minutes: 92)),
      ]),
      isFalse,
    );
  });

  test('an unknown Sprint reads as short', () {
    expect(_isLong(_fourSprints(), sprintId: 'nope'), isFalse);
  });
}
