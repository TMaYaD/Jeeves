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
/// - [sessionSettlementGroupsProvider], [unfinishedSelectedTodayProvider] —
///   stream providers driven by the active focus session's members.
/// - [loggedMinutesByOutcomeProvider] — the derived time-spent total the Review
///   steps render beside those Outcomes.
/// - [eveningShutdownProvider] — step / disposition state for the ritual.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/daos/focus_session_dao.dart' show SessionSettlement;
import '../database/gtd_database.dart';
import '../models/ritual.dart';
import '../services/notification_service.dart';
import '../utils/snapshot_nav.dart';
import 'database_provider.dart';
import 'focus_session_planning_provider.dart'
    show activeSessionSettlementsProvider, planningToday;
import 'synced_preferences_provider.dart';

// Re-export Todo so UI consumers (e.g. unfinished_tasks_step.dart) can use
// the type without taking a direct dependency on the database layer.
export '../database/gtd_database.dart' show Todo;
// Same reason: the summary step groups by Settlement and must not import the
// database layer to name the buckets.
export '../database/daos/focus_session_dao.dart' show SessionSettlement;

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

/// A stream that never emits and never closes, so a [StreamProvider] returning
/// it stays in its loading state instead of publishing a value it does not
/// have yet. The subscription is discarded when the dependency being waited on
/// arrives and the provider rebuilds.
///
/// Both stream providers below need it for the same reason: an empty
/// Settlement map is indistinguishable from "nothing Settled", so a loading map
/// defaulted to empty is not a neutral placeholder — it is a wrong answer
/// wearing the shape of a right one.
Stream<T> _holdInLoading<T>() => StreamController<T>().stream;

/// The order the summary renders Settlement groups in: achieved, then
/// continuing, then blocked on someone else, then parked.
///
/// It also puts the one group with a downstream consequence directly under
/// Done — `next` is what [EveningShutdownNotifier.closeDay] carries over.
const sessionSettlementRenderOrder = <SessionSettlement>[
  SessionSettlement.done,
  SessionSettlement.next,
  SessionSettlement.waitingFor,
  SessionSettlement.someday,
];

/// The day's **Settled** Outcomes, grouped by how each settled, in
/// [sessionSettlementRenderOrder]. Empty groups are absent from the map
/// (#694 AC6), and Dart's insertion-ordered map is what carries the order.
///
/// Reads the union surface, not Plan members only, so an off-Plan Outcome the
/// user resolved during the session still appears (CONTEXT.md § Engagement).
///
/// The grouping is by **where the Outcome stands now**, not by the verdict
/// keystroke — nothing records the keystroke. Move an item from Someday back to
/// Next later the same day and it changes group; the summary is the day's end
/// state, which is the right reading (ADR-0048).
final sessionSettlementGroupsProvider =
    StreamProvider<Map<SessionSettlement, List<Todo>>>((ref) {
  final db = ref.watch(databaseProvider);
  final surfaceStream = db.focusSessionDao.watchActiveSessionReviewSurface();
  final settlementsAsync = ref.watch(activeSessionSettlementsProvider);
  if (settlementsAsync.hasError) {
    return Stream.error(settlementsAsync.error!, settlementsAsync.stackTrace);
  }
  // The two streams emit independently, so defaulting a not-yet-emitted map to
  // empty publishes a first AsyncData claiming the day resolved nothing —
  // which the summary step renders as its empty state.
  final settlements = settlementsAsync.value;
  if (settlements == null) return _holdInLoading();
  return surfaceStream.map((surface) {
    final groups = <SessionSettlement, List<Todo>>{};
    for (final bucket in sessionSettlementRenderOrder) {
      final members =
          surface.where((t) => settlements[t.id] == bucket).toList();
      if (members.isNotEmpty) groups[bucket] = members;
    }
    return groups;
  });
});

/// Minutes logged per Outcome, keyed by Outcome id — the derived time-spent
/// total both Review steps render (issue #604).
///
/// Nothing stores a time-spent total; it is summed from `time_logs` on every
/// read, so this is a stream rather than a field on the Outcome rows the two
/// providers above emit. One watcher serves the whole step: the Completed
/// Review needs a per-card figure *and* a fold across the completed set, and a
/// read per card would settle a frame late in the summary bar.
///
/// An Outcome with no stints is **absent from the map**, not zero — read it as
/// `map[id] ?? 0`.
final loggedMinutesByOutcomeProvider = StreamProvider<Map<String, int>>((ref) {
  return ref.watch(databaseProvider).timeLogDao.watchTotalMinutesByTask();
});

