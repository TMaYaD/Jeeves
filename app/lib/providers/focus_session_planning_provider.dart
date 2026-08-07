/// Providers and state management for the focus session planning ritual (Issue #82).
///
/// Architecture:
/// - The Now screen derives "planning done" from persistent session data (an
///   open [FocusSession] exists via [activeSessionProvider]), not an in-memory
///   flag — so it survives process death (issue #460, ADR-0020).
/// - [FocusSessionPlanningNotifier] — manages step navigation and task selection
///   state; delegates database writes to [FocusSessionDao] and [TodoDao].
/// - Task selection during the ritual is accumulated in-memory
///   ([pendingSelectedTaskIds] / [reviewedTaskIds]); [startDay] commits them
///   atomically by calling [FocusSessionDao.openSession].
/// - Inbox clarification and task review both use a [SnapshotNav]: a fixed
///   list loaded once at step start, navigated by an integer index. Routing
///   and action records are tracked separately in [inboxRoutings] /
///   [reviewActions], keyed by snapshot index.
/// - Stream providers expose live lists of tasks for each ritual step.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/gtd_database.dart';
import '../models/action_draft.dart';
import '../models/ritual.dart';
import '../models/todo.dart' show RoutingKind;
import '../services/clarification_service.dart';
import '../services/notification_service.dart';
import '../utils/snapshot_nav.dart';
import 'auth_provider.dart';
import 'clarify_retention_provider.dart';
import 'database_provider.dart';
import 'synced_preferences_provider.dart';

export '../database/gtd_database.dart' show Todo, FocusSession, Tag;

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

const _kNotificationSkippedDateKey = 'planning_notification_skipped_date';
const _kNotificationSnoozedUntilKey = 'planning_notification_snoozed_until';

/// Highest 0-indexed step the planning ritual reaches. Step 0 is the
/// duration-estimate intro (#486), steps 1–5 are the working steps (Clarify
/// Inbox, Review Tasks, Energy, Time, Plan Summary), step 6 is the Today's
/// Schedule completion screen (rendered outside the wizard).
const int _maxStepIndex = 6;

// ---------------------------------------------------------------------------
// Sequenced Shutdown → Daily Planning intent (issue #460, ADR-0020, ruling 4)
// ---------------------------------------------------------------------------

/// Carries the *and-then-plan* intent through the blocked-start sequenced
/// entry. Set true by the Daily Planning blocked-start interstitial before it
/// routes the user to Evening Shutdown; read and cleared by the Close Day
/// step, which — instead of exiting the app — routes into Daily Planning once
/// the session has been reviewed and closed.
///
/// This is a user-initiated action spread across two ceremonies, not a
/// route-level auto-launch (REQUIREMENTS.md § Ceremonies).
final shutdownThenPlanProvider =
    NotifierProvider<ShutdownThenPlanNotifier, bool>(
  ShutdownThenPlanNotifier.new,
);

class ShutdownThenPlanNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
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

/// Returns true iff the user has chosen "Skip today" (as distinct from an
/// active snooze). The reschedule logic uses this to suppress *today*'s
/// recurring fire while leaving tomorrow's intact — a snooze, by contrast,
/// is satisfied by its own one-off and does not need to touch the recurring
/// schedule.
bool isFocusSessionPlanningNotificationSkippedToday() =>
    _notificationSkippedToday;

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
///
/// Dual-writes to SharedPreferences (for cold-start startup reads) and to the
/// synced preferences store (for cross-device visibility).
Future<void> persistFocusSessionPlanningSkipToday({Ref? ref}) async {
  final today = planningToday();
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kNotificationSkippedDateKey, today);
  _notificationSkippedToday = true;
  if (ref != null) {
    await syncedPrefs(ref).set(_kNotificationSkippedDateKey, today);
  }
}

/// Persists and activates a snooze until [until].
///
/// Dual-writes to SharedPreferences (for cold-start startup reads) and to the
/// synced preferences store (for cross-device visibility).
Future<void> persistFocusSessionPlanningSnoozedUntil(DateTime until, {Ref? ref}) async {
  final value = until.toIso8601String();
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kNotificationSnoozedUntilKey, value);
  _notificationSnoozedActive = DateTime.now().isBefore(until);
  if (ref != null) {
    await syncedPrefs(ref).set(_kNotificationSnoozedUntilKey, value);
  }
}

// ---------------------------------------------------------------------------
// Session providers
// ---------------------------------------------------------------------------

/// Stream of the user's currently open [FocusSession], or null.
final activeSessionProvider = StreamProvider<FocusSession?>((ref) {
  final db = ref.watch(databaseProvider);
  return db.focusSessionDao.watchActiveSession();
});

