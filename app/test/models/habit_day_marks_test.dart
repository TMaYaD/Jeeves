import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart'
    show Habit, HabitCheckIn, HabitInactivePeriod;
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/models/habit_day_marks.dart';
import 'package:jeeves/models/habit_progress.dart';

// Monday 2026-11-02 starts a week. Added to the TZ=America/Los_Angeles CI
// step: days are UTC calendar days, so a clock change must not move one.
final _habitRow = Habit(
  id: 'habit-1',
  userId: 'user-1',
  title: 'Read',
  anchorKind: 'none',
  createdAt: '2026-11-02T09:00:00.000Z',
);

var _sequence = 0;

HabitCommitment _commitment({
  String id = 'c1',
  required String chosenOn,
  HabitRepeatKind repeatKind = HabitRepeatKind.everyDay,
  List<int>? chosenWeekdays,
  int? timesPerPeriod,
  int? intervalDays,
  List<int>? preferredDays,
  String? unitLabel,
  double? dailyTargetAmount,
}) =>
    HabitCommitment(
      id: id,
      habitId: 'habit-1',
      chosenOn: chosenOn,
      createdAt: DateTime.utc(2026, 11, 2, 9, 0, _sequence++),
      repeatKind: repeatKind,
      chosenWeekdays: chosenWeekdays,
      timesPerPeriod: timesPerPeriod,
      intervalDays: intervalDays,
      preferredDays: preferredDays,
      unitLabel: unitLabel,
      dailyTargetAmount: dailyTargetAmount,
    );

HabitCheckIn _checkIn(String day, {double? amount}) => HabitCheckIn(
      id: 'ci-${_sequence++}',
      userId: 'user-1',
      habitId: 'habit-1',
      countsForDay: day,
      checkedInAt: '${day}T12:00:00.000Z',
      measuredAmount: amount,
    );

HabitInactivePeriod _period(String kind, String startsOn, String? endsBefore) =>
    HabitInactivePeriod(
      id: 'ip-${_sequence++}',
      userId: 'user-1',
      habitId: 'habit-1',
      kind: kind,
      startsOn: startsOn,
      endsBefore: endsBefore,
    );

HabitHistory _history(
  List<HabitCommitment> commitments, {
  List<HabitCheckIn> checkIns = const [],
  List<HabitInactivePeriod> periods = const [],
}) =>
    HabitHistory(
      habit: _habitRow,
      commitments: commitments,
      checkIns: checkIns,
      inactivePeriods: periods,
    );

DateTime _d(int month, int day, [int year = 2026]) =>
    DateTime.utc(year, month, day);

HabitDayMark _markOn(
        HabitHistory history, DateTime today, DateTime day) =>
    habitDayMarks(history, today, day, day).single;

