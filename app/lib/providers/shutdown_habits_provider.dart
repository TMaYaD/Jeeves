/// The Habits Evening Shutdown asks about: the ones for the day being closed
/// that have no Check-in yet.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart' show Habit;
import '../models/habit_progress.dart';
import 'evening_shutdown_provider.dart';
import 'habit_progress_provider.dart';

/// One Habit still open on the day being closed, with how far it got.
class ShutdownOpenHabit {
  const ShutdownOpenHabit({required this.habit, required this.progress});

  final Habit habit;

  /// The Habit's progress judged on the closing day.
  final HabitProgress progress;
}

/// The Habits for the closing day that are not done on it, in stack order.
///
/// A measurable Habit below its target is open (it has Check-ins but is not
/// done), so the user can top it up. Empty while the closing day is loading.
final shutdownOpenHabitsProvider =
    Provider.autoDispose<List<ShutdownOpenHabit>>((ref) {
  final closingDay = ref.watch(shutdownClosingDayProvider).value;
  if (closingDay == null) return const [];
  final progressById = ref.watch(habitProgressOnDayProvider(closingDay));
  final histories = ref.watch(habitHistoriesProvider).value ?? const [];
  final habitsById = {for (final h in histories) h.habit.id: h.habit};

  // Stack order comes from the stacks of today's active Habits. A Habit that
  // was active on the closing day but has been paused since is not in them;
  // it goes last, oldest first.
  final ordered = <Habit>[
    for (final chain in ref.watch(habitStackChainsProvider))
      for (final habit in chain)
        if (progressById.containsKey(habit.id)) habit,
  ];
  final orderedIds = {for (final habit in ordered) habit.id};
  final leftover = [
    for (final id in progressById.keys)
      if (!orderedIds.contains(id) && habitsById[id] != null) habitsById[id]!,
  ]..sort((a, b) {
      final byCreation = a.createdAt.compareTo(b.createdAt);
      return byCreation != 0 ? byCreation : a.id.compareTo(b.id);
    });

  return [
    for (final habit in [...ordered, ...leftover])
      if (progressById[habit.id]!.todayState == HabitTodayState.notYet)
        ShutdownOpenHabit(habit: habit, progress: progressById[habit.id]!),
  ];
});
