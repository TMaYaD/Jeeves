/// Providers and state management for the evening shutdown ritual (Issue #83).
///
/// After the FocusSession refactor (#185), "today's plan" is the set of tasks
/// that belong to the user's currently open [FocusSession]. The shutdown
/// ritual reviews completed members, lets the user assign a disposition
/// (rollover / leave / maybe) to each unfinished member, and then atomically
/// closes the session via [FocusSessionDao.reviewAndCloseSession].
///
/// Public surface:
/// - [shutdownCompletionNotifier], [shutdownBannerDismissedNotifier] —
///   [ValueNotifier]s consumed by the banner / app shell.
/// - [initShutdownCompletion] — seeds notifiers from [SharedPreferences];
///   call once in [main] before [runApp].
/// - Notification skip/snooze helpers used by main.dart on action taps.
/// - [completedTodayProvider], [unfinishedSelectedTodayProvider] — stream
///   providers driven by the active focus session's members.
/// - [eveningShutdownProvider] — step / disposition state for the ritual.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/gtd_database.dart';
import '../services/notification_service.dart';
import 'database_provider.dart';
import 'focus_session_planning_provider.dart' show planningToday;
import 'synced_preferences_provider.dart';

// Re-export Todo so UI consumers (e.g. unfinished_tasks_step.dart) can use
// the type without taking a direct dependency on the database layer.
export '../database/gtd_database.dart' show Todo;

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

bool _parseSnoozedActive(String? snoozedUntilStr) {
  if (snoozedUntilStr == null) return false;
  final snoozedUntil = DateTime.tryParse(snoozedUntilStr);
  return snoozedUntil != null && DateTime.now().isBefore(snoozedUntil);
}

/// Returns true if the user has skipped/snoozed shutdown notifications today.
bool isShutdownNotificationSuppressedToday() =>
    _shutdownNotificationSkippedToday || _shutdownNotificationSnoozedActive;

/// Reads shutdown skip/snooze state from [SharedPreferences] into module-level flags.
Future<void> loadShutdownNotificationSuppression() async {
  final prefs = await SharedPreferences.getInstance();
  final today = planningToday();
  _shutdownNotificationSkippedToday =
      prefs.getString(_kShutdownNotificationSkippedDateKey) == today;

  _shutdownNotificationSnoozedActive = _parseSnoozedActive(
    prefs.getString(_kShutdownNotificationSnoozedUntilKey),
  );
}

/// Persists and activates the "skip shutdown today" suppression.
///
/// Dual-writes to SharedPreferences (startup reads) and synced preferences
/// (cross-device visibility). Pass [ref] to enable the Drift write.
Future<void> persistShutdownSkipToday({Ref? ref}) async {
  final today = planningToday();
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kShutdownNotificationSkippedDateKey, today);
  _shutdownNotificationSkippedToday = true;
  if (ref != null) {
    await syncedPrefs(ref).set(_kShutdownNotificationSkippedDateKey, today);
  }
}

/// Persists and activates a shutdown snooze until [until].
///
/// Dual-writes to SharedPreferences (startup reads) and synced preferences
/// (cross-device visibility). Pass [ref] to enable the Drift write.
Future<void> persistShutdownSnoozedUntil(DateTime until, {Ref? ref}) async {
  final value = until.toIso8601String();
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kShutdownNotificationSnoozedUntilKey, value);
  _shutdownNotificationSnoozedActive = DateTime.now().isBefore(until);
  if (ref != null) {
    await syncedPrefs(ref).set(_kShutdownNotificationSnoozedUntilKey, value);
  }
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
// Stream providers — backed by the active focus session
// ---------------------------------------------------------------------------

/// Tasks from the active focus session that have been completed
/// (i.e. [Todo.doneAt] is not null).
final completedTodayProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.focusSessionDao.watchActiveSessionTasks().map(
        (tasks) => tasks.where((t) => t.doneAt != null).toList(),
      );
});

/// Tasks from the active focus session that are still unfinished
/// (no [doneAt]) **and** have not yet been assigned a shutdown disposition
/// in the current ritual.
///
/// The disposition map is the in-memory state on [eveningShutdownProvider]; it
/// only persists to the DB when [EveningShutdownNotifier.closeDay] is called.
/// Filtering here gives the donor's "one-at-a-time resolve" UX without
/// requiring intermediate DB writes.
final unfinishedSelectedTodayProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final dispositions = ref.watch(
    eveningShutdownProvider.select((s) => s.dispositions),
  );
  return db.focusSessionDao.watchActiveSessionTasks().map(
        (tasks) => tasks
            .where((t) =>
                t.doneAt == null && !dispositions.containsKey(t.id))
            .toList(),
      );
});

// ---------------------------------------------------------------------------
// EveningShutdownNotifier — step navigation + disposition state
// ---------------------------------------------------------------------------

/// Disposition values written to [focus_session_tasks.disposition]. The DAO
/// expects raw strings; we keep them in one place to avoid typos.
const _kDispRollover = 'rollover';
const _kDispLeave = 'leave';
const _kDispMaybe = 'maybe';

