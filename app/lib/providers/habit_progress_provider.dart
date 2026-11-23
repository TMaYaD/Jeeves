/// Feeds the streak engine from the Habit tables: today's day key, every
/// Habit's progress, the "for today" set and the stack order.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/habit_dao.dart';
import '../database/gtd_database.dart' show Habit, HabitCheckIn;
import '../models/habit_commitment.dart'
    show HabitCommitment, commitmentInForceOn, habitDayKey;
import '../models/habit_day_marks.dart';
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
  // A Dart Timer does not count time the process was suspended, so also
  // re-check the day when the app resumes.
  final todayKey = habitDayKey(now);
  final observer = _HabitDayResumeObserver(() {
    if (habitDayKey(ref.read(clockProvider)()) != todayKey) {
      ref.invalidateSelf();
    }
  });
  WidgetsBinding.instance.addObserver(observer);
  ref.onDispose(() {
    timer.cancel();
    WidgetsBinding.instance.removeObserver(observer);
  });
  return todayKey;
});

class _HabitDayResumeObserver with WidgetsBindingObserver {
  _HabitDayResumeObserver(this._onResumed);

  final void Function() _onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResumed();
  }
}

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

/// One Habit's full history, or null while loading or when there is no such
/// Habit.
final habitHistoryProvider =
    Provider.family<HabitHistory?, String>((ref, habitId) {
  final histories = ref.watch(habitHistoriesProvider).value;
  if (histories == null) return null;
  for (final history in histories) {
    if (history.habit.id == habitId) return history;
  }
  return null;
});

/// The day marks of one Habit from [HabitDayMarksRange.fromDay] to
/// [HabitDayMarksRange.toDay], or null while the history is loading.
///
/// Recomputed once per history change or day change, not per month shown.
final habitDayMarksProvider =
    Provider.family<List<HabitDayMark>?, HabitDayMarksRange>((ref, range) {
  final history = ref.watch(habitHistoryProvider(range.habitId));
  if (history == null) return null;
  final today = _todayAsDay(ref.watch(habitTodayProvider));
  final fromDay = parseHabitDay(range.fromDay);
  final toDay = parseHabitDay(range.toDay);
  if (fromDay == null || toDay == null) return const [];
  return habitDayMarks(history, today, fromDay, toDay);
});

/// The key of [habitDayMarksProvider]: a Habit and a range of day keys
/// (`yyyy-MM-dd`), both ends included.
typedef HabitDayMarksRange = ({String habitId, String fromDay, String toDay});

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

/// The commitment in force today and today's Check-ins of one Habit.
class HabitTodayEntries {
  const HabitTodayEntries({required this.commitment, required this.checkIns});

  /// The commitment in force today; null before the Habit's first day.
  final HabitCommitment? commitment;

  /// Today's Check-ins, oldest first (`checkedInAt`, then `id`).
  final List<HabitCheckIn> checkIns;
}

/// Today's commitment and Check-ins for one Habit, or null while loading or
/// when there is no such Habit.
final habitTodayEntriesProvider =
    Provider.family<HabitTodayEntries?, String>((ref, habitId) {
  final today = ref.watch(habitTodayProvider);
  final histories = ref.watch(habitHistoriesProvider).value;
  if (histories == null) return null;
  for (final history in histories) {
    if (history.habit.id != habitId) continue;
    final checkIns = [
      for (final checkIn in history.checkIns)
        if (checkIn.countsForDay == today) checkIn,
    ]..sort((a, b) {
        final byInstant = a.checkedInAt.compareTo(b.checkedInAt);
        return byInstant != 0 ? byInstant : a.id.compareTo(b.id);
      });
    return HabitTodayEntries(
      commitment: commitmentInForceOn(history.commitments, today),
      checkIns: List.unmodifiable(checkIns),
    );
  }
  return null;
});

/// The progress of the active Habits, by Habit id.
final activeHabitProgressProvider = Provider<Map<String, HabitProgress>>((ref) {
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
  (ref) => habitsForToday(ref.watch(activeHabitProgressProvider)),
);

/// The active Habits in stack order, one chain per root.
final habitStackChainsProvider = Provider<List<List<Habit>>>((ref) {
  final active = ref.watch(_activeHabitsProvider).value;
  return active == null ? const [] : habitStackChains(active);
});

/// The Habits that are for [dayKey] (active on it and either done or not yet
/// done), with their progress on it, by Habit id. Pure.
///
/// The same judgement as [habitsForTodayProvider], for any day. The day's state
/// comes from the Habit's history alone, so a Habit paused or archived on
/// [dayKey] is absent, and a Habit created after it never appears.
Map<String, HabitProgress> habitProgressForDay(
  List<HabitHistory> histories,
  String dayKey,
) {
  final day = parseHabitDay(dayKey);
  if (day == null) return const {};
  final progressById = {
    for (final history in histories)
      if (!_createdAfter(history.habit, dayKey))
        history.habit.id: computeHabitProgress(history, day),
  };
  final forDay = habitsForToday(progressById);
  return {
    for (final entry in progressById.entries)
      if (forDay.contains(entry.key)) entry.key: entry.value,
  };
}

/// Whether [habit] was created on a local day after [dayKey]. A Habit whose
/// creation instant cannot be read is not excluded.
bool _createdAfter(Habit habit, String dayKey) {
  final createdAt = DateTime.tryParse(habit.createdAt);
  if (createdAt == null) return false;
  return habitDayKey(createdAt.toLocal()).compareTo(dayKey) > 0;
}

/// [habitProgressForDay], live.
final habitProgressOnDayProvider =
    Provider.family<Map<String, HabitProgress>, String>((ref, dayKey) {
  final histories = ref.watch(habitHistoriesProvider).value;
  return histories == null ? const {} : habitProgressForDay(histories, dayKey);
});

/// The ids of the Habits that are for [dayKey] (see
/// [habitProgressOnDayProvider]). For today it equals [habitsForTodayProvider].
final habitsForDayProvider = Provider.family<Set<String>, String>(
  (ref, dayKey) => ref.watch(habitProgressOnDayProvider(dayKey)).keys.toSet(),
);
