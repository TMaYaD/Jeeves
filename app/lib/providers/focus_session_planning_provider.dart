/// Providers and state management for the focus session planning ritual (Issue #82).
///
/// Architecture:
/// - [focusSessionPlanningCompletionNotifier] — a [ValueNotifier] wired to GoRouter's
///   [refreshListenable] so the router re-evaluates the redirect on change.
/// - [focusSessionPlanningDateProvider] — a [StateProvider] that caches today's
///   date for the current session, preventing date-boundary inconsistencies
///   if the clock rolls past midnight mid-session.
/// - [FocusSessionPlanningNotifier] — manages step navigation and available-minutes
///   state; delegates all database writes to [TodoDao] planning methods.
/// - Stream providers expose live lists of tasks for each ritual step.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/planning_settings_keys.dart';
import '../database/gtd_database.dart';
import '../models/todo.dart' show GtdState;
import '../services/notification_service.dart';
import 'auth_provider.dart';
import 'database_provider.dart';

export '../database/gtd_database.dart' show Todo;
export '../models/todo.dart' show GtdState;

// ---------------------------------------------------------------------------
// Date helpers
// ---------------------------------------------------------------------------

/// In-memory cache of the user's planning time, used by [planningToday].
///
/// Defaults to 08:00. Call [loadPlanningTime] at startup and
/// [updateCachedPlanningTime] whenever the user changes their planning time.
TimeOfDay _cachedPlanningTime = const TimeOfDay(hour: 8, minute: 0);

/// Returns the cached planning time (set by [loadPlanningTime] or
/// [updateCachedPlanningTime]).
TimeOfDay get currentCachedPlanningTime => _cachedPlanningTime;

/// Loads the user's planning time from [SharedPreferences] into the in-memory
/// cache so that [planningToday] reflects the correct day boundary.
///
/// Must be called once in [main] before any call to [planningToday].
Future<void> loadPlanningTime() async {
  final prefs = await SharedPreferences.getInstance();
  final hour = prefs.getInt(kSettingsTimeHour) ?? 8;
  final minute = prefs.getInt(kSettingsTimeMinute) ?? 0;
  _cachedPlanningTime = TimeOfDay(hour: hour, minute: minute);
}

/// Updates the in-memory planning-time cache. Call this whenever the user
/// saves a new planning time so that subsequent [planningToday] calls use
/// the updated boundary without requiring an app restart.
void updateCachedPlanningTime(TimeOfDay time) {
  _cachedPlanningTime = time;
}

/// Returns the planning-day identifier as an ISO-8601 date string (yyyy-MM-dd).
///
/// The planning day begins at the user's configured planning time (from
/// [_cachedPlanningTime]) and ends at the same time the following morning.
/// This means a user who completes the ritual at 23:55 and reopens the app
/// at 00:05 is still within the same planning day until the planning time
/// rolls over (e.g. 08:00 the next morning).
String planningToday() {
  final now = DateTime.now();
  final todayBoundary = DateTime(
    now.year,
    now.month,
    now.day,
    _cachedPlanningTime.hour,
    _cachedPlanningTime.minute,
  );
  // Before the planning boundary the current calendar day hasn't "started" yet,
  // so we treat it as belonging to the previous planning day.
  final effective =
      now.isBefore(todayBoundary) ? now.subtract(const Duration(days: 1)) : now;
  return '${effective.year.toString().padLeft(4, '0')}-'
      '${effective.month.toString().padLeft(2, '0')}-'
      '${effective.day.toString().padLeft(2, '0')}';
}

const _kCompletedDateKey = 'planning_ritual_completed_date';
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

