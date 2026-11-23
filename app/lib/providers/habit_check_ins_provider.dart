/// Check-in actions for Habits: add, undo and correct.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/habit_commitment.dart' show habitDayKey;
import 'auth_provider.dart';
import 'clock_provider.dart';
import 'database_provider.dart';

/// The day a Check-in counts for.
///
/// [closingDay] is the day an Evening Shutdown is closing, which can be the
/// day before [now] when the shutdown runs past midnight. Without it, the
/// Check-in counts for the local day of [now].
String habitCheckInDay({required DateTime now, String? closingDay}) =>
    closingDay ?? habitDayKey(now);

/// Writes Habit Check-ins; progress providers recompute from the database.
///
/// Not named `HabitCheckIns`: that is the Drift table class.
final habitCheckInsProvider =
    NotifierProvider<HabitCheckInActions, void>(HabitCheckInActions.new);

class HabitCheckInActions extends Notifier<void> {
  @override
  void build() {}

  /// Adds a Check-in and returns its id, for [undo].
  ///
  /// [countsForDay] defaults to today. A measurable Habit needs an [amount]
  /// and a binary one refuses it; the DAO throws an [ArgumentError] otherwise.
  Future<String> checkIn(
    String habitId, {
    double? amount,
    String? countsForDay,
  }) {
    return ref.read(databaseProvider).habitDao.addCheckIn(
          habitId: habitId,
          userId: ref.read(currentUserIdProvider),
          // Read the clock now, not the cached habitTodayProvider: that one can
          // lag after the app wakes past midnight.
          countsForDay: habitCheckInDay(
              now: ref.read(clockProvider)(), closingDay: countsForDay),
          now: ref.read(clockProvider)().toUtc(),
          measuredAmount: amount,
        );
  }

  /// Adds today's first Check-in of a binary Habit and returns its id, or
  /// returns null when today already has one (a second tap in a stale frame).
  Future<String?> checkInFirstOfToday(String habitId) {
    final now = ref.read(clockProvider)();
    return ref.read(databaseProvider).habitDao.addFirstCheckInOfDay(
          habitId: habitId,
          userId: ref.read(currentUserIdProvider),
          countsForDay: habitCheckInDay(now: now),
          now: now.toUtc(),
        );
  }

  /// Takes back the Check-in [checkInId] returned by [checkIn].
  Future<void> undo(String checkInId) => remove(checkInId);

  /// Changes the amount of a Check-in on any day.
  Future<void> change(String checkInId, double amount) {
    return ref.read(databaseProvider).habitDao.changeCheckInAmount(
          checkInId: checkInId,
          userId: ref.read(currentUserIdProvider),
          measuredAmount: amount,
        );
  }

  /// Removes a Check-in on any day.
  Future<void> remove(String checkInId) {
    return ref.read(databaseProvider).habitDao.removeCheckIn(
          checkInId: checkInId,
          userId: ref.read(currentUserIdProvider),
        );
  }

  /// Removes the latest Check-in counted for today and returns its id, or
  /// returns null when there is none.
  ///
  /// Today is the clock day, as for [checkIn]. The latest is the one with the
  /// greatest `checkedInAt`, then the greatest id.
  Future<String?> removeLatestOfToday(String habitId) async {
    final today = habitDayKey(ref.read(clockProvider)());
    final todays = await ref
        .read(databaseProvider)
        .habitDao
        .checkInsFor(habitId, today, today);
    if (todays.isEmpty) return null;
    final latestId = todays.last.id;
    await remove(latestId);
    return latestId;
  }
}
