/// The Habits Evening Shutdown asks about: the ones for the day being closed
/// that have no Check-in yet.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart' show GtdDatabase, Habit;
import '../models/habit_stack.dart' show habitStackChains;
import 'habit_check_ins_provider.dart';
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

/// The Habits for [closingDay] that are not done on it, in stack order. Pure.
///
/// A measurable Habit below its target is open (it has Check-ins but is not
/// done), so the user can top it up. Stack order is the order of the Habits
/// that are for the closing day, not today's stacks: the ritual must not
/// depend on today's day key, which re-arms a midnight timer.
List<ShutdownOpenHabit> shutdownOpenHabits(
  List<HabitHistory> histories,
  String closingDay,
) {
  final progressById = habitProgressForDay(histories, closingDay);
  final habitsById = {for (final h in histories) h.habit.id: h.habit};
  final ordered = [
    for (final chain in habitStackChains([
      for (final id in progressById.keys)
        if (habitsById[id] != null) habitsById[id]!,
    ]))
      ...chain,
  ];
  return [
    for (final habit in ordered)
      if (progressById[habit.id]!.todayState == HabitTodayState.notYet)
        ShutdownOpenHabit(habit: habit, progress: progressById[habit.id]!),
  ];
}

/// [shutdownOpenHabits] for the day being closed, live. Empty while the
/// closing day or the Habits are loading.
final shutdownOpenHabitsProvider =
    Provider.autoDispose<List<ShutdownOpenHabit>>((ref) {
  final closingDay = ref.watch(shutdownClosingDayProvider).value;
  final histories = ref.watch(habitHistoriesProvider).value;
  if (closingDay == null || histories == null) return const [];
  return shutdownOpenHabits(histories, closingDay);
});

/// The open Habits for the day being closed, read once from the database.
///
/// For a caller that is not watching the providers above (the Now screen
/// deciding where Evening Shutdown starts). A one-shot read, not a stream,
/// so it settles on any event loop.
Future<List<ShutdownOpenHabit>> readShutdownOpenHabits(
  GtdDatabase db,
  DateTime now,
) async {
  final session = await db.focusSessionDao.getActiveSession();
  final histories = await db.habitDao.getHabitHistories();
  return shutdownOpenHabits(histories, shutdownClosingDayOf(session, now));
}

/// The Check-ins the habit step made in this performance, by Habit id.
///
/// A Habit with no entry (or an empty list) has had nothing from this step.
/// Only Check-ins made here can be taken back here, so a toggle off never
/// removes one the user made earlier in the day.
final shutdownHabitCheckInsProvider = NotifierProvider.autoDispose<
    ShutdownHabitCheckIns, Map<String, List<String>>>(
  ShutdownHabitCheckIns.new,
);

class ShutdownHabitCheckIns extends Notifier<Map<String, List<String>>> {
  final _busyHabitIds = <String>{};

  @override
  Map<String, List<String>> build() => const {};

  /// Checks a binary Habit in for [closingDay], or takes this step's Check-in
  /// back when it already made one.
  Future<void> toggleBinary(String habitId, String closingDay) async {
    if (!_busyHabitIds.add(habitId)) return;
    final actions = ref.read(habitCheckInsProvider.notifier);
    try {
      final made = state[habitId] ?? const <String>[];
      if (made.isEmpty) {
        final id = await actions.checkIn(habitId, countsForDay: closingDay);
        if (ref.mounted) state = {...state, habitId: [id]};
      } else {
        for (final id in made) {
          await actions.undo(id);
        }
        if (ref.mounted) state = {...state, habitId: const []};
      }
    } finally {
      _busyHabitIds.remove(habitId);
    }
  }

  /// Adds [amount] to a measurable Habit for [closingDay]. Each entry adds.
  Future<void> addAmount(
      String habitId, String closingDay, double amount) async {
    if (!_busyHabitIds.add(habitId)) return;
    final actions = ref.read(habitCheckInsProvider.notifier);
    try {
      final id = await actions.checkIn(habitId,
          amount: amount, countsForDay: closingDay);
      if (ref.mounted) {
        state = {
          ...state,
          habitId: [...?state[habitId], id],
        };
      }
    } finally {
      _busyHabitIds.remove(habitId);
    }
  }
}