/// Stream of [Todo] rows that are part of the user's active session, ordered
/// by their session position.
final activeSessionTasksProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.focusSessionDao.watchActiveSessionTasks();
});

/// True iff the user is in an open [FocusSession] that carries at least one
/// task — the exact condition the Now screen calls `showShutdownEntry`
/// (`planningDone && sortedTasks.isNotEmpty`). It gates both the Now screen's
/// shutdown callout and its shared-title-bar Re-plan page action, so deriving
/// them from one provider keeps the two from drifting (issue #499).
///
/// `.value` (not `.asData?.value`) retains the last-rendered value across a
/// transient loading/error state, so the derived bar action doesn't flicker
/// away during a brief re-subscription — the same idiom the Inbox badge uses.
final hasOpenSessionWithTasksProvider = Provider<bool>((ref) {
  final session = ref.watch(activeSessionProvider).value;
  final tasks =
      ref.watch(activeSessionTasksProvider).value ?? const <Todo>[];
  return session != null && tasks.isNotEmpty;
});

/// Stream of the tasks carried over ('rollover' disposition) from the most
/// recently closed session. Drives the Now screen's "Carried over from last
/// session" section, shown only while no session is open (issue #460).
final lastClosedSessionRolloverTasksProvider =
    StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.focusSessionDao.watchLastClosedSessionRolloverTasks();
});

// ---------------------------------------------------------------------------
// Stream providers — planning data
// ---------------------------------------------------------------------------

/// Energy-level ordering: 'low' < 'medium' < 'high'. Tasks tagged at or
/// below the day's energy level fit today; tasks above it do not. Unknown
/// strings (incl. null on the task side) are treated as "no constraint" —
/// the task always fits, and a null day-energy means no filtering at all.
const _kEnergyOrder = {'low': 1, 'medium': 2, 'high': 3};

/// True when [taskEnergy] is at or below [dayEnergy]. Null day-energy or
/// null task-energy → true (no constraint). Unknown energy strings also
/// return true (no constraint) — unknown values should never hide tasks.
bool _energyFits(String? taskEnergy, String? dayEnergy) {
  if (dayEnergy == null) return true;
  if (taskEnergy == null) return true;
  final day = _kEnergyOrder[dayEnergy];
  if (day == null) return true;
  final task = _kEnergyOrder[taskEnergy];
  if (task == null) return true;
  return task <= day;
}

/// Next-action tasks not yet reviewed in today's planning session, filtered
/// down to the ones whose energy requirement fits the user's self-reported
/// day-energy. Reactive: changing [FocusSessionPlanningState.energyLevel]
/// re-evaluates the visible Up Next list with no imperative state
/// mutation in between.
///
/// A null day-energy (Energy step not yet visited) means no filtering at
/// all; tasks with no energy tag are never filtered out.
final nextForFocusSessionPlanningProvider =
    StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final planningState = ref.watch(focusSessionPlanningProvider);
  final reviewed = {
    ...planningState.reviewedTaskIds,
    ...planningState.pendingSelectedTaskIds,
  };
  final dayEnergy = planningState.energyLevel;
  return db.todoDao.watchNext().map((all) => all
      .where((t) =>
          !reviewed.contains(t.id) && _energyFits(t.energyLevel, dayEnergy))
      .toList());
});

/// Tasks selected for today (in-memory pending list, ordered by selection).
final focusSessionPlanningSelectedTasksProvider =
    StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final ids = ref.watch(
    focusSessionPlanningProvider.select((s) => s.pendingSelectedTaskIds),
  );
  return db.todoDao.watchTodosById(ids).map((tasks) {
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
  final ids = ref.watch(
    focusSessionPlanningProvider.select((s) => s.pendingSelectedTaskIds),
  );
  return db.todoDao.watchTodosById(ids).map(
        (tasks) => tasks.where((t) => t.timeEstimate == null).toList(),
      );
});

/// Tasks reviewed today but not selected (skipped / deferred).
final skippedNextForFocusSessionPlanningProvider =
    StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final planningState = ref.watch(focusSessionPlanningProvider);
  final skippedIds = planningState.reviewedTaskIds
      .where((id) => !planningState.pendingSelectedTaskIds.contains(id))
      .toList();
  return db.todoDao.watchTodosById(skippedIds);
});

