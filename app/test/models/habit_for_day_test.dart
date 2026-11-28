/// Which days a Habit is for: the rule the Habit notification and the arrival
/// notification share. Pure: histories are hand-built.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart'
    show Habit, HabitCheckIn, HabitInactivePeriod;
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/models/habit_for_day.dart';
import 'package:jeeves/models/habit_progress.dart';

var _sequence = 0;

Habit _habit(String id) => Habit(
      id: id,
      userId: 'user-1',
      title: 'Workout',
      anchorKind: 'none',
      createdAt: '2026-11-02T09:00:00.000Z',
    );

HabitCommitment _commitment(
  String habitId, {
  HabitRepeatKind repeatKind = HabitRepeatKind.everyDay,
  List<int>? chosenWeekdays,
  int? timesPerPeriod,
}) =>
    HabitCommitment(
      id: 'c-${_sequence++}',
      habitId: habitId,
      chosenOn: '2026-11-02',
      createdAt: DateTime.utc(2026, 11, 2, 9, 0, _sequence),
      repeatKind: repeatKind,
      chosenWeekdays: chosenWeekdays,
      timesPerPeriod: timesPerPeriod,
    );

HabitCheckIn _checkIn(String habitId, String day) => HabitCheckIn(
      id: 'ci-${_sequence++}',
      userId: 'user-1',
      habitId: habitId,
      countsForDay: day,
      checkedInAt: '${day}T12:00:00.000Z',
    );

HabitInactivePeriod _pause(String habitId, String from, {String? until}) =>
    HabitInactivePeriod(
      id: 'ip-${_sequence++}',
      userId: 'user-1',
      habitId: habitId,
      kind: 'paused',
      startsOn: from,
      endsBefore: until,
    );

// Friday 20 November 2026 is "today"; Monday the 16th starts its week.
final _today = DateTime.utc(2026, 11, 20);

DateTime _day(int dayOfMonth) => DateTime.utc(2026, 11, dayOfMonth);

bool _isFor(HabitHistory history, DateTime day) => isHabitForDay(
      history,
      computeHabitProgress(history, _today),
      day: day,
      today: _today,
    );

void main() {
  group('an every-day Habit', () {
    test('is for today until it is checked in', () {
      final open = HabitHistory(
        habit: _habit('h'),
        commitments: [_commitment('h')],
      );
      final done = HabitHistory(
        habit: _habit('h'),
        commitments: [_commitment('h')],
        checkIns: [_checkIn('h', '2026-11-20')],
      );

      expect(_isFor(open, _today), isTrue);
      expect(_isFor(done, _today), isFalse);
      // Tomorrow is still ahead of the Check-in.
      expect(_isFor(done, _day(21)), isTrue);
    });

    test('is for no day a pause covers', () {
      final history = HabitHistory(
        habit: _habit('h'),
        commitments: [_commitment('h')],
        inactivePeriods: [_pause('h', '2026-11-21', until: '2026-11-23')],
      );

      expect(_isFor(history, _day(21)), isFalse);
      expect(_isFor(history, _day(22)), isFalse);
      expect(_isFor(history, _day(23)), isTrue);
    });
  });

  test('a chosen-weekdays Habit is for its weekdays only', () {
    final history = HabitHistory(
      habit: _habit('h'),
      // Monday, Wednesday.
      commitments: [
        _commitment(
          'h',
          repeatKind: HabitRepeatKind.chosenWeekdays,
          chosenWeekdays: [1, 3],
        ),
      ],
    );

    expect(_isFor(history, _today), isFalse); // Friday
    expect(_isFor(history, _day(23)), isTrue); // Monday
    expect(_isFor(history, _day(24)), isFalse); // Tuesday
    expect(_isFor(history, _day(25)), isTrue); // Wednesday
  });

  test('a 3-per-week Habit stops being for the week once it reaches 3', () {
    final history = HabitHistory(
      habit: _habit('h'),
      commitments: [
        _commitment('h',
            repeatKind: HabitRepeatKind.timesPerWeek, timesPerPeriod: 3),
      ],
      checkIns: [
        _checkIn('h', '2026-11-16'),
        _checkIn('h', '2026-11-17'),
        _checkIn('h', '2026-11-18'),
      ],
    );

    expect(_isFor(history, _today), isFalse);
    expect(_isFor(history, _day(22)), isFalse); // Sunday, same week
    expect(_isFor(history, _day(23)), isTrue); // next Monday
  });
}
