/// Providers and state management for the evening shutdown ritual (Issue #83).
///
/// Architecture mirrors the daily planning provider:
/// - [shutdownCompletionNotifier] — a [ValueNotifier] that tracks whether the
///   shutdown ritual has been completed today.
/// - [shutdownSessionDateProvider] — caches the session date to avoid boundary
///   bugs if the clock rolls past midnight mid-session.
/// - [EveningShutdownNotifier] — manages step navigation and delegates all
///   database writes to [TodoDao] shutdown methods.
/// - Stream providers expose live lists of completed and unfinished tasks.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/gtd_database.dart';
import '../models/todo.dart' show GtdState;
import '../services/notification_service.dart';
import 'auth_provider.dart';
import 'database_provider.dart';
import 'daily_planning_provider.dart' show planningToday;

export '../database/gtd_database.dart' show Todo;
export '../models/todo.dart' show GtdState;

// ---------------------------------------------------------------------------
// SharedPreferences keys
// ---------------------------------------------------------------------------

const _kShutdownCompletedDateKey = 'shutdown_ritual_completed_date';
const _kShutdownBannerDismissedDateKey = 'shutdown_banner_dismissed_date';
const _kShutdownNotificationSkippedDateKey =
    'shutdown_notification_skipped_date';
const _kShutdownNotificationSnoozedUntilKey =
    'shutdown_notification_snoozed_until';

/// Total number of shutdown ritual steps (0-indexed max).
const int _kShutdownMaxStep = 2;

// ---------------------------------------------------------------------------
// Router refresh notifiers
// ---------------------------------------------------------------------------

/// Tracks whether the shutdown ritual has been completed today.
final shutdownCompletionNotifier = ValueNotifier<bool>(false);

/// Global notifier for shutdown banner dismissal state.
final shutdownBannerDismissedNotifier = ValueNotifier<bool>(false);

/// Initialises [shutdownCompletionNotifier] and [shutdownBannerDismissedNotifier]
/// from [SharedPreferences].
///
/// Must be called once in [main] after [WidgetsFlutterBinding.ensureInitialized].
Future<void> initShutdownCompletion() async {
  final prefs = await SharedPreferences.getInstance();
  final today = planningToday();
  shutdownCompletionNotifier.value =
      prefs.getString(_kShutdownCompletedDateKey) == today;
  shutdownBannerDismissedNotifier.value =
      prefs.getString(_kShutdownBannerDismissedDateKey) == today;
}

// ---------------------------------------------------------------------------
// Notification suppression helpers
// ---------------------------------------------------------------------------

bool _shutdownNotificationSkippedToday = false;
bool _shutdownNotificationSnoozedActive = false;

/// Returns true if the user has skipped/snoozed shutdown notifications today.
bool isShutdownNotificationSuppressedToday() =>
    _shutdownNotificationSkippedToday || _shutdownNotificationSnoozedActive;

/// Reads shutdown skip/snooze state from [SharedPreferences] into module-level flags.
Future<void> loadShutdownNotificationSuppression() async {
  final prefs = await SharedPreferences.getInstance();
  final today = planningToday();
  _shutdownNotificationSkippedToday =
      prefs.getString(_kShutdownNotificationSkippedDateKey) == today;

  final snoozedUntilStr =
      prefs.getString(_kShutdownNotificationSnoozedUntilKey);
  if (snoozedUntilStr != null) {
    final snoozedUntil = DateTime.tryParse(snoozedUntilStr);
    _shutdownNotificationSnoozedActive =
        snoozedUntil != null && DateTime.now().isBefore(snoozedUntil);
  } else {
    _shutdownNotificationSnoozedActive = false;
  }
}

/// Persists and activates the "skip shutdown today" suppression.
Future<void> persistShutdownSkipToday() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kShutdownNotificationSkippedDateKey, planningToday());
  _shutdownNotificationSkippedToday = true;
}

/// Persists and activates a shutdown snooze until [until].
Future<void> persistShutdownSnoozedUntil(DateTime until) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
      _kShutdownNotificationSnoozedUntilKey, until.toIso8601String());
  _shutdownNotificationSnoozedActive = DateTime.now().isBefore(until);
}

