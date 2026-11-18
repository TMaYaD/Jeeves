/// [deriveSprintTimerState]: the timer's whole state as a pure function of the
/// recorded Sprints, the open TimeLog and `now` (issue #910).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/daos/sprint_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/sprint_timer_provider.dart';

final DateTime _logStart = DateTime.utc(2026, 7, 28, 9);

TimeLog _log({String actionId = 'a1'}) => TimeLog(
      id: 'log-1',
      userId: 'u',
      taskId: 'task-1',
      actionId: actionId,
      startedAt: _logStart.toIso8601String(),
      endedAt: null,
      focusSessionId: null,
    );

SprintRecord _sprint(
  String id,
  int startMinute, {
  int? endMinute,
  int length = 25,
  String actionId = 'a1',
}) {
  final start = _logStart.add(Duration(minutes: startMinute));
  final end =
      endMinute == null ? null : _logStart.add(Duration(minutes: endMinute));
  return SprintRecord(
    id: id,
    userId: 'u',
    actionId: actionId,
    startedAtUtc: start,
    endedAtUtc: end,
    storedEndedAtUtc: end,
    plannedDurationMinutes: length,
  );
}

SprintTimerState _derive(
  List<SprintRecord> sprints,
  int nowMinute, {
  TimeLog? log,
  int nowSecond = 0,
  String? suppressed,
}) =>
    deriveSprintTimerState(
      sprints: sprints,
      activeLog: log ?? _log(),
      activeTask: null,
      sprintMinutesSetting: 25,
      breakMinutesSetting: 5,
      now: _logStart.add(Duration(minutes: nowMinute, seconds: nowSecond)),
      suppressedSprintId: suppressed,
    );

void main() {
  test('no open TimeLog is idle', () {
    final state = deriveSprintTimerState(
      sprints: [_sprint('s1', 0)],
      activeLog: null,
      activeTask: null,
      sprintMinutesSetting: 25,
      breakMinutesSetting: 5,
      now: _logStart,
    );
    expect(state.phase, SprintPhase.idle);
  });

  test('a running Sprint counts down from its recorded start and length', () {
    final state = _derive([_sprint('s1', 0)], 10);
    expect(state.phase, SprintPhase.focus);
    expect(state.remaining, const Duration(minutes: 15));
    expect(state.total, const Duration(minutes: 25));
    expect(state.sprintNumber, 1);
    expect(state.activeTaskId, 'task-1');
  });

  test('uses the length recorded with the Sprint, not the current setting', () {
    final state = _derive([_sprint('s1', 0, length: 40)], 10);
    expect(state.total, const Duration(minutes: 40));
    expect(state.sprintDurationMinutes, 40);
  });

  test('past its length a running Sprint reads as overtime, never as a break',
      () {
    final state = _derive([_sprint('s1', 0)], 30);
    expect(state.phase, SprintPhase.focusOvertime);
    expect(state.overtime, const Duration(minutes: 5));
  });

  test('overtime is capped at one Sprint length', () {
    final state = _derive([_sprint('s1', 0)], 600);
    expect(state.phase, SprintPhase.focusOvertime);
    expect(state.overtime, const Duration(minutes: 25));
  });

  test('a closed latest Sprint is a break counted from its end', () {
    final state = _derive([_sprint('s1', 0, endMinute: 20)], 22);
    expect(state.phase, SprintPhase.break_);
    expect(state.remaining, const Duration(minutes: 3));
    expect(state.sprintNumber, 1);
  });

  test('a break past its length reads as break overtime', () {
    final state = _derive([_sprint('s1', 0, endMinute: 20)], 28);
    expect(state.phase, SprintPhase.breakOvertime);
    expect(state.overtime, const Duration(minutes: 3));
  });

  test('sprintNumber counts the recorded Sprints on the Action, running included',
      () {
    final state = _derive([
      _sprint('s1', 0, endMinute: 25),
      _sprint('s2', 30, endMinute: 55),
      _sprint('other', 56, endMinute: 57, actionId: 'a2'),
      _sprint('s3', 60),
    ], 62, log: _log());
    // The latest Sprint belongs to a1, so it is the third on that Action.
    expect(state.phase, SprintPhase.focus);
    expect(state.sprintNumber, 3);
  });

  test('a Sprint on another Action does not make this Action\'s timer active',
      () {
    final state = _derive([_sprint('s1', 0, actionId: 'a2')], 5);
    expect(state.phase, SprintPhase.idle);
    expect(state.sprintNumber, 1);
  });

  test('a Sprint that ended before the TimeLog opened is not a break', () {
    final state = _derive([_sprint('s1', -60, endMinute: -35)], 1);
    expect(state.phase, SprintPhase.idle);
    expect(state.sprintNumber, 2);
  });

  test('a Sprint stopped on this device never reads as a break', () {
    final state =
        _derive([_sprint('s1', 0, endMinute: 10)], 11, suppressed: 's1');
    expect(state.phase, SprintPhase.idle);
  });

  test('totalSprints keeps max(ceil(estimate / length), sprintNumber)', () {
    final state = _derive([
      _sprint('s1', 0, endMinute: 25),
      _sprint('s2', 30, endMinute: 55),
      _sprint('s3', 60),
    ], 62);
    expect(state.totalSprints, 3);
  });

  test('lastBreakEndedAt is the latest Sprint start once an earlier one exists',
      () {
    expect(_derive([_sprint('s1', 0)], 1).lastBreakEndedAt, isNull);
    final state =
        _derive([_sprint('s1', 0, endMinute: 25), _sprint('s2', 30)], 31);
    expect(state.lastBreakEndedAt!.toUtc(),
        _logStart.add(const Duration(minutes: 30)));
  });

  test('the timer reads no Sprint state from device-only storage', () {
    final source =
        File('lib/providers/sprint_timer_provider.dart').readAsStringSync();
    expect(source, isNot(contains('shared_preferences')));
    expect(source, isNot(contains('SharedPreferences')));
  });
}
