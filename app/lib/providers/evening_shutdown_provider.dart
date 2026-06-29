/// Providers and state management for the evening shutdown ritual (Issue #83).
///
/// After the FocusSession refactor (#185), "today's plan" is the set of tasks
/// that belong to the user's currently open [FocusSession]. The shutdown
/// ritual reviews completed members, lets the user assign a disposition
/// (rollover / leave / maybe) to each unfinished member, and then atomically
/// closes the session via [FocusSessionDao.reviewAndCloseSession].
///
/// Public surface:
/// - Notification skip/snooze helpers used by main.dart on action taps.
/// - [completedTodayProvider], [unfinishedSelectedTodayProvider] — stream
///   providers driven by the active focus session's members.
/// - [eveningShutdownProvider] — step / disposition state for the ritual.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/gtd_database.dart';
import '../models/ritual.dart';
import '../services/notification_service.dart';
import '../utils/snapshot_nav.dart';
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
const _kShutdownNotificationSkippedDateKey =
    'shutdown_notification_skipped_date';
const _kShutdownNotificationSnoozedUntilKey =
    'shutdown_notification_snoozed_until';

/// Total number of shutdown ritual steps (0-indexed max).
const int _kShutdownMaxStep = 2;

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

/// Returns true iff the user has tapped "Skip today" (as distinct from an
/// active snooze). The reschedule logic uses this to suppress *today*'s
/// recurring fire while leaving tomorrow's intact; a snooze is satisfied by
/// its own one-off and does not need to touch the recurring schedule.
bool isShutdownNotificationSkippedToday() =>
    _shutdownNotificationSkippedToday;

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
/// Filtering here gives the live "remaining tasks" count used by the banner
/// and other consumers outside the ritual step itself.
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
    this.unfinishedNav = const SnapshotNav<Todo>(),
  });

  final int currentStep;

  /// Maps task ID → disposition string ('rollover' | 'leave' | 'maybe').
  /// Held in memory until [EveningShutdownNotifier.closeDay] commits via
  /// [FocusSessionDao.reviewAndCloseSession].
  final Map<String, String> dispositions;

  /// Fixed snapshot of unfinished session tasks plus the navigation cursor.
  /// items == null until loaded.
  final SnapshotNav<Todo> unfinishedNav;

  EveningShutdownState copyWith({
    int? currentStep,
    Map<String, String>? dispositions,
    SnapshotNav<Todo>? unfinishedNav,
  }) =>
      EveningShutdownState(
        currentStep: currentStep ?? this.currentStep,
        dispositions: dispositions ?? this.dispositions,
        unfinishedNav: unfinishedNav ?? this.unfinishedNav,
      );
}

final eveningShutdownProvider =
    NotifierProvider<EveningShutdownNotifier, EveningShutdownState>(
  EveningShutdownNotifier.new,
);

class EveningShutdownNotifier extends Notifier<EveningShutdownState> {
  bool _loadingUnfinishedSnapshot = false;

  @override
  EveningShutdownState build() {
    // Refresh notification-suppression flags when Drift receives cross-device
    // sync. Banner dismiss state is now persisted by the Nudge module (see
    // nudgeStateProvider).
    ref.listen(syncedPreferencesProvider, (_, next) {
      if (next is AsyncData<SyncedPreferences>) {
        final today = planningToday();
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

  // ---- Unfinished snapshot navigation ----------------------------------------

  /// Loads the unfinished-tasks snapshot once. Idempotent: subsequent calls
  /// are no-ops. Only includes tasks with doneAt == null.
  Future<void> loadUnfinishedSnapshot() async {
    if (state.unfinishedNav.isLoaded || _loadingUnfinishedSnapshot) return;
    _loadingUnfinishedSnapshot = true;
    try {
      final allTasks =
          await _db.focusSessionDao.watchActiveSessionTasks().first;
      final unfinished = allTasks.where((t) => t.doneAt == null).toList();
      state = state.copyWith(
        unfinishedNav: state.unfinishedNav.withItems(unfinished),
      );
    } finally {
      _loadingUnfinishedSnapshot = false;
    }
  }

  /// Advances the cursor by one. When all items have been resolved (new index
  /// reaches or exceeds snapshot length), calls [advanceStep] instead so the
  /// ritual proceeds automatically.
  void nextUnfinishedTask() {
    if (!state.unfinishedNav.isLoaded) return;
    final advanced = state.unfinishedNav.next();
    if (advanced.index >= state.unfinishedNav.length) {
      advanceStep();
    } else {
      state = state.copyWith(unfinishedNav: advanced);
    }
  }

  /// Pure navigation: decrements the cursor (clamped to 0). The in-memory
  /// disposition is preserved so the previously-tapped action can render its
  /// visual affordance on revisit. Re-tapping a disposition replaces the
  /// prior one; that is what removes the previous selection.
  void previousUnfinishedTask() {
    if (state.unfinishedNav.index == 0 || !state.unfinishedNav.isLoaded) return;
    state = state.copyWith(unfinishedNav: state.unfinishedNav.previous());
  }

  // ---- Task disposition (in-memory) ------------------------------------------

  /// Marks [id] for rollover into tomorrow's session and advances the index.
  void rolloverTask(String id) {
    _setDisposition(id, _kDispRollover);
    nextUnfinishedTask();
  }

  /// Marks [id] to remain in next-actions and advances the index.
  void returnToNext(String id) {
    _setDisposition(id, _kDispLeave);
    nextUnfinishedTask();
  }

  /// Marks [id] to defer to Someday/Maybe and advances the index.
  void deferTask(String id) {
    _setDisposition(id, _kDispMaybe);
    nextUnfinishedTask();
  }

  void _setDisposition(String id, String disposition) {
    state = state.copyWith(
      dispositions: {...state.dispositions, id: disposition},
    );
  }

  // ---- Notification skip / snooze --------------------------------------------

  Future<void> skipShutdownToday() async {
    await persistShutdownSkipToday(ref: ref);
    // Skip today only — leave tomorrow's recurring reminder intact.
    await NotificationService.instance
        .skipTodayRitualReminder(RitualId.eveningShutdown);
  }

  Future<void> snoozeShutdownNotification(int minutes) async {
    final until = DateTime.now().add(Duration(minutes: minutes));
    await persistShutdownSnoozedUntil(until, ref: ref);
    await NotificationService.instance
        .snoozeRitualReminder(RitualId.eveningShutdown, minutes);
  }

  // ---- Shutdown lifecycle ----------------------------------------------------

  /// Atomically commits accumulated dispositions and closes the active focus
  /// session. The Nudge module's ES Cadence Trigger predicate is gated on
  /// "active session exists" — closing the session makes the ES Nudge stand
  /// down without any explicit completion flag.
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
      await syncedPrefs(ref).set(_kShutdownCompletedDateKey, today);
      state = const EveningShutdownState();
    } catch (e) {
      await prefs.remove(_kShutdownCompletedDateKey);
      rethrow;
    }
  }
}
