/// Providers and state management for the focus session planning ritual (Issue #82).
///
/// Architecture:
/// - [focusSessionPlanningCompletionNotifier] — a [ValueNotifier] wired to GoRouter's
///   [refreshListenable] so the router re-evaluates the redirect on change.
/// - [FocusSessionPlanningNotifier] — manages step navigation and task selection
///   state; delegates database writes to [FocusSessionDao] and [TodoDao].
/// - Task selection during the ritual is accumulated in-memory
///   ([pendingSelectedTaskIds] / [reviewedTaskIds]); [startDay] commits them
///   atomically by calling [FocusSessionDao.openSession].
/// - Stream providers expose live lists of tasks for each ritual step.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/gtd_database.dart';
import '../models/todo.dart' show GtdState;
import '../services/notification_service.dart';
import 'auth_provider.dart';
import 'database_provider.dart';

export '../database/gtd_database.dart' show Todo, FocusSession;
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

const _kBannerDismissedDateKey = 'planning_banner_dismissed_date';
const _kNotificationSkippedDateKey = 'planning_notification_skipped_date';
const _kNotificationSnoozedUntilKey = 'planning_notification_snoozed_until';

/// Total number of planning ritual steps (0-indexed max).
const int _maxStepIndex = 5;

// ---------------------------------------------------------------------------
// Router refresh notifier
// ---------------------------------------------------------------------------

/// Tracks whether the focus session planning ritual has been completed today.
///
/// GoRouter uses this as its [refreshListenable] so the redirect guard
/// re-evaluates whenever completion state changes (e.g. after [startDay] or
/// [reEnterPlanning]).
final focusSessionPlanningCompletionNotifier = ValueNotifier<bool>(false);

/// Global notifier for banner dismissal state — mirrors the SharedPreferences
/// key so widgets can react without a Riverpod container.
final focusSessionPlanningBannerDismissedNotifier = ValueNotifier<bool>(false);

/// Initialises [focusSessionPlanningBannerDismissedNotifier] from
/// [SharedPreferences].
///
/// Completion state is not persisted across restarts — [startDay] sets it
/// in-memory when the user finishes the ritual.
///
/// Must be called once in [main] after [WidgetsFlutterBinding.ensureInitialized].
Future<void> initFocusSessionPlanningCompletion() async {
  final prefs = await SharedPreferences.getInstance();
  final today = planningToday();
  focusSessionPlanningBannerDismissedNotifier.value =
      prefs.getString(_kBannerDismissedDateKey) == today;
}

// ---------------------------------------------------------------------------
// Notification suppression helpers (top-level so both the settings provider
// and notification handler can call them without a Riverpod container).
// ---------------------------------------------------------------------------

/// Returns true if the user has skipped planning notifications for today or
/// has an active snooze that hasn't expired yet.
bool isFocusSessionPlanningNotificationSuppressed() {
  // This is intentionally synchronous — callers that need the persisted value
  // should call [loadFocusSessionPlanningNotificationSuppression] first.
  return _notificationSkippedToday || _notificationSnoozedActive;
}

bool _notificationSkippedToday = false;
bool _notificationSnoozedActive = false;

/// Reads skip/snooze state from [SharedPreferences] into module-level flags.
Future<void> loadFocusSessionPlanningNotificationSuppression() async {
  final prefs = await SharedPreferences.getInstance();
  final today = planningToday();
  _notificationSkippedToday =
      prefs.getString(_kNotificationSkippedDateKey) == today;

  final snoozedUntilStr = prefs.getString(_kNotificationSnoozedUntilKey);
  if (snoozedUntilStr != null) {
    final snoozedUntil = DateTime.tryParse(snoozedUntilStr);
    _notificationSnoozedActive =
        snoozedUntil != null && DateTime.now().isBefore(snoozedUntil);
  } else {
    _notificationSnoozedActive = false;
  }
}

/// Persists and activates the "skip today" suppression.
Future<void> persistFocusSessionPlanningSkipToday() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kNotificationSkippedDateKey, planningToday());
  _notificationSkippedToday = true;
}

/// Persists and activates a snooze until [until].
Future<void> persistFocusSessionPlanningSnoozedUntil(DateTime until) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kNotificationSnoozedUntilKey, until.toIso8601String());
  _notificationSnoozedActive = DateTime.now().isBefore(until);
}

// ---------------------------------------------------------------------------
// Session providers
// ---------------------------------------------------------------------------

/// Stream of the user's currently open [FocusSession], or null.
final activeSessionProvider = StreamProvider<FocusSession?>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.focusSessionDao.watchActiveSession(userId);
});

