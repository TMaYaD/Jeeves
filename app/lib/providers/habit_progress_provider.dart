/// Feeds the streak engine from the Habit tables: today's day key, every
/// Habit's progress, the "for today" set and the stack order.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/habit_dao.dart';
import '../database/gtd_database.dart' show Habit;
import '../models/habit_commitment.dart' show habitDayKey;
import '../models/habit_days.dart' show parseHabitDay;
import '../models/habit_progress.dart';
import '../models/habit_stack.dart';
import 'clock_provider.dart';
import 'database_provider.dart';

/// Today's day key (`yyyy-MM-dd`, local date of [clockProvider]).
///
/// Re-arms itself at the next local midnight, so every provider below
/// recomputes at the day boundary.
final habitTodayProvider = Provider<String>((ref) {
  final now = ref.watch(clockProvider)();
  final nextMidnight = DateTime(now.year, now.month, now.day + 1);
  final timer = Timer(nextMidnight.difference(now), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return habitDayKey(now);
});

/// Every Habit with its full history, re-emitted after any Habit write.
final habitHistoriesProvider = StreamProvider<List<HabitHistory>>((ref) {
  return ref.watch(databaseProvider).habitDao.watchHabitHistories();
});

/// The Habits that are neither paused nor archived today, oldest first.
final _activeHabitsProvider = StreamProvider<List<Habit>>((ref) {
  final today = ref.watch(habitTodayProvider);
  return ref
      .watch(databaseProvider)
      .habitDao
      .watchHabits(today)
      .map((rows) => [
            for (final row in rows)
              if (row.state == HabitState.active) row.habit,
          ]);
});

DateTime _todayAsDay(String todayKey) => parseHabitDay(todayKey)!;

/// The progress of one Habit, or null while loading or when there is no such
/// Habit.
final habitProgressProvider =
    Provider.family<HabitProgress?, String>((ref, habitId) {
  final today = _todayAsDay(ref.watch(habitTodayProvider));
  final histories = ref.watch(habitHistoriesProvider).value;
  if (histories == null) return null;
  for (final history in histories) {
    if (history.habit.id == habitId) {
      return computeHabitProgress(history, today);
    }
  }
  return null;
});

/// The progress of the active Habits, by Habit id.
final _activeProgressProvider = Provider<Map<String, HabitProgress>>((ref) {
  final today = _todayAsDay(ref.watch(habitTodayProvider));
  final histories = ref.watch(habitHistoriesProvider).value;
  final active = ref.watch(_activeHabitsProvider).value;
  if (histories == null || active == null) return const {};
  final activeIds = {for (final habit in active) habit.id};
  return {
    for (final history in histories)
      if (activeIds.contains(history.habit.id))
        history.habit.id: computeHabitProgress(history, today),
  };
});

/// The ids of the active Habits that are for today.
final habitsForTodayProvider = Provider<Set<String>>(
  (ref) => habitsForToday(ref.watch(_activeProgressProvider)),
);

/// The active Habits in stack order, one chain per root.
final habitStackChainsProvider = Provider<List<List<Habit>>>((ref) {
  final active = ref.watch(_activeHabitsProvider).value;
  return active == null ? const [] : habitStackChains(active);
});