/// Item counts feeding the Daily Planning duration-estimate intro (#486).
///
/// Count-only reads that touch no snapshot lifecycle — the inbox and review
/// snapshots keep loading lazily on their own step entry. Moving them here
/// would change semantics: items clarified in Clarify Inbox must not surface
/// in the Review Tasks snapshot, which is taken on entry into that step.
/// `autoDispose` gives run-to-run freshness — each fresh performance
/// recomputes from the current lists. The counts may drift slightly from the
/// snapshots taken later (an inbox item clarified in step 1 removes a
/// would-be review item); acceptable — the estimate is an approximation.
final focusSessionPlanningIntroCountsProvider =
    FutureProvider.autoDispose<({int inboxCount, int reviewCount})>(
        (ref) async {
  final db = ref.watch(databaseProvider);
  final inbox = await db.captureDao.watchInbox().first;
  final review = await db.todoDao.getNeedsReview();
  return (inboxCount: inbox.length, reviewCount: review.length);
});

// ---------------------------------------------------------------------------
// Review action tracking — used to show affordances when going back
// ---------------------------------------------------------------------------

enum ReviewActionKind {
  stillRelevant,
  updateNextAction,
  waitingFor,
  markDone,
  sendToSomeday,
  trash,
}

class ReviewActionRecord {
  const ReviewActionRecord({
    required this.kind,
    this.actionText,
    this.personTagIds = const {},
  });

  final ReviewActionKind kind;

  /// Recorded Action phrase when [kind] is
  /// [ReviewActionKind.updateNextAction].
  final String? actionText;

  /// Person tag IDs assigned when [kind] is [ReviewActionKind.waitingFor].
  final Set<String> personTagIds;
}

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
    this.inboxNav = const SnapshotNav<String>(),
    this.inboxRoutings = const {},
    this.pendingSelectedTaskIds = const [],
    this.reviewedTaskIds = const [],
    this.reviewNav = const SnapshotNav<Todo>(),
    this.reviewActions = const {},
    this.reviewPersonTags = const {},
    this.reviewActionTexts = const {},
  });

  final int currentStep;
  final int availableMinutes;

  /// True once the user has explicitly set available time (not the default).
  final bool availableTimeSet;

  /// User's self-reported energy level for today: 'low' | 'medium' | 'high'.
  final String? energyLevel;

  /// Fixed snapshot of inbox item **IDs** loaded at the start of Step 1
  /// plus the current navigation cursor. items == null until loaded;
  /// ordered oldest-first (FIFO).
  ///
  /// Storing only IDs (not full rows) keeps the snapshot's role narrow — it
  /// pins the order the user is walking through, while the authoritative
  /// attributes are read live from Drift by the clarify card's own subject
  /// binding (`captureProvider`).
  ///
  /// The in-progress clarify draft *is* a third state, and deliberately not
  /// this one's business: a Capture's title and notes are never written while
  /// it is being clarified (ADR-0023), so the typing lives only in the
  /// `ClarifyRetention` store until a verdict lands it on an Outcome. That
  /// store is keyed by Capture id and held outside planning state, so the
  /// snapshot still carries order and nothing else.
  final SnapshotNav<String> inboxNav;

  /// Maps [inboxNav.items] index → the [RoutingKind] last applied at that
  /// position. An absent key means the item at that index has not yet been
  /// processed. Mirrors [PeriodicReviewState.inboxRoutings] so both ceremonies
  /// use the same shape — no projection needed at the call site.
  final Map<int, RoutingKind> inboxRoutings;

  /// Task IDs the user has selected for today's plan (in selection order).
  /// Committed to the DB atomically when [FocusSessionPlanningNotifier.startDay]
  /// is called.
  final List<String> pendingSelectedTaskIds;

  /// Task IDs the user has reviewed but skipped (not selected).
  final List<String> reviewedTaskIds;

  /// Snapshot of tasks needing re-clarification plus the navigation cursor.
  /// Loaded once when Step 2 is entered; the DB is never queried for "next".
  /// items == null until step 2 is entered; an empty list short-circuits the
  /// step entirely.
  final SnapshotNav<Todo> reviewNav;

  /// Recorded action for each review index — used to show selection affordances
  /// when the user navigates back within the review step.
  final Map<int, ReviewActionRecord> reviewActions;

  /// Person-typed tags for each task in [reviewNav.items], keyed by task id.
  /// Loaded alongside the review snapshot so the card can render the delegate
  /// name(s) for the stale waiting-for variant without a per-frame DAO call.
  /// Tasks with no person tag are absent from the map.
  final Map<String, List<Tag>> reviewPersonTags;

  /// Current Action text for each task in [reviewNav.items], keyed by task id.
  /// Absent means the Outcome is Actionless — the state the review step's
  /// "No next action defined" hint names.
  ///
  /// Read from `actions` alongside the snapshot: the Action entity is the only
  /// next-action grain (ADR-0001 story 3).
  final Map<String, String> reviewActionTexts;

  FocusSessionPlanningState copyWith({
    int? currentStep,
    int? availableMinutes,
    bool? availableTimeSet,
    String? energyLevel,
    bool clearEnergyLevel = false,
    SnapshotNav<String>? inboxNav,
    Map<int, RoutingKind>? inboxRoutings,
    List<String>? pendingSelectedTaskIds,
    List<String>? reviewedTaskIds,
    SnapshotNav<Todo>? reviewNav,
    Map<int, ReviewActionRecord>? reviewActions,
    Map<String, List<Tag>>? reviewPersonTags,
    Map<String, String>? reviewActionTexts,
  }) =>
      FocusSessionPlanningState(
        currentStep: currentStep ?? this.currentStep,
        availableMinutes: availableMinutes ?? this.availableMinutes,
        availableTimeSet: availableTimeSet ?? this.availableTimeSet,
        energyLevel: clearEnergyLevel ? null : (energyLevel ?? this.energyLevel),
        inboxNav: inboxNav ?? this.inboxNav,
        inboxRoutings: inboxRoutings ?? this.inboxRoutings,
        pendingSelectedTaskIds:
            pendingSelectedTaskIds ?? this.pendingSelectedTaskIds,
        reviewedTaskIds: reviewedTaskIds ?? this.reviewedTaskIds,
        reviewNav: reviewNav ?? this.reviewNav,
        reviewActions: reviewActions ?? this.reviewActions,
        reviewPersonTags: reviewPersonTags ?? this.reviewPersonTags,
        reviewActionTexts: reviewActionTexts ?? this.reviewActionTexts,
      );
}