/// Initialises [focusSessionPlanningCompletionNotifier] and
/// [focusSessionPlanningBannerDismissedNotifier] from [SharedPreferences].
///
/// Must be called once in [main] after [WidgetsFlutterBinding.ensureInitialized].
Future<void> initFocusSessionPlanningCompletion() async {
  final prefs = await SharedPreferences.getInstance();
  final today = planningToday();
  focusSessionPlanningCompletionNotifier.value =
      prefs.getString(_kCompletedDateKey) == today;
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

/// Clears the active snooze flag without touching SharedPreferences.
///
/// Called by [DailyStateRefresher] when the one-shot snooze timer fires.
void clearNotificationSnooze() {
  _notificationSnoozedActive = false;
}

/// Called when a snooze is persisted (from [persistFocusSessionPlanningSnoozedUntil] callers).
///
/// [DailyStateRefresher] sets this to schedule its one-shot snooze timer,
/// avoiding a circular import between the two files.
void Function(DateTime until)? onSnoozeScheduled;

/// Re-reads planning completion and banner-dismissed state from
/// [SharedPreferences] and updates the global [ValueNotifier]s.
///
/// Called by [DailyStateRefresher] on app resume and at the planning-time
/// boundary so the router redirect and banner reflect the current day without
/// requiring an app restart.
Future<void> refreshPlanningState() async {
  final prefs = await SharedPreferences.getInstance();
  final today = planningToday();
  focusSessionPlanningCompletionNotifier.value =
      prefs.getString(_kCompletedDateKey) == today;
  focusSessionPlanningBannerDismissedNotifier.value =
      prefs.getString(_kBannerDismissedDateKey) == today;
  await loadFocusSessionPlanningNotificationSuppression();
}

// ---------------------------------------------------------------------------
// Session date cache
// ---------------------------------------------------------------------------

/// Caches the planning date for the current session.
///
/// Initialized to today's date when first read. [FocusSessionPlanningNotifier.reEnterPlanning]
/// resets it via [FocusSessionPlanningDateNotifier.reset] so the cached date stays
/// consistent even if the clock rolls past midnight mid-session.
final focusSessionPlanningDateProvider =
    NotifierProvider<FocusSessionPlanningDateNotifier, String>(
  FocusSessionPlanningDateNotifier.new,
);

class FocusSessionPlanningDateNotifier extends Notifier<String> {
  @override
  String build() => planningToday();

  /// Refreshes the cached date to [planningToday()].
  ///
  /// Call this at the start of a new planning session (e.g. after
  /// [FocusSessionPlanningNotifier.reEnterPlanning]).
  void reset() => state = planningToday();
}

// ---------------------------------------------------------------------------
// Stream providers — planning data
// ---------------------------------------------------------------------------

/// Next-action tasks not yet reviewed in today's planning session.
final nextActionsForFocusSessionPlanningProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = ref.watch(focusSessionPlanningDateProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.todoDao.watchNextActionsForPlanning(userId, today);
});

/// Scheduled tasks with a due date on today, not yet confirmed in planning.
final focusSessionPlanningScheduledDueTodayProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = ref.watch(focusSessionPlanningDateProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.todoDao.watchScheduledDueToday(userId, today);
});

/// Tasks selected for today (selectedForToday == true).
final focusSessionPlanningSelectedTasksProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = ref.watch(focusSessionPlanningDateProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.todoDao.watchSelectedForToday(userId, today);
});

/// Selected tasks that are still missing a time estimate (drives Step 3).
final focusSessionPlanningTasksMissingEstimatesProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = ref.watch(focusSessionPlanningDateProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.todoDao.watchSelectedTasksMissingEstimates(userId, today);
});

