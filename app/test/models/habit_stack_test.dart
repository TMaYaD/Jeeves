import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart'
    show Habit, HabitCheckIn, HabitInactivePeriod;
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/models/habit_progress.dart';
import 'package:jeeves/models/habit_stack.dart';

// Monday 2026-11-16 is "today" throughout; Habits are created on 2026-11-02.
final today = DateTime.utc(2026, 11, 16);

Habit habit(
  String id, {
  String anchorKind = 'none',
  String? anchorHabitId,
  String createdAt = '2026-11-02T09:00:00.000Z',
}) =>
    Habit(
      id: id,
      userId: 'user-1',
      title: id,
      anchorKind: anchorKind,
      anchorHabitId: anchorHabitId,
      createdAt: createdAt,
    );

Habit after(String id, String anchor, {String? createdAt}) => habit(id,
    anchorKind: 'after_habit',
    anchorHabitId: anchor,
    createdAt: createdAt ?? '2026-11-02T09:00:00.000Z');

Habit before(String id, String anchor, {String? createdAt}) => habit(id,
    anchorKind: 'before_habit',
    anchorHabitId: anchor,
    createdAt: createdAt ?? '2026-11-02T09:00:00.000Z');

HabitCommitment commitmentFor(
  String habitId, {
  HabitRepeatKind repeatKind = HabitRepeatKind.everyDay,
  List<int>? chosenWeekdays,
  int? timesPerPeriod,
  List<int>? preferredDays,
}) =>
    HabitCommitment(
      id: 'c-$habitId',
      habitId: habitId,
      chosenOn: '2026-11-02',
      createdAt: DateTime.utc(2026, 11, 2, 9),
      repeatKind: repeatKind,
      chosenWeekdays: chosenWeekdays,
      timesPerPeriod: timesPerPeriod,
      preferredDays: preferredDays,
    );

HabitCheckIn checkInFor(String habitId, String day) => HabitCheckIn(
      id: 'ci-$habitId-$day',
      userId: 'user-1',
      habitId: habitId,
      countsForDay: day,
      checkedInAt: '${day}T12:00:00.000Z',
    );

HabitProgress progressOf(
  Habit row,
  HabitCommitment commitment, {
  List<HabitCheckIn> checkIns = const [],
  List<HabitInactivePeriod> inactivePeriods = const [],
}) =>
    computeHabitProgress(
      HabitHistory(
        habit: row,
        commitments: [commitment],
        checkIns: checkIns,
        inactivePeriods: inactivePeriods,
      ),
      today,
    );

HabitProgress withState(HabitTodayState state) => HabitProgress(
      mainStreakKind: HabitUnitKind.day,
      currentStreak: 0,
      bestStreak: 0,
      brokenStreakLength: null,
      rates: const [],
      todayState: state,
    );

List<String> ids(Iterable<Habit> habits) => [for (final h in habits) h.id];

List<List<String>> chainIds(List<List<Habit>> chains) =>
    [for (final chain in chains) ids(chain)];

