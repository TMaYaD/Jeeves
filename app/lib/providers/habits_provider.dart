/// What the Habit list and detail screens read: every Habit with its state
/// today, and one Habit's rows.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/habit_dao.dart';
import '../database/gtd_database.dart' show Habit, Tag;
import '../models/habit_commitment.dart';
import 'database_provider.dart';
import 'habit_progress_provider.dart' show habitTodayProvider;

/// Every Habit with the state it is in today, oldest first.
final habitListProvider = StreamProvider<List<HabitWithState>>((ref) {
  final today = ref.watch(habitTodayProvider);
  return ref.watch(databaseProvider).habitDao.watchHabits(today);
});

/// One Habit, or null when there is none.
final habitByIdProvider = StreamProvider.family<Habit?, String>((ref, id) =>
    ref.watch(databaseProvider).habitDao.watchHabit(id));

/// One Habit's commitments, oldest first.
final habitCommitmentsProvider =
    StreamProvider.family<List<HabitCommitment>, String>((ref, id) =>
        ref.watch(databaseProvider).habitDao.watchCommitmentsFor(id));

/// The Area and Labels of one Habit.
final habitTagsProvider = StreamProvider.family<List<Tag>, String>((ref, id) =>
    ref.watch(databaseProvider).habitDao.watchTagsFor(id));

/// The state of one Habit today, from the list stream.
final habitStateTodayProvider =
    Provider.family<HabitState?, String>((ref, id) {
  final rows = ref.watch(habitListProvider).value;
  if (rows == null) return null;
  for (final row in rows) {
    if (row.habit.id == id) return row.state;
  }
  return null;
});