/// Stream of [Todo] rows that are part of the user's active session, ordered
/// by their session position.
final activeSessionTasksProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.focusSessionDao.watchSessionTasksForUser(userId);
});

// ---------------------------------------------------------------------------
// Stream providers — planning data
// ---------------------------------------------------------------------------

/// Next-action tasks not yet reviewed in today's planning session.
final nextActionsForFocusSessionPlanningProvider =
    StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  final planningState = ref.watch(focusSessionPlanningProvider);
  final reviewed = {
    ...planningState.reviewedTaskIds,
    ...planningState.pendingSelectedTaskIds,
  };
  return db.todoDao
      .watchNextActions(userId)
      .map((all) => all.where((t) => !reviewed.contains(t.id)).toList());
});

/// Tasks selected for today (in-memory pending list, ordered by selection).
final focusSessionPlanningSelectedTasksProvider =
    StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  final ids = ref.watch(
    focusSessionPlanningProvider.select((s) => s.pendingSelectedTaskIds),
  );
  return db.todoDao.watchTodosById(userId, ids).map((tasks) {
    final indexById = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    final ordered = [...tasks];
    ordered.sort((a, b) =>
        (indexById[a.id] ?? 1 << 30).compareTo(indexById[b.id] ?? 1 << 30));
    return ordered;
  });
});

/// Selected tasks that are still missing a time estimate (drives Step 3).
final focusSessionPlanningTasksMissingEstimatesProvider =
    StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  final ids = ref.watch(
    focusSessionPlanningProvider.select((s) => s.pendingSelectedTaskIds),
  );
  return db.todoDao.watchTodosById(userId, ids).map(
        (tasks) => tasks.where((t) => t.timeEstimate == null).toList(),
      );
});

/// Tasks reviewed today but not selected (skipped / deferred).
final skippedNextActionsForFocusSessionPlanningProvider =
    StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  final planningState = ref.watch(focusSessionPlanningProvider);
  final skippedIds = planningState.reviewedTaskIds
      .where((id) => !planningState.pendingSelectedTaskIds.contains(id))
      .toList();
  return db.todoDao.watchTodosById(userId, skippedIds);
});

// ---------------------------------------------------------------------------
// FocusSessionPlanningNotifier — step navigation + mutations
// ---------------------------------------------------------------------------

/// Immutable state for the focus session planning UI.
class FocusSessionPlanningState {
  const FocusSessionPlanningState({
    this.currentStep = 0,
    this.availableMinutes = 480, // 8 hours default
    this.availableTimeSet = false,
    this.energyLevel,
    this.initialInboxCount,
    this.inboxClarifiedCount = 0,
    this.inboxSkippedCount = 0,
    this.pendingSelectedTaskIds = const [],
    this.reviewedTaskIds = const [],
  });

  final int currentStep;
  final int availableMinutes;

  /// True once the user has explicitly set available time (not the default).
  final bool availableTimeSet;

  /// User's self-reported energy level for today: 'low' | 'medium' | 'high'.
  final String? energyLevel;

  final int? initialInboxCount;
  final int inboxClarifiedCount;
  final int inboxSkippedCount;

  /// Task IDs the user has selected for today's plan (in selection order).
  /// Committed to the DB atomically when [FocusSessionPlanningNotifier.startDay]
  /// is called.
  final List<String> pendingSelectedTaskIds;

  /// Task IDs the user has reviewed but skipped (not selected).
  final List<String> reviewedTaskIds;

  FocusSessionPlanningState copyWith({
    int? currentStep,
    int? availableMinutes,
    bool? availableTimeSet,
    String? energyLevel,
    bool clearEnergyLevel = false,
    int? initialInboxCount,
    int? inboxClarifiedCount,
    int? inboxSkippedCount,
    List<String>? pendingSelectedTaskIds,
    List<String>? reviewedTaskIds,
  }) =>
      FocusSessionPlanningState(
        currentStep: currentStep ?? this.currentStep,
        availableMinutes: availableMinutes ?? this.availableMinutes,
        availableTimeSet: availableTimeSet ?? this.availableTimeSet,
        energyLevel: clearEnergyLevel ? null : (energyLevel ?? this.energyLevel),
        initialInboxCount: initialInboxCount ?? this.initialInboxCount,
        inboxClarifiedCount: inboxClarifiedCount ?? this.inboxClarifiedCount,
        inboxSkippedCount: inboxSkippedCount ?? this.inboxSkippedCount,
        pendingSelectedTaskIds:
            pendingSelectedTaskIds ?? this.pendingSelectedTaskIds,
        reviewedTaskIds: reviewedTaskIds ?? this.reviewedTaskIds,
      );
}