final focusSessionPlanningProvider =
    NotifierProvider<FocusSessionPlanningNotifier, FocusSessionPlanningState>(
  FocusSessionPlanningNotifier.new,
);

class FocusSessionPlanningNotifier extends Notifier<FocusSessionPlanningState> {
  bool _loadingInboxSnapshot = false;

  /// Re-entrancy guard for [advanceStep]. Held until the end of the current
  /// event-loop turn (mirroring PeriodicReviewNotifier's `_isTransitioning`
  /// discipline) so a rapid double-tap advances exactly one step, whether
  /// the branch awaits a snapshot load or is otherwise synchronous.
  bool _advancing = false;

  @override
  FocusSessionPlanningState build() {
    // Refresh notification-suppression flags when Drift receives cross-device
    // sync. Banner dismiss state is now persisted by the Nudge module (see
    // nudgeStateProvider) and no longer lives in a ValueNotifier here.
    ref.listen(syncedPreferencesProvider, (_, next) {
      if (next is AsyncData<SyncedPreferences>) {
        final today = planningToday();
        _notificationSkippedToday =
            next.value.get<String>(_kNotificationSkippedDateKey) == today;

        final snoozedUntil = DateTime.tryParse(
          next.value.get<String>(_kNotificationSnoozedUntilKey) ?? '',
        );
        _notificationSnoozedActive =
            snoozedUntil != null && DateTime.now().isBefore(snoozedUntil);
      }
    });
    Future.microtask(ensureRolloverPreload);
    return const FocusSessionPlanningState();
  }

  GtdDatabase get _db => ref.read(databaseProvider);
  ClarificationService get _clarification =>
      ref.read(clarificationServiceProvider);
  String get _userId => ref.read(currentUserIdProvider);

  /// (Re)computes rollover pre-selection from the most recently closed session
  /// and merges it into [pendingSelectedTaskIds] so carried-over tasks arrive
  /// pre-selected in the Plan Summary.
  ///
  /// Idempotent and safe to call on every planning entry: the notifier
  /// [build] microtask (cold start), [reEnterPlanning] (the sequenced
  /// Shutdown → Planning replan), and the planning screen mount (warm-process
  /// replan). A once-per-build preload missed every in-process replan path
  /// (#461); recomputing at each entry closes that gap.
  ///
  /// Skipped entirely while a session is open ([FocusSessionDao.getActiveSession]
  /// non-null): a mid-day cold start would otherwise read the *previous*
  /// period's rollover ids — already consumed by the open plan — into a fresh
  /// draft. The blocked-start interstitial owns that state (ADR-0020).
  ///
  /// Merge respects **both** lists: an id is added only when it is neither
  /// already pending nor in [reviewedTaskIds], so a task the user deliberately
  /// skipped or deselected is never resurrected by a repeated call. (An
  /// [undoTaskReview] clears a task from both lists by design, so a later call
  /// legitimately restores it as the rollover default — CONTEXT.md § Engagement.)
  ///
  /// Read-only over dispositions: no Disposition is minted here — carrying a
  /// task over stays a user decision (CONTEXT.md § Engagement, Disposition).
  Future<void> ensureRolloverPreload() async {
    if (await _db.focusSessionDao.getActiveSession() != null) return;
    if (!ref.mounted) return;
    final ids =
        await _db.focusSessionDao.getLastClosedSessionRolloverTaskIds();
    if (ids.isEmpty || !ref.mounted) return;
    final pending = Set.of(state.pendingSelectedTaskIds);
    final reviewed = Set.of(state.reviewedTaskIds);
    final newIds = ids
        .where((id) => !pending.contains(id) && !reviewed.contains(id))
        .toList();
    if (newIds.isEmpty) return;
    state = state.copyWith(
      pendingSelectedTaskIds: [
        ...newIds,
        ...state.pendingSelectedTaskIds,
      ],
    );
  }

