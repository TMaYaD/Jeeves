/// Providers and state management for the daily planning ritual (Issue #82).
///
/// Architecture:
/// - [planningCompletionNotifier] — a [ValueNotifier] wired to GoRouter's
///   [refreshListenable] so the router re-evaluates the redirect on change.
/// - [planningSessionDateProvider] — a [StateProvider] that caches today's
///   date for the current session, preventing date-boundary inconsistencies
///   if the clock rolls past midnight mid-session.
/// - [DailyPlanningNotifier] — manages step navigation and available-minutes
///   state; delegates all database writes to [TodoDao] planning methods.
/// - Stream providers expose live lists of tasks for each ritual step.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/gtd_database.dart';
import '../models/todo.dart' show GtdState;
import 'database_provider.dart';
import 'user_constants.dart';

export '../database/gtd_database.dart' show Todo;
export '../models/todo.dart' show GtdState;

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

/// Total number of planning ritual steps (0-indexed max).
const int _maxStepIndex = 5;

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
// Session date cache
// ---------------------------------------------------------------------------

/// Caches the planning date for the current session.
///
/// Initialized to today's date when first read. [DailyPlanningNotifier.reEnterPlanning]
/// resets it via [PlanningSessionDateNotifier.reset] so the cached date stays
/// consistent even if the clock rolls past midnight mid-session.
final planningSessionDateProvider =
    NotifierProvider<PlanningSessionDateNotifier, String>(
  PlanningSessionDateNotifier.new,
);

class PlanningSessionDateNotifier extends Notifier<String> {
  @override
  String build() => planningToday();

  /// Refreshes the cached date to [planningToday()].
  ///
  /// Call this at the start of a new planning session (e.g. after
  /// [DailyPlanningNotifier.reEnterPlanning]).
  void reset() => state = planningToday();
}

// ---------------------------------------------------------------------------
// Stream providers — planning data
// ---------------------------------------------------------------------------

/// Next-action tasks not yet reviewed in today's planning session.
final nextActionsForPlanningProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = ref.watch(planningSessionDateProvider);
  return db.todoDao.watchNextActionsForPlanning(kLocalUserId, today);
});

/// Scheduled tasks with a due date on today, not yet confirmed in planning.
final scheduledDueTodayProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = ref.watch(planningSessionDateProvider);
  return db.todoDao.watchScheduledDueToday(kLocalUserId, today);
});

/// Tasks selected for today (selectedForToday == true).
final todaySelectedTasksProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = ref.watch(planningSessionDateProvider);
  return db.todoDao.watchSelectedForToday(kLocalUserId, today);
});

/// Selected tasks that are still missing a time estimate (drives Step 3).
final selectedTasksMissingEstimatesProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = ref.watch(planningSessionDateProvider);
  return db.todoDao.watchSelectedTasksMissingEstimates(kLocalUserId, today);
});

// ---------------------------------------------------------------------------
// DailyPlanningNotifier — step navigation + mutations
// ---------------------------------------------------------------------------

/// Immutable state for the daily planning UI.
class DailyPlanningState {
  const DailyPlanningState({
    this.currentStep = 0,
    this.availableMinutes = 480, // 8 hours default
    this.energyLevel,
  });

  final int currentStep;
  final int availableMinutes;

  /// User's self-reported energy level for today: 'low' | 'medium' | 'high'.
  final String? energyLevel;

  DailyPlanningState copyWith({
    int? currentStep,
    int? availableMinutes,
    String? energyLevel,
    bool clearEnergyLevel = false,
  }) =>
      DailyPlanningState(
        currentStep: currentStep ?? this.currentStep,
        availableMinutes: availableMinutes ?? this.availableMinutes,
        energyLevel: clearEnergyLevel ? null : (energyLevel ?? this.energyLevel),
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

  String get _sessionDate => ref.read(planningSessionDateProvider);

  // ---- Step navigation -------------------------------------------------------

  void advanceStep() {
    state = state.copyWith(
        currentStep: (state.currentStep + 1).clamp(0, _maxStepIndex));
  }

  void goToStep(int step) {
    state = state.copyWith(currentStep: step.clamp(0, _maxStepIndex));
  }

  void setAvailableTime(int minutes) {
    state = state.copyWith(availableMinutes: minutes);
  }

  void setEnergyLevel(String level) {
    state = state.copyWith(energyLevel: level);
  }

  // ---- Inbox clarification (Step 0) -----------------------------------------

  /// Updates mutable fields on an inbox item before it is processed.
  Future<void> updateInboxItemFields(
    String id, {
    String? title,
    String? notes,
    String? energyLevel,
    int? timeEstimate,
    DateTime? dueDate,
    bool clearDueDate = false,
  }) =>
      _db.todoDao.updateFields(
        id, kLocalUserId,
        title: title,
        notes: notes,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
        dueDate: dueDate,
        clearDueDate: clearDueDate,
      );

  /// Processes an inbox item to a GTD list (transitions out of inbox state).
  Future<void> processInboxItem(String id, GtdState newState) =>
      _db.inboxDao.processInboxItem(
        id,
        userId: kLocalUserId,
        newState: newState.value,
      );

  // ---- Task mutations (Step 2 — Next Actions review) -------------------------

  Future<void> selectTask(String id) =>
      _db.todoDao.selectForToday(id, kLocalUserId, _sessionDate);

  Future<void> skipTask(String id) =>
      _db.todoDao.skipForToday(id, kLocalUserId, _sessionDate);

  Future<void> undoTaskReview(String id) =>
      _db.todoDao.undoReview(id, kLocalUserId);

  Future<void> deferTask(String id) =>
      _db.todoDao.deferTaskToSomeday(id, kLocalUserId);

  // ---- Task mutations (Step 3 — Scheduled review) ----------------------------

  Future<void> confirmScheduledTask(String id) =>
      _db.todoDao.selectForToday(id, kLocalUserId, _sessionDate);

  Future<void> rescheduleTask(String id, DateTime newDate) =>
      _db.todoDao.rescheduleTask(id, kLocalUserId, newDate);

  // ---- Task mutations (Step 4 — Time Estimates) ------------------------------

  Future<void> setTimeEstimate(String id, int minutes) =>
      _db.todoDao.updateFields(id, kLocalUserId, timeEstimate: minutes);

  // ---- Ritual lifecycle ------------------------------------------------------

  /// Marks the ritual as complete for today and unlocks execution features.
  Future<void> startDay() async {
    final today = _sessionDate;
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString(_kCompletedDateKey, today);
      planningCompletionNotifier.value = true;
      state = const DailyPlanningState(); // reset UI state
    } catch (e) {
      // Attempt rollback of prefs on failure so persisted state stays
      // consistent with the in-memory notifier.
      await prefs.remove(_kCompletedDateKey);
      rethrow;
    }
  }

  /// Clears completion state and resets task selections so the user can
  /// re-plan mid-day.
  Future<void> reEnterPlanning() async {
    final today = _sessionDate;
    final prefs = await SharedPreferences.getInstance();
    // Clear DB first — it is the more failure-prone operation.  If it throws,
    // prefs and notifier state are left untouched (consistent).
    await _db.todoDao.clearTodaySelections(kLocalUserId, today);
    await prefs.remove(_kCompletedDateKey);
    // Reset the session date in case the clock crossed midnight.
    ref.read(planningSessionDateProvider.notifier).reset();
    planningCompletionNotifier.value = false;
    state = const DailyPlanningState(); // reset to Step 1
  }
}
