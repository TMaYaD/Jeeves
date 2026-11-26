/// The next-in-stack offer: after a Check-in, the next Habit of the stack is
/// offered until the person answers.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart' show Habit;
import '../models/habit_progress.dart';
import '../models/habit_stack.dart';
import 'habit_progress_provider.dart';

/// The id of the Habit just checked in (the offer's source), or null.
final habitStackOfferProvider =
    NotifierProvider<HabitStackOfferSource, String?>(HabitStackOfferSource.new);

class HabitStackOfferSource extends Notifier<String?> {
  @override
  String? build() => null;

  /// [habitId] was just checked in: offer what follows it.
  void checkedIn(String habitId) => state = habitId;

  /// "Not now".
  void dismiss() => state = null;
}

/// The source Habit's row, or null.
final offerSourceHabitProvider = Provider<Habit?>((ref) {
  final sourceId = ref.watch(habitStackOfferProvider);
  if (sourceId == null) return null;
  for (final chain in ref.watch(habitStackChainsProvider)) {
    for (final habit in chain) {
      if (habit.id == sourceId) return habit;
    }
  }
  return null;
});

/// The Habit being offered, or null. Withdrawn when the source's Check-in is
/// undone. Nothing times it out.
final offeredHabitProvider = Provider<Habit?>((ref) {
  final sourceId = ref.watch(habitStackOfferProvider);
  if (sourceId == null) return null;
  final progress = ref.watch(activeHabitProgressProvider);
  if (progress[sourceId]?.todayState != HabitTodayState.done) return null;
  return nextInStack(ref.watch(habitStackChainsProvider), progress, sourceId);
});