  // ---- Step navigation -------------------------------------------------------

  Future<void> advanceStep() async {
    if (_advancing) return;
    _advancing = true;
    try {
      final next = state.currentStep + 1;
      if (next == 2) {
        // Crossing into Review Tasks (step 2 — step 1 is Clarify Inbox, step 0
        // the intro). Load the review snapshot on entry, never earlier: items
        // clarified during Clarify Inbox get a current Action and must not
        // surface here. The step always renders — an empty snapshot shows the
        // empty-state view and the user clicks Next to advance (CONTEXT.md
        // § Wizard: steps do not auto-skip).
        final items = await _db.todoDao.getNeedsReview();
        if (!ref.mounted) return;
        // Batched person-tag lookup so the stale waiting-for card variant
        // can render delegate names without a per-frame DAO call.
        final personTags = await _db.todoDao.getPersonTagsForTodos(
          items.map((t) => t.id).toSet(),
        );
        if (!ref.mounted) return;
        // Batched current-Action lookup, same discipline: one query for the
        // whole snapshot rather than a DAO call per rendered card.
        final actionTexts = await _db.actionDao.getCurrentActionTexts(
          items.map((t) => t.id).toSet(),
        );
        if (!ref.mounted) return;
        state = state.copyWith(
          reviewNav: SnapshotNav<Todo>(items: items),
          reviewActions: {},
          reviewPersonTags: personTags,
          reviewActionTexts: actionTexts,
        );
      }
      state = state.copyWith(currentStep: next.clamp(0, _maxStepIndex));
      // Hold the guard through the rest of the current event-loop turn so a
      // second call from the same tap burst is dropped even on the branch
      // with no snapshot load to await.
      await Future<void>.microtask(() {});
    } finally {
      _advancing = false;
    }
  }

  /// Steps back within the review step to the previous item.
  void reviewBack() {
    if (state.reviewNav.canGoBack) {
      state = state.copyWith(reviewNav: state.reviewNav.previous());
    }
  }