final focusSessionPlanningProvider =
    NotifierProvider<FocusSessionPlanningNotifier, FocusSessionPlanningState>(
  FocusSessionPlanningNotifier.new,
);

class FocusSessionPlanningNotifier extends Notifier<FocusSessionPlanningState> {
  @override
  FocusSessionPlanningState build() => const FocusSessionPlanningState();

  GtdDatabase get _db => ref.read(databaseProvider);
  String get _userId => ref.read(currentUserIdProvider);

  // ---- Step navigation -------------------------------------------------------

  void advanceStep() {
    state = state.copyWith(
        currentStep: (state.currentStep + 1).clamp(0, _maxStepIndex));
  }

  void goToStep(int step) {
    state = state.copyWith(currentStep: step.clamp(0, _maxStepIndex));
  }

  void setAvailableTime(int minutes) {
    state = state.copyWith(availableMinutes: minutes, availableTimeSet: true);
  }

  void setEnergyLevel(String level) {
    state = state.copyWith(energyLevel: level);
  }

  void setInitialInboxCount(int count) {
    state = state.copyWith(initialInboxCount: count);
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
        id, _userId,
        title: title,
        notes: notes,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
        dueDate: dueDate,
        clearDueDate: clearDueDate,
      );

  /// Processes an inbox item by setting clarified = true and transitioning
  /// to [newState].
  Future<void> processInboxItem(String id, GtdState newState) async {
    await _db.inboxDao.processInboxItem(
      id,
      userId: _userId,
      newState: newState.value,
    );
    state = state.copyWith(
      inboxClarifiedCount: state.inboxClarifiedCount + 1,
    );
  }

  /// Processes an inbox item to the Waiting For list.
  ///
  /// Sets clarified = true, state = next_action, and writes [waitingForText]
  /// to the waiting_for column so the item appears in the Waiting For view.
  Future<void> processInboxItemToWaitingFor(
      String id, String waitingForText) async {
    final normalizedWaitingFor = waitingForText.trim();
    await _db.transaction(() async {
      await _db.inboxDao.processInboxItem(
        id,
        userId: _userId,
        newState: GtdState.nextAction.value,
      );
      await _db.todoDao.setWaitingFor(id, _userId, normalizedWaitingFor);
    });
    state = state.copyWith(
      inboxClarifiedCount: state.inboxClarifiedCount + 1,
    );
  }

  /// Processes an inbox item to the maybe list.
  ///
  /// Sets clarified = true, state = next_action, and intent = 'maybe'
  /// so the item appears in the Maybe view rather than Next Actions.
  Future<void> processInboxItemToMaybe(String id) async {
    await _db.inboxDao.processInboxItem(
      id,
      userId: _userId,
      newState: GtdState.nextAction.value,
      intent: 'maybe',
    );
    state = state.copyWith(
      inboxClarifiedCount: state.inboxClarifiedCount + 1,
    );
  }

  /// Skips an inbox item for today without clarifying it.
  Future<void> skipInboxItem(String id) async {
    state = state.copyWith(
      inboxSkippedCount: state.inboxSkippedCount + 1,
    );
  }

  // ---- Task mutations (Step 2 — Next Actions review) -------------------------

  /// Adds [id] to the pending day's plan (in-memory; committed by [startDay]).
  void selectTask(String id) {
    if (state.pendingSelectedTaskIds.contains(id)) return;
    state = state.copyWith(
      pendingSelectedTaskIds: [...state.pendingSelectedTaskIds, id],
      // Remove from skipped list if the user previously skipped this task.
      reviewedTaskIds: state.reviewedTaskIds.where((t) => t != id).toList(),
    );
  }

  /// Records [id] as skipped (reviewed but not selected).
  void skipTask(String id) {
    if (state.reviewedTaskIds.contains(id)) return;
    state = state.copyWith(
      reviewedTaskIds: [...state.reviewedTaskIds, id],
      // Remove from selected list if the user previously selected this task.
      pendingSelectedTaskIds:
          state.pendingSelectedTaskIds.where((t) => t != id).toList(),
    );
  }

  /// Returns [id] to the unreviewed pool by removing it from both lists.
  void undoTaskReview(String id) {
    state = state.copyWith(
      pendingSelectedTaskIds:
          state.pendingSelectedTaskIds.where((t) => t != id).toList(),
      reviewedTaskIds: state.reviewedTaskIds.where((t) => t != id).toList(),
    );
  }

