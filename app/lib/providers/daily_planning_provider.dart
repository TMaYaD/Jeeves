/// Providers and state management for the daily planning ritual (Issue #82).
///
/// Architecture:
/// - [planningCompletionNotifier] — a [ValueNotifier] wired to GoRouter's
///   [refreshListenable] so the router re-evaluates the redirect on change.
/// - [DailyPlanningNotifier] — manages step navigation and available-minutes
///   state; delegates all database writes to [TodoDao] planning methods.
/// - Stream providers expose live lists of tasks for each ritual step.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/gtd_database.dart';
import 'database_provider.dart';
import 'user_constants.dart';

export '../database/gtd_database.dart' show Todo;

// ---------------------------------------------------------------------------
// Date helpers
// ---------------------------------------------------------------------------

/// Returns today's date as an ISO-8601 date string (yyyy-MM-dd).
String planningToday() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

const _kCompletedDateKey = 'planning_ritual_completed_date';

// ---------------------------------------------------------------------------
// Router refresh notifier
// ---------------------------------------------------------------------------

/// Tracks whether the planning ritual has been completed today.
///
/// GoRouter uses this as its [refreshListenable] so the redirect guard
/// re-evaluates whenever completion state changes (e.g. after [startDay] or
/// [reEnterPlanning]).
final planningCompletionNotifier = ValueNotifier<bool>(false);

/// Initialises [planningCompletionNotifier] from [SharedPreferences].
///
/// Must be called once in [main] after [WidgetsFlutterBinding.ensureInitialized].
Future<void> initPlanningCompletion() async {
  final prefs = await SharedPreferences.getInstance();
  final stored = prefs.getString(_kCompletedDateKey);
  planningCompletionNotifier.value = stored == planningToday();
}

// ---------------------------------------------------------------------------
// Stream providers — planning data
// ---------------------------------------------------------------------------

/// Next-action tasks not yet reviewed in today's planning session.
final nextActionsForPlanningProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchNextActionsForPlanning(kLocalUserId, planningToday());
});

/// Scheduled tasks with a due date on today, not yet confirmed in planning.
final scheduledDueTodayProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchScheduledDueToday(kLocalUserId, planningToday());
});

/// Tasks selected for today (selectedForToday == true).
final todaySelectedTasksProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchSelectedForToday(kLocalUserId, planningToday());
});

/// Selected tasks that are still missing a time estimate (drives Step 3).
final selectedTasksMissingEstimatesProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.todoDao
      .watchSelectedTasksMissingEstimates(kLocalUserId, planningToday());
});

// ---------------------------------------------------------------------------
// DailyPlanningNotifier — step navigation + mutations
// ---------------------------------------------------------------------------

/// Immutable state for the daily planning UI.
class DailyPlanningState {
  const DailyPlanningState({
    this.currentStep = 0,
    this.availableMinutes = 480, // 8 hours default
  });

  final int currentStep;
  final int availableMinutes;

  DailyPlanningState copyWith({int? currentStep, int? availableMinutes}) =>
      DailyPlanningState(
        currentStep: currentStep ?? this.currentStep,
        availableMinutes: availableMinutes ?? this.availableMinutes,
      );
}

final dailyPlanningProvider =
    NotifierProvider<DailyPlanningNotifier, DailyPlanningState>(
  DailyPlanningNotifier.new,
);

class DailyPlanningNotifier extends Notifier<DailyPlanningState> {
  @override
  DailyPlanningState build() => const DailyPlanningState();

  GtdDatabase get _db => ref.read(databaseProvider);

  // ---- Step navigation -------------------------------------------------------

  void advanceStep() {
    state = state.copyWith(
        currentStep: (state.currentStep + 1).clamp(0, 3));
  }

  void goToStep(int step) {
    state = state.copyWith(currentStep: step.clamp(0, 3));
  }

  void setAvailableTime(int minutes) {
    state = state.copyWith(availableMinutes: minutes);
  }

  // ---- Task mutations (Step 1 — Next Actions) --------------------------------

  Future<void> selectTask(String id) =>
      _db.todoDao.selectForToday(id, kLocalUserId, planningToday());

  Future<void> skipTask(String id) =>
      _db.todoDao.skipForToday(id, kLocalUserId, planningToday());

  Future<void> undoTaskReview(String id) =>
      _db.todoDao.undoReview(id, kLocalUserId);

  Future<void> deferTask(String id) =>
      _db.todoDao.deferTaskToSomeday(id, kLocalUserId);

  // ---- Task mutations (Step 2 — Scheduled) -----------------------------------

  Future<void> confirmScheduledTask(String id) =>
      _db.todoDao.selectForToday(id, kLocalUserId, planningToday());

  Future<void> rescheduleTask(String id, DateTime newDate) =>
      _db.todoDao.rescheduleTask(id, kLocalUserId, newDate);

  // ---- Task mutations (Step 3 — Time Estimates) ------------------------------

  Future<void> setTimeEstimate(String id, int minutes) =>
      _db.todoDao.updateFields(id, kLocalUserId, timeEstimate: minutes);

  // ---- Ritual lifecycle ------------------------------------------------------

  /// Marks the ritual as complete for today and unlocks execution features.
  Future<void> startDay() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCompletedDateKey, planningToday());
    planningCompletionNotifier.value = true;
    state = const DailyPlanningState(); // reset UI state
  }

  /// Clears completion state and resets task selections so the user can
  /// re-plan mid-day.
  Future<void> reEnterPlanning() async {
    final today = planningToday();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kCompletedDateKey);
    await _db.todoDao.clearTodaySelections(kLocalUserId, today);
    planningCompletionNotifier.value = false;
    state = const DailyPlanningState(); // reset to Step 1
  }
}