  /// Skips the current review item without writing anything to the DB.
  /// Called by the Next button while the review step still has pending items.
  void skipReviewItem() {
    if (!state.reviewNav.isComplete) {
      state = state.copyWith(reviewNav: state.reviewNav.next());
    }
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

  // ---- Inbox clarification (Step 1) — snapshot navigation -------------------

  /// Loads the inbox snapshot once. Idempotent: subsequent calls are no-ops.
  ///
  /// Matches Weekly Review's loader — the full inbox, unfiltered by the
  /// user's active context-tag filter. Daily Planning's purpose is the same
  /// as Weekly Review's at this step: clear every inbox item by giving it a
  /// disposition.
  Future<void> loadInboxSnapshot() async {
    if (state.inboxNav.isLoaded || _loadingInboxSnapshot) return;
    _loadingInboxSnapshot = true;
    try {
      // Captures with `clarified_at IS NULL` (ADR-0006) — the snapshot holds
      // Capture ids, and each one is clarified *into* a new Outcome.
      final items = await _db.captureDao.watchInbox().first;
      state = state.copyWith(
        inboxNav: state.inboxNav
            .withItems(items.reversed.map((c) => c.id).toList()),
      );
    } finally {
      _loadingInboxSnapshot = false;
    }
  }

  /// Advances the inbox cursor by one (no bounds check — callers must not call
  /// when already past the end).
  void nextInboxItem() =>
      state = state.copyWith(inboxNav: state.inboxNav.next());

  /// Pure navigation: decrements the inbox cursor (clamped to 0). The DB is
  /// not touched on Back — any prior routing remains applied so the
  /// "previously selected" affordance can render on revisit. Re-tapping a
  /// destination is what reverts the prior routing (handled inside each
  /// destination handler).
  void previousInboxItem() {
    if (state.inboxNav.index <= 0) return;
    state = state.copyWith(inboxNav: state.inboxNav.previous());
  }

  /// Advances the cursor without writing to the DB or recording a routing.
  void skipInboxItem() => nextInboxItem();

  /// State-only sibling to [_routeInboxItem]. Used by callsites where the
  /// DAO write has already happened inside the action widget
  /// ([ProcessToHandlers]) and only the in-session bookkeeping remains.
  void recordInboxRoutingAndAdvance(RoutingKind kind) {
    final idx = state.inboxNav.index;
    state = state.copyWith(
      inboxRoutings: {
        ...state.inboxRoutings,
        idx: kind,
      },
    );
    nextInboxItem();
  }

  /// Clarifies the snapshot Capture at [idx] with the verdict [to]. Records
  /// [kind] in [inboxRoutings] and advances the cursor.
  ///
  /// Every destination except Trash creates a **new** Outcome, links it back
  /// to the Capture as provenance and stamps `clarified_at` (ADR-0006). Trash
  /// is the zero-Outcome discard: it stamps and creates nothing, so a
  /// discarded Capture never appears on the Trash List. [title] defaults to the
  /// Capture's own title; its tag hints seed the new Outcome's tags.
  ///
  /// Bails out without mutating state if the snapshot row no longer exists
  /// in the DB (deleted between snapshot load and apply). Idempotent under
  /// rapid re-taps: the cursor advance check at the end discards a second
  /// call's state mutation when the first call has already advanced.
  ///
  /// Note: the routing write is a multi-statement transaction whose
  /// affected-rows count says nothing about the subject in particular, so we
  /// pre-check for row existence via [ClarificationService.captureExists] and
  /// otherwise trust the snapshot's claim that the row exists.
  Future<void> _routeInboxItem(
    String captureId, {
    required RoutingKind to,
    String? title,
    String? actionText,
    Set<String>? personTagIds,
  }) async {
    final idx = state.inboxNav.index;
    final capture = await _db.captureDao.getCapture(captureId);
    if (capture == null) return;
    if (to == RoutingKind.trash) {
      await _clarification.discardCapture(captureId);
    } else {
      await _clarification.clarifyCaptureToOutcome(
        captureId,
        to: to,
        userId: _userId,
        title: title ?? capture.title,
        notes: capture.notes,
        action: actionText == null ? null : ActionDraft(text: actionText),
        personTagIds: personTagIds,
        tagIds: await _db.captureDao.tagHintIdsForCapture(captureId),
      );
    }
    if (state.inboxNav.index != idx) return;
    state = state.copyWith(
      inboxRoutings: {
        ...state.inboxRoutings,
        idx: to,
      },
    );
    nextInboxItem();
  }

  /// Clarifies the current Capture into a Next Action, recording [title] as
  /// the new Outcome's next-action text.
  ///
  /// Giving the new Outcome a current Action prevents it from immediately
  /// surfacing as Actionless in the re-clarification surface after
  /// inbox-clarify.
  Future<void> processInboxItem(String id, {required String title}) =>
      _routeInboxItem(
        id,
        to: RoutingKind.nextAction,
        title: title,
        actionText: title,
      );

  /// Clarifies the current Capture into a delegated Outcome.
  ///
  /// [personTagIds] must carry the delegates the picker collected: the Outcome
  /// does not exist until this call, so there is no row for the picker to have
  /// assigned them to beforehand. Routing to Waiting For without them would
  /// create an Outcome that lands on Next and never surfaces on Waiting For.
  Future<void> processInboxItemToWaitingFor(
    String id, {
    required String title,
    required Set<String> personTagIds,
  }) =>
      _routeInboxItem(
        id,
        to: RoutingKind.waitingFor,
        title: title,
        actionText: title,
        personTagIds: personTagIds,
      );

  /// Clarifies the current Capture into a Someday/Maybe Outcome.
  Future<void> processInboxItemToMaybe(String id) =>
      _routeInboxItem(id, to: RoutingKind.maybe);

  /// Discards the current Capture — a zero-Outcome clarification (ADR-0006).
  /// Stamps `clarified_at` and creates nothing; the Capture itself is never
  /// deleted, so Back can still revisit it.
  Future<void> processInboxItemToTrash(String id) =>
      _routeInboxItem(id, to: RoutingKind.trash);

  /// Clarifies the current Capture into an already-achieved Outcome.
  Future<void> processInboxItemToDone(String id) =>
      _routeInboxItem(id, to: RoutingKind.done);

  /// Returns the IDs of person-typed tags currently assigned to [todoId].
  /// Used to pre-seed the Waiting For person picker on revisit.
  Future<Set<String>> getPersonTagIds(String todoId) =>
      _clarification.getPersonTagIds(todoId);

  // ---- Task mutations (Step 2 — Next Actions review) -------------------------

  /// Adds [ids] to the pending day's plan in a single state publish
  /// (in-memory; committed by [startDay]).
  ///
  /// Ids already selected — and any duplicates within [ids] — are skipped, so
  /// the pending list never gains a repeat. Each newly added id is removed from
  /// the reviewed/skipped list (picking up a task un-skips it). If nothing new
  /// is added the state is left untouched (no rebuild), preserving the
  /// early-return semantics [selectTask] relied on.
  void selectTasks(List<String> ids) {
    final existing = state.pendingSelectedTaskIds.toSet();
    final toAdd = <String>[];
    for (final id in ids) {
      // Set.add returns false when the id is already present, covering both
      // already-selected ids and repeats within [ids].
      if (existing.add(id)) toAdd.add(id);
    }
    if (toAdd.isEmpty) return;
    final addedSet = toAdd.toSet();
    state = state.copyWith(
      pendingSelectedTaskIds: [...state.pendingSelectedTaskIds, ...toAdd],
      // Remove any newly selected task from the skipped list.
      reviewedTaskIds:
          state.reviewedTaskIds.where((t) => !addedSet.contains(t)).toList(),
    );
  }

  /// Adds [id] to the pending day's plan (in-memory; committed by [startDay]).
  void selectTask(String id) => selectTasks([id]);

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

  Future<void> deferTask(String id) => _db.todoDao.deferTaskToMaybe(id);

  // ---- Task mutations (Step 3 — Scheduled review) ----------------------------

  /// Adds [id] to the pending day's plan (same as [selectTask]).
  void confirmScheduledTask(String id) => selectTask(id);

  Future<void> rescheduleTask(String id, DateTime newDate) =>
      _db.todoDao.rescheduleTask(id, newDate);

  // ---- Task mutations (Step 4 — Time Estimates) ------------------------------

  Future<void> setTimeEstimate(String id, int minutes) =>
      _db.todoDao.updateFields(id, timeEstimate: minutes);

  // ---- Task Review (Step 2) --------------------------------------------------

  /// "Still relevant" — only available for Stale tasks. Routes through
  /// [ClarificationService.clarifyToOutcome] so a prior in-session
  /// resolution (markDone / sendToSomeday / trash) is undone in the same
  /// write that stamps `last_clarified_at`.
  Future<void> confirmReviewItemRelevant(String id) async {
    final idx = state.reviewNav.index;
    await _clarification.clarifyToOutcome(
      id,
      to: RoutingKind.nextAction,
      userId: _userId,
    );
    if (state.reviewNav.index != idx) return;
    _recordAndAdvance(
      const ReviewActionRecord(kind: ReviewActionKind.stillRelevant),
    );
  }

  /// "Waiting for…" — a legacy bundled helper: it commits the route itself
  /// via [ClarificationService.clarifyToOutcome], then reads back whatever
  /// delegates are assigned to the Outcome and advances the cursor. Retained
  /// because the test suite drives it directly; widget-owned routing commits
  /// through `ProcessToHandlers` and reports via
  /// [recordReviewActionAndAdvance] instead.
  ///
  /// Routing is intent-only; the Outcome's current Action is on an orthogonal
  /// axis and is not touched here. The (now-removed) "Waiting for…"
  /// placeholder for actionless tasks belonged to the user-action axis,
  /// not the routing axis — the next-action dialog is the user-facing
  /// path for setting the phrase.
  Future<void> markReviewItemWaitingFor(String id) async {
    final idx = state.reviewNav.index;
    await _clarification.clarifyToOutcome(
      id,
      to: RoutingKind.waitingFor,
      userId: _userId,
    );
    if (state.reviewNav.index != idx) return;
    final tagIds = await _db.tagDao.getPersonTagIdsForTodo(id);
    if (state.reviewNav.index != idx) return;
    _recordAndAdvance(ReviewActionRecord(
      kind: ReviewActionKind.waitingFor,
      personTagIds: tagIds,
    ));
  }

  /// "Mark done" — sets done_at and stamps last_clarified_at.
  Future<void> markReviewItemDone(String id) async {
    final idx = state.reviewNav.index;
    await _clarification.clarifyToOutcome(
      id,
      to: RoutingKind.done,
      userId: _userId,
    );
    if (state.reviewNav.index != idx) return;
    _recordAndAdvance(const ReviewActionRecord(kind: ReviewActionKind.markDone));
  }

  /// "Send to Someday" — sets intent='maybe' and stamps last_clarified_at.
  Future<void> deferReviewItemToSomeday(String id) async {
    final idx = state.reviewNav.index;
    await _clarification.clarifyToOutcome(
      id,
      to: RoutingKind.maybe,
      userId: _userId,
    );
    if (state.reviewNav.index != idx) return;
    _recordAndAdvance(
      const ReviewActionRecord(kind: ReviewActionKind.sendToSomeday),
    );
  }

  /// "Trash" — sets intent='trash' and stamps last_clarified_at.
  Future<void> trashReviewItem(String id) async {
    final idx = state.reviewNav.index;
    await _clarification.clarifyToOutcome(
      id,
      to: RoutingKind.trash,
      userId: _userId,
    );
    if (state.reviewNav.index != idx) return;
    _recordAndAdvance(const ReviewActionRecord(kind: ReviewActionKind.trash));
  }

  void _recordAndAdvance(ReviewActionRecord record) {
    final index = state.reviewNav.index;
    state = state.copyWith(
      reviewNav: state.reviewNav.next(),
      reviewActions: {...state.reviewActions, index: record},
    );
  }

  /// State-only sibling to the [confirmReviewItemRelevant] /
  /// [markReviewItem*] family. Used by callsites where the DAO write has
  /// already happened inside the action widget ([ProcessToHandlers]) and
  /// only the in-session bookkeeping remains.
  void recordReviewActionAndAdvance(ReviewActionRecord record) =>
      _recordAndAdvance(record);

  // ---- Banner dismissal ------------------------------------------------------

  // ---- Notification skip / snooze --------------------------------------------

  /// Suppresses all planning nudges until the next calendar day and cancels
  /// any scheduled notification for today.
  Future<void> skipPlanningToday() async {
    await persistFocusSessionPlanningSkipToday(ref: ref);
    // Skip today only — leave tomorrow's recurring reminder intact.
    await NotificationService.instance
        .skipTodayRitualReminder(RitualId.dailyPlanning);
  }

  /// Snoozes the planning notification by [minutes] and reschedules it as a
  /// one-off fire.
  Future<void> snoozePlanningNotification(int minutes) async {
    final until = DateTime.now().add(Duration(minutes: minutes));
    await persistFocusSessionPlanningSnoozedUntil(until, ref: ref);
    await NotificationService.instance
        .snoozeRitualReminder(RitualId.dailyPlanning, minutes);
  }

  // ---- Ritual lifecycle ------------------------------------------------------

  /// Opens a new [FocusSession] with the pending task list.
  ///
  /// Guards the single-open-session invariant (ADR-0020): if a session is
  /// already open, the [FocusSessionDao.openSession] throw is the backstop —
  /// the UI gates on this by routing the user through Evening Shutdown first.
  /// On success, today's Daily Planning notification is now moot (a qualifying
  /// session exists), so its pending one-off fire is cancelled.
  Future<void> startDay() async {
    await _db.focusSessionDao.openSession(
      userId: _userId,
      taskIds: state.pendingSelectedTaskIds,
    );
    // A qualifying session now exists — today's DPR fire is moot. Best-effort.
    await ref
        .read(notificationServiceProvider)
        .skipTodayRitualReminder(RitualId.dailyPlanning);
    state = FocusSessionPlanningState(
      energyLevel: state.energyLevel,
      availableMinutes: state.availableMinutes,
      availableTimeSet: state.availableTimeSet,
    );
    // Retained clarify drafts belong to the performance that produced them,
    // the same as the inbox snapshot and its cursor above.
    ref.read(clarifyRetentionProvider).clearAll();
  }

  /// Resets the planning ritual to a fresh performance.
  ///
  /// Task selections are **cleared** so the user can re-plan from scratch.
  /// Energy level and available time are preserved. Inbox snapshot resets so
  /// it is re-loaded fresh on the next visit to Step 1. Called on the sequenced
  /// Shutdown → Planning path (a completed performance), not on a direct
  /// "Plan the Day" with no session (which resumes the in-memory draft as
  /// today — issue #180 behaviour preserved).
  Future<void> reEnterPlanning() async {
    final preservedEnergy = state.energyLevel;
    final preservedMinutes = state.availableMinutes;
    final preservedTimeSet = state.availableTimeSet;
    state = FocusSessionPlanningState(
      currentStep: 0,
      availableMinutes: preservedMinutes,
      availableTimeSet: preservedTimeSet,
      energyLevel: preservedEnergy,
    );
    // A fresh performance re-loads the inbox snapshot, so a draft left against
    // an item from the last one has nothing to come back to.
    ref.read(clarifyRetentionProvider).clearAll();
    // Re-populate the rollover pre-selection: build()'s microtask ran once per
    // process and never fires again on this in-process replan path (#461). The
    // just-closed session's rollover ids are now committed and queryable — the
    // caller (close_day_step) awaits this before routing to the planning
    // screen, so the carried-over tasks are pre-selected the moment it mounts.
    await ensureRolloverPreload();
  }
}