  Future<void> deferTask(String id) => _db.todoDao.deferTaskToMaybe(id, _userId);

  // ---- Task mutations (Step 3 — Scheduled review) ----------------------------

  /// Adds [id] to the pending day's plan (same as [selectTask]).
  void confirmScheduledTask(String id) => selectTask(id);

  Future<void> rescheduleTask(String id, DateTime newDate) =>
      _db.todoDao.rescheduleTask(id, _userId, newDate);

  // ---- Task mutations (Step 4 — Time Estimates) ------------------------------

  Future<void> setTimeEstimate(String id, int minutes) =>
      _db.todoDao.updateFields(id, _userId, timeEstimate: minutes);

  // ---- Energy-based auto-skip ------------------------------------------------

  /// Skips all pending next-action tasks whose energy requirement exceeds the
  /// day's energy level.
  ///
  /// Called when the user advances past the Energy Check-in step so that the
  /// Plan Summary only shows tasks the user can realistically do today.
  ///
  /// - 'low' day  → auto-skips 'medium' and 'high' tasks.
  /// - 'medium' day → auto-skips 'high' tasks.
  /// - 'high' day or no energy set → no auto-skips.
  /// - Tasks with no energy tag are never auto-skipped.
  Future<void> autoSkipByEnergy() async {
    final dayEnergy = state.energyLevel;
    if (dayEnergy == null || dayEnergy == 'high') return;

    const energyOrder = {'low': 1, 'medium': 2, 'high': 3};
    final dayLevel = energyOrder[dayEnergy] ?? 0;

    final allNextActions = await _db.todoDao.watchNextActions(_userId).first;
    final alreadyReviewed = {
      ...state.reviewedTaskIds,
      ...state.pendingSelectedTaskIds,
    };

    final toSkip = allNextActions
        .where((t) =>
            !alreadyReviewed.contains(t.id) &&
            t.energyLevel != null &&
            (energyOrder[t.energyLevel!] ?? 0) > dayLevel)
        .map((t) => t.id)
        .toList();

    if (toSkip.isNotEmpty) {
      state = state.copyWith(
        reviewedTaskIds: [...state.reviewedTaskIds, ...toSkip],
      );
    }
  }

  // ---- Banner dismissal ------------------------------------------------------

  /// Hides the planning banner for the rest of today.
  Future<void> dismissBannerForToday() async {
    final today = planningToday();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBannerDismissedDateKey, today);
    focusSessionPlanningBannerDismissedNotifier.value = true;
  }

  // ---- Notification skip / snooze --------------------------------------------

  /// Suppresses all planning nudges until the next calendar day and cancels
  /// any scheduled notification for today.
  Future<void> skipPlanningToday() async {
    await persistFocusSessionPlanningSkipToday();
    await NotificationService.instance.cancelFocusSessionPlanningReminder();
  }

  /// Snoozes the planning notification by [minutes] and reschedules it as a
  /// one-off fire.
  Future<void> snoozePlanningNotification(int minutes) async {
    final until = DateTime.now().add(Duration(minutes: minutes));
    await persistFocusSessionPlanningSnoozedUntil(until);
    await NotificationService.instance.snoozeFocusSessionPlanningReminder(minutes);
  }

  // ---- Ritual lifecycle ------------------------------------------------------

  /// Opens a new [FocusSession] with the pending task list and marks the
  /// ritual as complete for today.
  Future<void> startDay() async {
    await _db.focusSessionDao.openSession(
      userId: _userId,
      taskIds: state.pendingSelectedTaskIds,
    );
    focusSessionPlanningCompletionNotifier.value = true;
    state = FocusSessionPlanningState(
      energyLevel: state.energyLevel,
      availableMinutes: state.availableMinutes,
      availableTimeSet: state.availableTimeSet,
    );
  }

  /// Clears completion state and returns the user to the planning ritual.
  ///
  /// Task selections are **cleared** so the user can re-plan from scratch.
  /// Energy level and available time are preserved.
  Future<void> reEnterPlanning() async {
    final preservedEnergy = state.energyLevel;
    final preservedMinutes = state.availableMinutes;
    final preservedTimeSet = state.availableTimeSet;
    focusSessionPlanningCompletionNotifier.value = false;
    state = FocusSessionPlanningState(
      currentStep: 0,
      availableMinutes: preservedMinutes,
      availableTimeSet: preservedTimeSet,
      energyLevel: preservedEnergy,
    );
  }
}
