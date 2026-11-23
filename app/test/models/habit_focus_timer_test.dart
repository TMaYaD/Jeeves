import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_focus_timer.dart';
import 'package:jeeves/providers/sprint_timer_provider.dart' show SprintPhase, SprintTimerState;
import 'package:jeeves/sync/collection_codecs.dart' show encodeInstant;

final _start = DateTime.utc(2026, 11, 18, 9, 0, 0);

HabitTimeLog _log() => HabitTimeLog(
    id: 'l1',
    userId: 'u',
    habitId: 'h1',
    startedAt: encodeInstant(_start)!,
    endedAt: null);

HabitSprint _sprint(String id, DateTime start, {DateTime? end, int minutes = 25}) =>
    HabitSprint(
        id: id,
        userId: 'u',
        habitId: 'h1',
        startedAt: encodeInstant(start)!,
        endedAt: end == null ? null : encodeInstant(end),
        plannedDurationMinutes: minutes);

void main() {
  SprintTimerState derive({
    required List<HabitSprint> sprints,
    required DateTime now,
    bool open = true,
    int? estimate = 60,
  }) =>
      deriveHabitSprintTimerState(
        openLog: open ? _log() : null,
        sprints: sprints,
        sprintMinutesSetting: 25,
        breakMinutesSetting: 5,
        longBreakMinutesSetting: 15,
        sprintsBeforeLongBreakSetting: 4,
        estimateMinutes: estimate,
        now: now,
        habitTitle: 'Meditate',
      );

  test('no open log is idle', () {
    final state = derive(sprints: const [], now: _start, open: false);
    expect(state.phase, SprintPhase.idle);
    expect(state.activeTaskId, isNull);
  });

  test('a running sprint counts down', () {
    final state = derive(
        sprints: [_sprint('s1', _start)],
        now: _start.add(const Duration(minutes: 10)));
    expect(state.phase, SprintPhase.focus);
    expect(state.remaining, const Duration(minutes: 15));
    expect(state.activeTaskId, 'h1');
    expect(state.activeTaskTitle, 'Meditate');
  });

  test('past its length a sprint reads as focus overtime', () {
    final state = derive(
        sprints: [_sprint('s1', _start)],
        now: _start.add(const Duration(minutes: 30)));
    expect(state.phase, SprintPhase.focusOvertime);
    expect(state.overtime, const Duration(minutes: 5));
  });

  test('an ended sprint is a break, then break overtime', () {
    final end = _start.add(const Duration(minutes: 25));
    final sprints = [_sprint('s1', _start, end: end)];
    final inBreak = derive(
        sprints: sprints, now: end.add(const Duration(minutes: 2)));
    expect(inBreak.phase, SprintPhase.break_);
    expect(inBreak.remaining, const Duration(minutes: 3));
    final late = derive(
        sprints: sprints, now: end.add(const Duration(minutes: 7)));
    expect(late.phase, SprintPhase.breakOvertime);
    expect(late.overtime, const Duration(minutes: 2));
  });

  test('an open log with no sprint is idle and names sprint 1', () {
    final state = derive(sprints: const [], now: _start);
    expect(state.phase, SprintPhase.idle);
    expect(state.sprintNumber, 1);
  });

  test('the sprint hint comes from the estimate', () {
    final sprints = [_sprint('s1', _start)];
    expect(derive(sprints: sprints, now: _start, estimate: 60).totalSprints, 3);
    expect(derive(sprints: sprints, now: _start, estimate: 10).totalSprints, 1);
    expect(derive(sprints: sprints, now: _start, estimate: null).totalSprints, 1);
  });

  test('the second sprint is number 2', () {
    final s1End = _start.add(const Duration(minutes: 25));
    final s2Start = s1End.add(const Duration(minutes: 5));
    final state = derive(
        sprints: [_sprint('s1', _start, end: s1End), _sprint('s2', s2Start)],
        now: s2Start.add(const Duration(minutes: 1)));
    expect(state.phase, SprintPhase.focus);
    expect(state.sprintNumber, 2);
  });

  test('the break after the fourth sprint is the long one', () {
    final sprints = <HabitSprint>[];
    var end = _start;
    for (var n = 0; n < 4; n++) {
      final start = n == 0 ? _start : end.add(const Duration(minutes: 5));
      end = start.add(const Duration(minutes: 25));
      sprints.add(_sprint('s$n', start, end: end));
    }
    final state =
        derive(sprints: sprints, now: end.add(const Duration(minutes: 10)));
    expect(state.phase, SprintPhase.break_);
    expect(state.isLongBreak, isTrue);
    expect(state.total, const Duration(minutes: 15));
    expect(state.remaining, const Duration(minutes: 5));
  });

  test('the break after the first sprint stays short', () {
    final end = _start.add(const Duration(minutes: 25));
    final state = derive(
        sprints: [_sprint('s1', _start, end: end)],
        now: end.add(const Duration(minutes: 1)));
    expect(state.isLongBreak, isFalse);
    expect(state.total, const Duration(minutes: 5));
  });
}