/// Immutable state for the evening shutdown UI.
class EveningShutdownState {
  const EveningShutdownState({
    this.currentStep = 0,
    this.dispositions = const {},
  });

  final int currentStep;

  /// Maps task ID → disposition string ('rollover' | 'leave' | 'maybe').
  /// Held in memory until [EveningShutdownNotifier.closeDay] commits via
  /// [FocusSessionDao.reviewAndCloseSession].
  final Map<String, String> dispositions;

  EveningShutdownState copyWith({
    int? currentStep,
    Map<String, String>? dispositions,
  }) =>
      EveningShutdownState(
        currentStep: currentStep ?? this.currentStep,
        dispositions: dispositions ?? this.dispositions,
      );
}

final eveningShutdownProvider =
    NotifierProvider<EveningShutdownNotifier, EveningShutdownState>(
  EveningShutdownNotifier.new,
);

class EveningShutdownNotifier extends Notifier<EveningShutdownState> {
  @override
  EveningShutdownState build() {
    // Update shutdown ValueNotifiers and suppression flags when Drift receives cross-device sync.
    ref.listen(syncedPreferencesProvider, (_, next) {
      if (next is AsyncData<SyncedPreferences>) {
        final today = planningToday();
        final completed =
            next.value.get<String>(_kShutdownCompletedDateKey) == today;
        final bannerDismissed =
            next.value.get<String>(_kShutdownBannerDismissedDateKey) == today;
        shutdownCompletionNotifier.value = completed;
        shutdownBannerDismissedNotifier.value = bannerDismissed;

        _shutdownNotificationSkippedToday =
            next.value.get<String>(_kShutdownNotificationSkippedDateKey) == today;

        _shutdownNotificationSnoozedActive = _parseSnoozedActive(
          next.value.get<String>(_kShutdownNotificationSnoozedUntilKey),
        );
      }
    });
    return const EveningShutdownState();
  }

  GtdDatabase get _db => ref.read(databaseProvider);

  // ---- Step navigation -------------------------------------------------------

  void advanceStep() {
    state = state.copyWith(
        currentStep: (state.currentStep + 1).clamp(0, _kShutdownMaxStep));
  }

  void goToStep(int step) {
    state = state.copyWith(currentStep: step.clamp(0, _kShutdownMaxStep));
  }

  // ---- Task disposition (in-memory) ------------------------------------------

  /// Marks [id] for rollover into tomorrow's session. Held in memory until
  /// [closeDay] commits.
  void rolloverTask(String id) => _setDisposition(id, _kDispRollover);

  /// Marks [id] to remain in next-actions (the task is already
  /// `intent='next'`, `clarified=true`, `done_at IS NULL`, so it surfaces
  /// naturally in tomorrow's planning).
  void returnToNextActions(String id) => _setDisposition(id, _kDispLeave);

  /// Marks [id] to defer to Someday/Maybe. The intent flip happens atomically
  /// during [closeDay] via [FocusSessionDao.reviewAndCloseSession].
  void deferTask(String id) => _setDisposition(id, _kDispMaybe);

  void _setDisposition(String id, String disposition) {
    state = state.copyWith(
      dispositions: {...state.dispositions, id: disposition},
    );
  }

  // ---- Banner dismissal ------------------------------------------------------

  Future<void> dismissBannerForToday() async {
    final today = planningToday();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kShutdownBannerDismissedDateKey, today);
    shutdownBannerDismissedNotifier.value = true;
    await syncedPrefs(ref).set(_kShutdownBannerDismissedDateKey, today);
  }

  // ---- Notification skip / snooze --------------------------------------------

  Future<void> skipShutdownToday() async {
    await persistShutdownSkipToday(ref: ref);
    await NotificationService.instance.cancelShutdownReminder();
  }

  Future<void> snoozeShutdownNotification(int minutes) async {
    final until = DateTime.now().add(Duration(minutes: minutes));
    await persistShutdownSnoozedUntil(until, ref: ref);
    await NotificationService.instance.snoozeShutdownReminder(minutes);
  }

  // ---- Shutdown lifecycle ----------------------------------------------------

  /// Atomically commits accumulated dispositions, closes the active focus
  /// session, and flips the completion notifier so the banner / focus-screen
  /// entry stand down for the rest of today.
  ///
  /// Tasks not present in [state.dispositions] are left as-is on
  /// [focus_session_tasks] (their disposition column stays at its default).
  /// Done tasks are filtered out because [FocusSessionDao.reviewAndCloseSession]
  /// expects callers to do so.
  Future<void> closeDay({DateTime? now}) async {
    final session = await _db.focusSessionDao.getActiveSession();
    if (session != null) {
      await _db.focusSessionDao.reviewAndCloseSession(
        sessionId: session.id,
        dispositions: state.dispositions,
        now: now,
      );
    }

    final today = planningToday();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString(_kShutdownCompletedDateKey, today);
      shutdownCompletionNotifier.value = true;
      await syncedPrefs(ref).set(_kShutdownCompletedDateKey, today);
      state = const EveningShutdownState();
    } catch (e) {
      await prefs.remove(_kShutdownCompletedDateKey);
      rethrow;
    }
  }
}