/// Skipped Next Actions for today.
final skippedNextActionsForFocusSessionPlanningProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = ref.watch(focusSessionPlanningDateProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.todoDao.watchSkippedNextActionsForPlanning(userId, today);
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

  FocusSessionPlanningState copyWith({
    int? currentStep,
    int? availableMinutes,
    bool? availableTimeSet,
    String? energyLevel,
    bool clearEnergyLevel = false,
    int? initialInboxCount,
    int? inboxClarifiedCount,
    int? inboxSkippedCount,
  }) =>
      FocusSessionPlanningState(
        currentStep: currentStep ?? this.currentStep,
        availableMinutes: availableMinutes ?? this.availableMinutes,
        availableTimeSet: availableTimeSet ?? this.availableTimeSet,
        energyLevel: clearEnergyLevel ? null : (energyLevel ?? this.energyLevel),
        initialInboxCount: initialInboxCount ?? this.initialInboxCount,
        inboxClarifiedCount: inboxClarifiedCount ?? this.inboxClarifiedCount,
        inboxSkippedCount: inboxSkippedCount ?? this.inboxSkippedCount,
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
  String get _sessionDate => ref.read(focusSessionPlanningDateProvider);

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

  /// Processes an inbox item to a GTD list (transitions out of inbox state).
  ///
  /// The GTD state machine deliberately forbids `inbox → scheduled` as a
  /// single hop (see `GtdStateMachine`); scheduling requires first clarifying
  /// the item as a next action. When [newState] is [GtdState.scheduled], this
  /// method uses the atomic [InboxDao.transitionInboxToScheduled] to perform
  /// the two-hop transition `inbox → nextAction → scheduled` in a single
  /// transaction.
  Future<void> processInboxItem(String id, GtdState newState) async {
    if (newState == GtdState.scheduled) {
      await _db.inboxDao.transitionInboxToScheduled(
        id,
        userId: _userId,
      );
    } else {
      await _db.inboxDao.processInboxItem(
        id,
        userId: _userId,
        newState: newState.value,
      );
    }
    state = state.copyWith(
      inboxClarifiedCount: state.inboxClarifiedCount + 1,
    );
  }

  /// Skips an inbox item for today without clarifying it.
  Future<void> skipInboxItem(String id) async {
    await _db.todoDao.skipForToday(id, _userId, _sessionDate);
    state = state.copyWith(
      inboxSkippedCount: state.inboxSkippedCount + 1,
    );
  }

  // ---- Task mutations (Step 2 — Next Actions review) -------------------------

  Future<void> selectTask(String id) =>
      _db.todoDao.selectForToday(id, _userId, _sessionDate);

  Future<void> skipTask(String id) =>
      _db.todoDao.skipForToday(id, _userId, _sessionDate);

  Future<void> undoTaskReview(String id) =>
      _db.todoDao.undoReview(id, _userId);

  Future<void> deferTask(String id) =>
      _db.todoDao.deferTaskToSomeday(id, _userId);

  // ---- Task mutations (Step 3 — Scheduled review) ----------------------------

  Future<void> confirmScheduledTask(String id) =>
      _db.todoDao.selectForToday(id, _userId, _sessionDate);

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
    final today = _sessionDate;

    final pending =
        await _db.todoDao.watchNextActionsForPlanning(_userId, today).first;
    for (final task in pending) {
      if (task.energyLevel != null) {
        final taskLevel = energyOrder[task.energyLevel] ?? 0;
        if (taskLevel > dayLevel) {
          await _db.todoDao.skipForToday(task.id, _userId, today);
        }
      }
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
    // Notify the refresher so it can schedule a one-shot timer that clears
    // the snooze flag when it expires (avoiding a circular import).
    onSnoozeScheduled?.call(until);
  }

  // ---- Ritual lifecycle ------------------------------------------------------

  /// Marks the ritual as complete for today and unlocks execution features.
  Future<void> startDay() async {
    final today = _sessionDate;
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString(_kCompletedDateKey, today);
      focusSessionPlanningCompletionNotifier.value = true;
      // Reset step/inbox counters but keep energy and time so reEnterPlanning()
      // can restore them if the user replans later in the same session.
      state = FocusSessionPlanningState(
        energyLevel: state.energyLevel,
        availableMinutes: state.availableMinutes,
        availableTimeSet: state.availableTimeSet,
      );
    } catch (e) {
      // Attempt rollback of prefs on failure so persisted state stays
      // consistent with the in-memory notifier.
      await prefs.remove(_kCompletedDateKey);
      rethrow;
    }
  }

  /// Clears completion state and returns the user to the planning ritual.
  ///
  /// All existing task selections (selected and skipped) are **preserved** so
  /// the day's plan is unchanged on re-entry.  The user can adjust individual
  /// tasks via the Plan Summary screen's action buttons.  Energy level and
  /// available time are also preserved so the user doesn't have to re-enter
  /// them.
  Future<void> reEnterPlanning() async {
    final today = _sessionDate;
    final prefs = await SharedPreferences.getInstance();
    // Snapshot state values to restore in the new planning session.
    final preservedEnergy = state.energyLevel;
    final preservedMinutes = state.availableMinutes;
    final preservedTimeSet = state.availableTimeSet;
    try {
      await prefs.remove(_kCompletedDateKey);
      // Reset the session date in case the clock crossed midnight.
      ref.read(focusSessionPlanningDateProvider.notifier).reset();
      focusSessionPlanningCompletionNotifier.value = false;
      state = FocusSessionPlanningState(
        currentStep: 0,
        availableMinutes: preservedMinutes,
        availableTimeSet: preservedTimeSet,
        energyLevel: preservedEnergy,
      );
    } catch (e) {
      // Restore the completion flag so the router guard doesn't block
      // re-entry on the next attempt.
      await prefs.setString(_kCompletedDateKey, today);
      rethrow;
    }
  }
}