void main() {
  group('inactiveKindOn', () {
    final periods = [
      _period('paused', '2026-11-05', '2026-11-08'),
      _period('archived', '2026-11-20', null),
    ];

    test('covers startsOn up to but not including endsBefore', () {
      expect(inactiveKindOn(periods, _d(11, 4)), isNull);
      expect(inactiveKindOn(periods, _d(11, 5)), HabitInactiveKind.paused);
      expect(inactiveKindOn(periods, _d(11, 7)), HabitInactiveKind.paused);
      expect(inactiveKindOn(periods, _d(11, 8)), isNull);
    });

    test('an open period covers every later day', () {
      expect(inactiveKindOn(periods, _d(11, 20)), HabitInactiveKind.archived);
      expect(inactiveKindOn(periods, _d(12, 31)), HabitInactiveKind.archived);
    });

    test('archived wins over paused on the same day', () {
      final both = [
        _period('paused', '2026-11-01', null),
        _period('archived', '2026-11-03', null),
      ];
      expect(inactiveKindOn(both, _d(11, 2)), HabitInactiveKind.paused);
      expect(inactiveKindOn(both, _d(11, 3)), HabitInactiveKind.archived);
    });
  });

  group('states', () {
    test('every-day Habit: beforeHabit, done, missed, openToday, future', () {
      final history = _history(
        [_commitment(chosenOn: '2026-11-03')],
        checkIns: [_checkIn('2026-11-03'), _checkIn('2026-11-05')],
      );
      final marks = habitDayMarks(history, _d(11, 6), _d(11, 2), _d(11, 7));
      expect([for (final m in marks) m.state], [
        HabitDayState.beforeHabit, // 2
        HabitDayState.done, // 3
        HabitDayState.missed, // 4
        HabitDayState.done, // 5
        HabitDayState.openToday, // 6
        HabitDayState.future, // 7
      ]);
      expect(marks.every((m) => m.counted), isTrue);
    });

    test('no commitment at all: every day is beforeHabit', () {
      final marks =
          habitDayMarks(_history([]), _d(11, 6), _d(11, 2), _d(11, 4));
      expect(marks.map((m) => m.state), everyElement(HabitDayState.beforeHabit));
    });

    test('an empty range gives no marks', () {
      expect(
          habitDayMarks(_history([]), _d(11, 6), _d(11, 5), _d(11, 4)), isEmpty);
    });

    test('chosen weekdays: rest days are notDue and not counted', () {
      // Mon, Wed, Fri.
      final history = _history([
        _commitment(
            chosenOn: '2026-11-02',
            repeatKind: HabitRepeatKind.chosenWeekdays,
            chosenWeekdays: [1, 3, 5]),
      ], checkIns: [
        _checkIn('2026-11-02'),
      ]);
      final marks = habitDayMarks(history, _d(11, 8), _d(11, 2), _d(11, 8));
      expect([for (final m in marks) m.state], [
        HabitDayState.done, // Mon
        HabitDayState.notDue, // Tue
        HabitDayState.missed, // Wed
        HabitDayState.notDue, // Thu
        HabitDayState.missed, // Fri
        HabitDayState.notDue, // Sat
        HabitDayState.notDue, // Sun
      ]);
      expect(marks[1].counted, isFalse);
      expect(marks[2].counted, isTrue);
    });

    test('every N days: only the interval days are due', () {
      final history = _history([
        _commitment(
            chosenOn: '2026-11-02',
            repeatKind: HabitRepeatKind.everyNDays,
            intervalDays: 3),
      ]);
      final marks = habitDayMarks(history, _d(11, 9), _d(11, 2), _d(11, 9));
      expect([for (final m in marks) m.state], [
        HabitDayState.missed, // 2
        HabitDayState.notDue, // 3
        HabitDayState.notDue, // 4
        HabitDayState.missed, // 5
        HabitDayState.notDue, // 6
        HabitDayState.notDue, // 7
        HabitDayState.missed, // 8
        HabitDayState.notDue, // 9 (today, not due)
      ]);
    });

    test('N per week and N per month: no day is due, a Check-in is done', () {
      for (final repeatKind in [
        HabitRepeatKind.timesPerWeek,
        HabitRepeatKind.timesPerMonth,
      ]) {
        final history = _history([
          _commitment(
              chosenOn: '2026-11-02',
              repeatKind: repeatKind,
              timesPerPeriod: 3),
        ], checkIns: [
          _checkIn('2026-11-03'),
        ]);
        final marks = habitDayMarks(history, _d(11, 5), _d(11, 2), _d(11, 5));
        expect([for (final m in marks) m.state], [
          HabitDayState.notDue,
          HabitDayState.done,
          HabitDayState.notDue,
          HabitDayState.notDue,
        ], reason: repeatKind.name);
        expect(marks.every((m) => m.counted), isTrue);
      }
    });

    test('a weekly commitment chosen on Wednesday: Mon and Tue are beforeHabit',
        () {
      // Effective start is Monday 2026-11-02, the first judged day is the
      // choosing day (Wednesday).
      final history = _history([
        _commitment(
            chosenOn: '2026-11-04',
            repeatKind: HabitRepeatKind.timesPerWeek,
            timesPerPeriod: 2),
      ]);
      final marks = habitDayMarks(history, _d(11, 6), _d(11, 2), _d(11, 5));
      expect([for (final m in marks) m.state], [
        HabitDayState.beforeHabit,
        HabitDayState.beforeHabit,
        HabitDayState.notDue,
        HabitDayState.notDue,
      ]);
    });

    test('paused and archived days that reached nothing', () {
      final history = _history([
        _commitment(chosenOn: '2026-11-02'),
      ], periods: [
        _period('paused', '2026-11-03', '2026-11-04'),
        _period('archived', '2026-11-05', '2026-11-06'),
      ]);
      final marks = habitDayMarks(history, _d(11, 6), _d(11, 3), _d(11, 5));
      expect([for (final m in marks) m.state], [
        HabitDayState.paused,
        HabitDayState.missed,
        HabitDayState.archived,
      ]);
      expect(marks[0].counted, isFalse);
      expect(marks[2].counted, isFalse);
    });

    test('a Check-in on a rest day or a paused day is done and not counted',
        () {
      final history = _history([
        _commitment(
            chosenOn: '2026-11-02',
            repeatKind: HabitRepeatKind.chosenWeekdays,
            chosenWeekdays: [1]),
      ], checkIns: [
        _checkIn('2026-11-03'), // Tuesday: a rest day
        _checkIn('2026-11-09'), // Monday: due, but paused
      ], periods: [
        _period('paused', '2026-11-09', '2026-11-10'),
      ]);
      final rest = _markOn(history, _d(11, 10), _d(11, 3));
      expect(rest.state, HabitDayState.done);
      expect(rest.counted, isFalse);
      final paused = _markOn(history, _d(11, 10), _d(11, 9));
      expect(paused.state, HabitDayState.done);
      expect(paused.counted, isFalse);
    });
  });

  group('measurable days', () {
    final history = _history([
      _commitment(
          chosenOn: '2026-11-02', unitLabel: 'glasses', dailyTargetAmount: 8),
    ], checkIns: [
      _checkIn('2026-11-03', amount: 5),
      _checkIn('2026-11-04', amount: 8),
      _checkIn('2026-11-05', amount: 11),
      _checkIn('2026-11-06', amount: 3),
      _checkIn('2026-11-06', amount: 5),
      _checkIn('2026-11-07', amount: 0.1),
      _checkIn('2026-11-07', amount: 0.2),
    ]);
    final today = _d(11, 9);

    test('under target is partial, at and over target are done', () {
      final marks = habitDayMarks(history, today, _d(11, 2), _d(11, 5));
      expect([for (final m in marks) m.state], [
        HabitDayState.missed,
        HabitDayState.partial,
        HabitDayState.done,
        HabitDayState.done,
      ]);
      expect([for (final m in marks) m.totalAmount], [0, 5, 8, 11]);
      expect(marks.map((m) => m.targetAmount), everyElement(8));
      expect(marks.map((m) => m.unitLabel), everyElement('glasses'));
    });

    test('two Check-ins on one day add up and are both listed', () {
      final mark = _markOn(history, today, _d(11, 6));
      expect(mark.state, HabitDayState.done);
      expect(mark.totalAmount, 8);
      expect(mark.checkInCount, 2);
      expect(mark.checkIns.map((c) => c.measuredAmount), [3, 5]);
    });

    test('decimal entries are settled before comparing', () {
      final settled = _history([
        _commitment(
            chosenOn: '2026-11-02',
            unitLabel: 'litres',
            dailyTargetAmount: 0.3),
      ], checkIns: [
        _checkIn('2026-11-07', amount: 0.1),
        _checkIn('2026-11-07', amount: 0.2),
      ]);
      expect(_markOn(settled, today, _d(11, 7)).state, HabitDayState.done);
    });

    test('a partial day on a rest day is partial and not counted', () {
      final weekdays = _history([
        _commitment(
            chosenOn: '2026-11-02',
            repeatKind: HabitRepeatKind.chosenWeekdays,
            chosenWeekdays: [1],
            unitLabel: 'pages',
            dailyTargetAmount: 10),
      ], checkIns: [
        _checkIn('2026-11-03', amount: 4),
      ]);
      final mark = _markOn(weekdays, today, _d(11, 3));
      expect(mark.state, HabitDayState.partial);
      expect(mark.counted, isFalse);
    });
  });

  group('commitment changes', () {
    test('earlier days keep the old target; the marker sits on the new first '
        'day', () {
      final history = _history([
        _commitment(
            id: 'old',
            chosenOn: '2026-11-02',
            unitLabel: 'pages',
            dailyTargetAmount: 10),
        _commitment(
            id: 'new',
            chosenOn: '2026-11-05',
            unitLabel: 'pages',
            dailyTargetAmount: 20),
      ], checkIns: [
        _checkIn('2026-11-04', amount: 10),
        _checkIn('2026-11-05', amount: 10),
      ]);
      final marks = habitDayMarks(history, _d(11, 6), _d(11, 3), _d(11, 6));
      expect([for (final m in marks) m.targetAmount], [10, 10, 20, 20]);
      expect([for (final m in marks) m.state], [
        HabitDayState.missed,
        HabitDayState.done,
        HabitDayState.partial,
        HabitDayState.openToday,
      ]);
      expect([for (final m in marks) m.commitmentStartsHere],
          [false, false, true, false]);
    });

    test('an unchanged re-save has no marker', () {
      final history = _history([
        _commitment(id: 'a', chosenOn: '2026-11-02'),
        _commitment(id: 'b', chosenOn: '2026-11-05'),
      ]);
      final marks = habitDayMarks(history, _d(11, 8), _d(11, 2), _d(11, 8));
      expect(marks.any((m) => m.commitmentStartsHere), isFalse);
    });

    test('a changed repeat rule is marked', () {
      final history = _history([
        _commitment(id: 'a', chosenOn: '2026-11-02'),
        _commitment(
            id: 'b',
            chosenOn: '2026-11-05',
            repeatKind: HabitRepeatKind.chosenWeekdays,
            chosenWeekdays: [1, 2]),
      ]);
      final marks = habitDayMarks(history, _d(11, 8), _d(11, 2), _d(11, 8));
      expect(
          [for (final m in marks) if (m.commitmentStartsHere) m.day], [_d(11, 5)]);
    });

    test('binary to measurable: days before the change have no target', () {
      final history = _history([
        _commitment(id: 'bin', chosenOn: '2026-11-02'),
        _commitment(
            id: 'meas',
            chosenOn: '2026-11-05',
            unitLabel: 'pages',
            dailyTargetAmount: 10),
      ], checkIns: [
        _checkIn('2026-11-03'),
        _checkIn('2026-11-05', amount: 10),
      ]);
      final marks = habitDayMarks(history, _d(11, 6), _d(11, 3), _d(11, 6));
      expect([for (final m in marks) m.targetAmount], [null, null, 10, 10]);
      expect([for (final m in marks) m.totalAmount], [null, null, 10, 0]);
      expect(marks.first.state, HabitDayState.done);
      expect(marks[2].state, HabitDayState.done);
      expect(marks[2].commitmentStartsHere, isTrue);
    });
  });

  group('agreement with the streak engine', () {
    // 120 days from Monday 2026-08-03 to Tuesday 2026-11-30, a Check-in on
    // most days, a few measurable partials, and a pause.
    final firstDay = _d(8, 3);
    final today = _d(11, 30);
    String key(DateTime day) => habitDayKey(day);

    final fixtures = <String, HabitCommitment Function(String)>{
      'every day': (c) => _commitment(chosenOn: c),
      'chosen weekdays': (c) => _commitment(
          chosenOn: c,
          repeatKind: HabitRepeatKind.chosenWeekdays,
          chosenWeekdays: [1, 3, 4, 6]),
      'every 3 days': (c) => _commitment(
          chosenOn: c,
          repeatKind: HabitRepeatKind.everyNDays,
          intervalDays: 3),
      'every day, measurable': (c) => _commitment(
          chosenOn: c, unitLabel: 'pages', dailyTargetAmount: 10),
    };

    for (final entry in fixtures.entries) {
      test('${entry.key}: missed plus past partial due days are the '
          'engine\'s missed day units', () {
        final measurable = entry.key.contains('measurable');
        final checkIns = <HabitCheckIn>[];
        for (var i = 0; i < 120; i++) {
          final day = key(DateTime.utc(2026, 8, 3 + i));
          if (i % 7 == 3 || i % 11 == 5) continue; // no Check-in
          if (measurable) {
            final amount = i % 5 == 0 ? 4.0 : (i % 4 == 0 ? 12.0 : 10.0);
            checkIns.add(_checkIn(day, amount: amount));
          } else {
            checkIns.add(_checkIn(day));
          }
        }
        final history = _history(
          [entry.value(key(firstDay))],
          checkIns: checkIns,
          periods: [_period('paused', '2026-09-10', '2026-09-17')],
        );

        final engineMissed = <DateTime>{
          for (final unit in judgeUnits(history, today))
            if (unit.kind == HabitUnitKind.day &&
                unit.result == HabitUnitResult.missed)
              unit.firstDay,
        };
        final marks = habitDayMarks(history, today, firstDay, today);
        expect(marks, hasLength(120));
        final dueDays = <DateTime>{
          for (final unit in judgeUnits(history, today))
            if (unit.kind == HabitUnitKind.day) unit.firstDay,
        };
        final markedMissed = <DateTime>{
          for (final mark in marks)
            if (mark.state == HabitDayState.missed ||
                (mark.state == HabitDayState.partial &&
                    dueDays.contains(mark.day) &&
                    mark.day != today))
              mark.day,
        };
        expect(markedMissed, engineMissed);
        expect(engineMissed, isNotEmpty);
      });
    }
  });

  test('a range across a daylight-saving change has one mark per calendar day',
      () {
    // US clocks went forward on 2026-03-08 and back on 2026-11-01.
    for (final range in [
      (_d(3, 6), _d(3, 11)),
      (_d(10, 30), _d(11, 4)),
    ]) {
      final history = _history([_commitment(chosenOn: '2026-01-01')]);
      final marks = habitDayMarks(history, _d(12, 1), range.$1, range.$2);
      final expectedDays = range.$2.difference(range.$1).inDays + 1;
      expect(marks, hasLength(expectedDays));
      for (var i = 0; i < marks.length; i++) {
        expect(marks[i].day,
            DateTime.utc(range.$1.year, range.$1.month, range.$1.day + i));
        expect(marks[i].state, HabitDayState.missed);
      }
    }
  });
}