/// Outcomes on the active session's Review surface (Plan ∪ off-Plan engaged)
/// with **no resolution yet**: not Settled during the session, and no
/// shutdown disposition recorded in the current ritual.
///
/// The disposition map is the in-memory state on [eveningShutdownProvider]; it
/// only persists to the DB when [EveningShutdownNotifier.closeDay] is called.
/// Filtering here gives the live "remaining tasks" count used by the banner
/// and other consumers outside the ritual step itself. Reading the union
/// surface ensures off-Plan engaged Outcomes are surfaced for disposition too.
///
/// The Settlement exclusion is #694 AC4: an item the user already resolved in
/// the session must not be asked about again. The `doneAt == null` clause is
/// now implied by it (a completed Outcome settles as `done`) and stays only as
/// the cheap guard.
final unfinishedSelectedTodayProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final dispositions = ref.watch(
    eveningShutdownProvider.select((s) => s.dispositions),
  );
  final surfaceStream = db.focusSessionDao.watchActiveSessionReviewSurface();
  final settlementsAsync = ref.watch(activeSessionSettlementsProvider);
  if (settlementsAsync.hasError) {
    return Stream.error(settlementsAsync.error!, settlementsAsync.stackTrace);
  }
  // Same gate as [sessionSettlementGroupsProvider]: a not-yet-emitted map
  // defaulted to empty would count every Settled Outcome as unfinished work on
  // the first emission — the banner's count and the ritual header's
  // "remaining" figure.
  final settlements = settlementsAsync.value;
  if (settlements == null) return _holdInLoading();
  return surfaceStream.map(
        (tasks) => tasks
            .where((t) =>
                t.doneAt == null &&
                !settlements.containsKey(t.id) &&
                !dispositions.containsKey(t.id))
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
  /// are no-ops. Only includes Outcomes with **no resolution yet** — not
  /// completed, and not Settled during the session.
  ///
  /// The step iterates this frozen snapshot, not the stream, so this is the
  /// exclusion that decides what the user is actually asked about (#694 AC4).
  /// Settlements come from the one-shot read: awaiting a live Drift
  /// `watch().first` from a widget-driven path never returns
  /// (docs/TESTING.md § Frontend).
  Future<void> loadUnfinishedSnapshot() async {
    if (state.unfinishedNav.isLoaded || _loadingUnfinishedSnapshot) return;
    _loadingUnfinishedSnapshot = true;
    try {
      final allTasks =
          await _db.focusSessionDao.watchActiveSessionReviewSurface().first;
      final settlements =
          await _db.focusSessionDao.getActiveSessionSettlements();
      final unfinished = allTasks
          .where((t) => t.doneAt == null && !settlements.containsKey(t.id))
          .toList();
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

  /// The Dispositions implied by [settlements] — for the Outcomes the user
  /// therefore never saw in the disposition step.
  ///
  /// * `next` → `rollover`: "more work later" is precisely the item the user
  ///   expects to find waiting tomorrow.
  /// * `waitingFor` / `someday` → `leave`: neither rolls over, and `leave` is
  ///   "return to its normal List membership; no special handling", which is
  ///   exactly what those verdicts already accomplished. Writing *nothing*
  ///   would drop a record that exists today — every non-completed Review-surface
  ///   Outcome takes a Disposition (CONTEXT.md § Disposition). Not `maybe` for
  ///   `someday`: the verdict already set `intent='maybe'`, and a `maybe`
  ///   Disposition would make `reviewAndCloseSession` re-stamp
  ///   `last_clarified_at` at close time, dragging it off the moment the user
  ///   actually decided.
  /// * `done` → **none**, and this exclusion is load-bearing rather than tidy:
  ///   `reviewAndCloseSession` does not filter completed Outcomes itself — its
  ///   doc comment puts that on the caller — so including them here would write
  ///   Disposition rows for achieved work and contradict CONTEXT.md's
  ///   "Completed Outcomes need no Disposition".
  static Map<String, String> _impliedDispositions(
    Map<String, SessionSettlement> settlements,
  ) =>
      {
        for (final entry in settlements.entries)
          if (entry.value != SessionSettlement.done)
            entry.key: entry.value == SessionSettlement.next
                ? _kDispRollover
                : _kDispLeave,
      };

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
  ///
  /// **Settled Outcomes take an implicit Disposition here.** They never reach
  /// the disposition step (they were resolved in-session), so without this they
  /// would leave Review with no Disposition at all — and a `next`-Settled item,
  /// the one the user said "more work later" about, would silently vanish from
  /// the Now screen's carried-over section and from tomorrow's pre-selection.
  /// The mapping: `next → rollover`, `waitingFor | someday → leave`,
  /// `done → none`. See [_impliedDispositions].
  ///
  /// This is the commit point because [FocusSessionDao.reviewAndCloseSession] is
  /// the only writer that routes a Disposition to its correct home
  /// — a Settled Outcome may be off-Plan, and `setTaskDisposition` throws for
  /// exactly that case. Seeding earlier would not work either: the step's own
  /// loader never runs on a day where *everything* settled, because the wizard
  /// auto-advances past an empty step 1.
  Future<void> closeDay({DateTime? now}) async {
    final session = await _db.focusSessionDao.getActiveSession();
    if (session != null) {
      // Derived fresh from the live store at commit time and never stored, so
      // re-entering an abandoned ritual accumulates nothing and an item that
      // settled while ES was backgrounded is still caught.
      //
      // Scoped to the session this call already selected, not to "whatever is
      // active now": two open sessions is a reachable sync state (ADR-0020) and
      // the winner can change between these two awaits. Re-resolving here would
      // let the map be derived from one session and committed against another —
      // dropping a `next`-Settled Outcome's `rollover` and offering the closing
      // session Dispositions belonging to its rival.
      final implied = _impliedDispositions(
        await _db.focusSessionDao.getSettlementsForSession(session.id),
      );
      await _db.focusSessionDao.reviewAndCloseSession(
        sessionId: session.id,
        // Explicit last: a Disposition the user actually tapped always wins
        // over a derived one, never the reverse.
        dispositions: {...implied, ...state.dispositions},
        now: now,
      );
      // No open session remains — today's Evening Shutdown fire is moot.
      // Best-effort reconciliation of the OS-scheduled notification: a
      // platform failure here must never abort the shutdown, which has
      // already closed the session. Swallow so the completion-state update
      // below still runs (ADR-0020).
      try {
        await ref
            .read(notificationServiceProvider)
            .skipTodayRitualReminder(RitualId.eveningShutdown);
      } catch (_) {
        // Best-effort OS notification reconciliation must not fail shutdown.
      }
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
