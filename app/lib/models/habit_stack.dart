/// Which Habits are for today, and the one order in which Habits stack.
///
/// Pure, like the rest of the streak engine: callers pass what they already
/// loaded. This is the only place in the app that orders Habits into stacks.
library;

import '../database/gtd_database.dart' show Habit;
import 'habit_progress.dart';

/// The ids of the Habits that are for today.
///
/// A Habit is for today when it is due today (day-based) or its open period
/// still needs a Check-in (period-based). A Habit that is done today stays in,
/// so the list can say "all done". Paused Habits and Habits not due are out.
/// Preferred days never add a Habit: [HabitProgress.todayState] ignores them.
///
/// [progressById] holds the progress of the active Habits, by Habit id.
Set<String> habitsForToday(Map<String, HabitProgress> progressById) => {
      for (final entry in progressById.entries)
        if (_isForToday(entry.value)) entry.key,
    };

bool _isForToday(HabitProgress progress) =>
    progress.todayState == HabitTodayState.done ||
    progress.todayState == HabitTodayState.notYet;

int _byCreationThenId(Habit a, Habit b) {
  final byCreation = a.createdAt.compareTo(b.createdAt);
  return byCreation != 0 ? byCreation : a.id.compareTo(b.id);
}

/// Orders [habits] into stacks: one chain per root, each chain in stack order.
///
/// Pass the active Habits only. A Habit anchored (after or before) to a Habit
/// that is not in [habits] has no anchor to follow, so it is a root. Within a
/// level, Habits go by creation time, then id.
///
/// For a root: the Habits anchored before it, the root, then for each Habit
/// anchored after it, that Habit's own before-anchored Habits, the Habit, and
/// its followers. A guard against loops (two devices can still make one)
/// emits every Habit exactly once; Habits a walk from the roots never reaches
/// start chains of their own.
List<List<Habit>> habitStackChains(Iterable<Habit> habits) {
  final sorted = [...habits]..sort(_byCreationThenId);
  final idsInSet = {for (final habit in sorted) habit.id};

  final afters = <String, List<Habit>>{};
  final befores = <String, List<Habit>>{};
  final roots = <Habit>[];
  for (final habit in sorted) {
    final anchorId = habit.anchorHabitId;
    final isHabitAnchor = habit.anchorKind == 'after_habit' ||
        habit.anchorKind == 'before_habit';
    if (!isHabitAnchor ||
        anchorId == null ||
        anchorId == habit.id ||
        !idsInSet.contains(anchorId)) {
      roots.add(habit);
      continue;
    }
    final target = habit.anchorKind == 'after_habit' ? afters : befores;
    (target[anchorId] ??= []).add(habit);
  }

  final visited = <String>{};
  final chains = <List<Habit>>[];

  void expand(Habit habit, List<Habit> chain) {
    if (!visited.add(habit.id)) return;
    for (final earlier in befores[habit.id] ?? const <Habit>[]) {
      expand(earlier, chain);
    }
    chain.add(habit);
    for (final follower in afters[habit.id] ?? const <Habit>[]) {
      expand(follower, chain);
    }
  }

  for (final root in roots) {
    final chain = <Habit>[];
    expand(root, chain);
    if (chain.isNotEmpty) chains.add(chain);
  }
  // Habits only a loop connects: each unvisited one starts a chain.
  for (final habit in sorted) {
    final chain = <Habit>[];
    expand(habit, chain);
    if (chain.isNotEmpty) chains.add(chain);
  }
  return chains;
}

/// The Habit to offer after a Check-in on [checkedInHabitId], or null.
///
/// It is the first later Habit in the same chain that is for today and not
/// done. A Habit with no progress in [progressById] is skipped. Nothing is
/// offered after the last Habit of a stack.
Habit? nextInStack(
  List<List<Habit>> chains,
  Map<String, HabitProgress> progressById,
  String checkedInHabitId,
) {
  for (final chain in chains) {
    final index = chain.indexWhere((habit) => habit.id == checkedInHabitId);
    if (index < 0) continue;
    for (final candidate in chain.skip(index + 1)) {
      if (progressById[candidate.id]?.todayState == HabitTodayState.notYet) {
        return candidate;
      }
    }
    return null;
  }
  return null;
}