void main() {
  group('habitsForToday', () {
    test('keeps a due Habit, an unfinished period and a met one as done', () {
      final due = habit('due');
      final weekly = habit('weekly');
      final metToday = habit('met-today');
      final progress = {
        'due': progressOf(due, commitmentFor('due')),
        'weekly': progressOf(weekly,
            commitmentFor('weekly',
                repeatKind: HabitRepeatKind.timesPerWeek, timesPerPeriod: 3),
            checkIns: [checkInFor('weekly', '2026-11-16')]),
        'met-today': progressOf(
            metToday,
            commitmentFor('met-today',
                repeatKind: HabitRepeatKind.timesPerWeek, timesPerPeriod: 1),
            checkIns: [checkInFor('met-today', '2026-11-16')]),
      };
      expect(progress['met-today']!.todayState, HabitTodayState.done);

      expect(habitsForToday(progress), {'due', 'weekly', 'met-today'});
    });

    test('leaves out a Habit that is not due today', () {
      final tuesdaysOnly = habit('tuesdays');
      final progress = {
        'tuesdays': progressOf(
            tuesdaysOnly,
            commitmentFor('tuesdays',
                repeatKind: HabitRepeatKind.chosenWeekdays,
                chosenWeekdays: [2])),
      };
      expect(habitsForToday(progress), isEmpty);
    });

    test('leaves out a period that was met on an earlier day', () {
      final weekly = habit('weekly');
      final progress = {
        'weekly': progressOf(
            weekly,
            commitmentFor('weekly',
                repeatKind: HabitRepeatKind.timesPerWeek, timesPerPeriod: 1),
            checkIns: [checkInFor('weekly', '2026-11-01')]),
      };
      expect(habitsForToday(progress), {'weekly'},
          reason: 'the check-in on 11-01 is last week, so this week is open');

      final metEarlier = {
        'weekly': progressOf(
            weekly,
            commitmentFor('weekly',
                repeatKind: HabitRepeatKind.timesPerWeek, timesPerPeriod: 1),
            checkIns: [checkInFor('weekly', '2026-11-15')]),
      };
      // 11-15 is a Sunday: the previous week. Still open today.
      expect(habitsForToday(metEarlier), {'weekly'});
    });

    test('a preferred day does not add a Habit', () {
      // Met earlier this month, and today is its preferred date.
      final monthly = habit('monthly');
      final progress = {
        'monthly': progressOf(
            monthly,
            commitmentFor('monthly',
                repeatKind: HabitRepeatKind.timesPerMonth,
                timesPerPeriod: 1,
                preferredDays: [16]),
            checkIns: [checkInFor('monthly', '2026-11-05')]),
      };
      expect(progress['monthly']!.todayState, HabitTodayState.notDue);
      expect(habitsForToday(progress), isEmpty);
    });

    test('a preferred day does not take a Habit out', () {
      final weekly = habit('weekly');
      final progress = {
        'weekly': progressOf(
            weekly,
            commitmentFor('weekly',
                repeatKind: HabitRepeatKind.timesPerWeek,
                timesPerPeriod: 3,
                preferredDays: [5])),
      };
      expect(habitsForToday(progress), {'weekly'});
    });

    test('a paused Habit is excluded', () {
      final paused = habit('paused');
      final progress = {
        'paused': progressOf(paused, commitmentFor('paused'), inactivePeriods: [
          HabitInactivePeriod(
            id: 'ip-1',
            userId: 'user-1',
            habitId: 'paused',
            kind: 'paused',
            startsOn: '2026-11-10',
          ),
        ]),
      };
      expect(progress['paused']!.todayState, HabitTodayState.paused);
      expect(habitsForToday(progress), isEmpty);
    });
  });

  group('habitStackChains', () {
    test('Habits without an anchor to a Habit are separate chains, oldest '
        'first, then by id', () {
      final chains = habitStackChains([
        habit('b', createdAt: '2026-11-02T09:00:00.000Z'),
        habit('c', createdAt: '2026-11-01T09:00:00.000Z'),
        habit('a', createdAt: '2026-11-02T09:00:00.000Z'),
        habit('d', anchorKind: 'clock_time'),
      ]);
      expect(chainIds(chains), [
        ['c'],
        ['a'],
        ['b'],
        ['d'],
      ]);
    });

    test('a Habit after another follows it, and its followers follow', () {
      final chains = habitStackChains([
        after('journal', 'water', createdAt: '2026-11-03T09:00:00.000Z'),
        after('water', 'stretch', createdAt: '2026-11-02T10:00:00.000Z'),
        habit('stretch'),
      ]);
      expect(chainIds(chains), [
        ['stretch', 'water', 'journal'],
      ]);
    });

    test('a Habit before another comes ahead of it (H27)', () {
      final chains = habitStackChains([
        habit('water'),
        after('journal', 'water'),
        before('stretch', 'journal', createdAt: '2026-11-04T09:00:00.000Z'),
      ]);
      expect(chainIds(chains), [
        ['water', 'stretch', 'journal'],
      ]);
    });

    test('a Habit before a root comes ahead of the root', () {
      final chains = habitStackChains([
        habit('water'),
        before('stretch', 'water'),
        after('journal', 'water'),
      ]);
      expect(chainIds(chains), [
        ['stretch', 'water', 'journal'],
      ]);
    });

    test('an anchor to a Habit not in the set makes the follower a root', () {
      final chains = habitStackChains([
        after('orphan', 'paused-one'),
        before('orphan-before', 'archived-one',
            createdAt: '2026-11-03T09:00:00.000Z'),
      ]);
      expect(chainIds(chains), [
        ['orphan'],
        ['orphan-before'],
      ]);
    });

    test('an A-B loop does not hang and emits each Habit once', () {
      final chains = habitStackChains([
        after('a', 'b', createdAt: '2026-11-02T09:00:00.000Z'),
        after('b', 'a', createdAt: '2026-11-03T09:00:00.000Z'),
      ]);
      final flat = ids(chains.expand((chain) => chain));
      expect(flat..sort(), ['a', 'b']);
    });

    test('a Habit anchored to itself is a single Habit', () {
      final chains = habitStackChains([after('a', 'a')]);
      expect(chainIds(chains), [
        ['a'],
      ]);
    });

    test('a loop does not duplicate the Habits hanging off it', () {
      final chains = habitStackChains([
        habit('root'),
        after('a', 'b', createdAt: '2026-11-02T09:00:00.000Z'),
        after('b', 'a', createdAt: '2026-11-03T09:00:00.000Z'),
        after('tail', 'b', createdAt: '2026-11-04T09:00:00.000Z'),
      ]);
      final flat = ids(chains.expand((chain) => chain));
      expect(flat.toSet().length, 4);
      expect(flat.length, 4);
    });
  });

  group('nextInStack', () {
    final stack = [
      habit('stretch'),
      after('water', 'stretch'),
      after('journal', 'water'),
    ];

    test('offers the first later Habit that is for today and not done', () {
      final chains = habitStackChains(stack);
      final next = nextInStack(chains, {
        'stretch': withState(HabitTodayState.done),
        'water': withState(HabitTodayState.notYet),
        'journal': withState(HabitTodayState.notYet),
      }, 'stretch');
      expect(next?.id, 'water');
    });

    test('skips a Habit that is not due and offers the one after it', () {
      final chains = habitStackChains(stack);
      final next = nextInStack(chains, {
        'stretch': withState(HabitTodayState.done),
        'water': withState(HabitTodayState.notDue),
        'journal': withState(HabitTodayState.notYet),
      }, 'stretch');
      expect(next?.id, 'journal');
    });

    test('skips a Habit that is already done or paused', () {
      final chains = habitStackChains(stack);
      final next = nextInStack(chains, {
        'stretch': withState(HabitTodayState.done),
        'water': withState(HabitTodayState.done),
        'journal': withState(HabitTodayState.paused),
      }, 'stretch');
      expect(next, isNull);
    });

    test('the last Habit in the stack offers nothing', () {
      final chains = habitStackChains(stack);
      final next = nextInStack(chains, {
        'stretch': withState(HabitTodayState.notYet),
        'water': withState(HabitTodayState.notYet),
        'journal': withState(HabitTodayState.done),
      }, 'journal');
      expect(next, isNull);
    });

    test('never looks outside the checked-in Habit\'s own chain', () {
      final chains = habitStackChains([...stack, habit('other')]);
      final next = nextInStack(chains, {
        'stretch': withState(HabitTodayState.notYet),
        'water': withState(HabitTodayState.notYet),
        'journal': withState(HabitTodayState.notYet),
        'other': withState(HabitTodayState.done),
      }, 'other');
      expect(next, isNull);
    });

    test('a Habit not in any chain offers nothing', () {
      final next = nextInStack(habitStackChains(stack), {}, 'missing');
      expect(next, isNull);
    });
  });
}