// ---------------------------------------------------------------------------
// Session date cache
// ---------------------------------------------------------------------------

final shutdownSessionDateProvider =
    NotifierProvider<ShutdownSessionDateNotifier, String>(
  ShutdownSessionDateNotifier.new,
);

class ShutdownSessionDateNotifier extends Notifier<String> {
  @override
  String build() => planningToday();

  void reset() => state = planningToday();
}

// ---------------------------------------------------------------------------
// Stream providers — shutdown data
// ---------------------------------------------------------------------------

/// Tasks from today's plan that have been completed.
final completedTodayProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = ref.watch(shutdownSessionDateProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.todoDao.watchCompletedToday(userId, today);
});

/// Tasks from today's plan that are still unfinished (not done).
final unfinishedSelectedTodayProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = ref.watch(shutdownSessionDateProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.todoDao.watchUnfinishedSelectedToday(userId, today);
});

// ---------------------------------------------------------------------------
// EveningShutdownNotifier — step navigation + mutations
// ---------------------------------------------------------------------------

/// Immutable state for the evening shutdown UI.
class EveningShutdownState {
  const EveningShutdownState({
    this.currentStep = 0,
  });

  final int currentStep;

  EveningShutdownState copyWith({int? currentStep}) =>
      EveningShutdownState(currentStep: currentStep ?? this.currentStep);
}

final eveningShutdownProvider =
    NotifierProvider<EveningShutdownNotifier, EveningShutdownState>(
  EveningShutdownNotifier.new,
);

class EveningShutdownNotifier extends Notifier<EveningShutdownState> {
  @override
  EveningShutdownState build() => const EveningShutdownState();

  GtdDatabase get _db => ref.read(databaseProvider);
  String get _userId => ref.read(currentUserIdProvider);
  String get _today => ref.read(shutdownSessionDateProvider);

  String get _tomorrow {
    final parts = _today.split('-');
    final date = DateTime(
        int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
    final tomorrow = date.add(const Duration(days: 1));
    return '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
  }

  // ---- Step navigation -------------------------------------------------------

  void advanceStep() {
    state = state.copyWith(
        currentStep: (state.currentStep + 1).clamp(0, _kShutdownMaxStep));
  }

  void goToStep(int step) {
    state = state.copyWith(currentStep: step.clamp(0, _kShutdownMaxStep));
  }

  // ---- Task mutations --------------------------------------------------------

  /// Preselects [id] for tomorrow's plan (rolls it over).
  Future<void> rolloverTask(String id) =>
      _db.todoDao.rolloverTask(id, _userId, _tomorrow);

  /// Returns [id] to the unreviewed next-actions pool.
  Future<void> returnToNextActions(String id) =>
      _db.todoDao.returnToNextActions(id, _userId);

  /// Defers [id] to Someday/Maybe via the GTD state machine.
  Future<void> deferTask(String id) =>
      _db.todoDao.deferTaskToSomeday(id, _userId);

  // ---- Banner dismissal ------------------------------------------------------

  Future<void> dismissBannerForToday() async {
    final today = planningToday();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kShutdownBannerDismissedDateKey, today);
    shutdownBannerDismissedNotifier.value = true;
  }

  // ---- Notification skip / snooze --------------------------------------------

  Future<void> skipShutdownToday() async {
    await persistShutdownSkipToday();
    await NotificationService.instance.cancelShutdownReminder();
  }

  Future<void> snoozeShutdownNotification(int minutes) async {
    final until = DateTime.now().add(Duration(minutes: minutes));
    await persistShutdownSnoozedUntil(until);
    await NotificationService.instance.snoozeShutdownReminder(minutes);
  }

  // ---- Shutdown lifecycle ----------------------------------------------------

  /// Marks the shutdown ritual as complete for today.
  Future<void> closeDay() async {
    final today = _today;
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString(_kShutdownCompletedDateKey, today);
      shutdownCompletionNotifier.value = true;
      state = const EveningShutdownState();
    } catch (e) {
      await prefs.remove(_kShutdownCompletedDateKey);
      rethrow;
    }
  }
}
