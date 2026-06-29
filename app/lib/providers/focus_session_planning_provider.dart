/// Providers and state management for the focus session planning ritual (Issue #82).
///
/// Architecture:
/// - [focusSessionPlanningCompletionNotifier] — a [ValueNotifier] read by
///   [FocusScreen] to gate the "Begin Evening Shutdown" entry on the
///   home schedule once today's planning has been completed.
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

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/gtd_database.dart';
import '../models/ritual.dart';
import '../models/todo.dart' show RoutingKind;
import '../services/notification_service.dart';
import '../utils/snapshot_nav.dart';
import 'auth_provider.dart';
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

/// Total number of planning ritual steps (0-indexed max).
const int _maxStepIndex = 5;

// ---------------------------------------------------------------------------
// Router refresh notifier
// ---------------------------------------------------------------------------

/// Tracks whether the focus session planning ritual has been completed today.
///
/// Read by [FocusScreen] to gate the "Begin Evening Shutdown" entry on the
/// home schedule. In-memory only — [startDay] sets it true; cold start
/// resets it to false (the banner's own visibility is now driven by the
/// Nudge module's persisted dismiss state and the active-session
/// world-state precondition on the Daily Planning Cadence Trigger).
final focusSessionPlanningCompletionNotifier = ValueNotifier<bool>(false);

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
/// re-evaluates the visible Pending Review list with no imperative state
/// mutation in between.
///
/// A null day-energy (Energy step not yet visited) means no filtering at
/// all; tasks with no energy tag are never filtered out.
final nextActionsForFocusSessionPlanningProvider =
    StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final planningState = ref.watch(focusSessionPlanningProvider);
  final reviewed = {
    ...planningState.reviewedTaskIds,
    ...planningState.pendingSelectedTaskIds,
  };
  final dayEnergy = planningState.energyLevel;
  return db.todoDao.watchNextActions().map((all) => all
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
final skippedNextActionsForFocusSessionPlanningProvider =
    StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final planningState = ref.watch(focusSessionPlanningProvider);
  final skippedIds = planningState.reviewedTaskIds
      .where((id) => !planningState.pendingSelectedTaskIds.contains(id))
      .toList();
  return db.todoDao.watchTodosById(skippedIds);
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
    this.nextActionText,
    this.personTagIds = const {},
  });

  final ReviewActionKind kind;

  /// Recorded text when [kind] is [ReviewActionKind.updateNextAction].
  final String? nextActionText;

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
  });

  final int currentStep;
  final int availableMinutes;

  /// True once the user has explicitly set available time (not the default).
  final bool availableTimeSet;

  /// User's self-reported energy level for today: 'low' | 'medium' | 'high'.
  final String? energyLevel;

  /// Fixed snapshot of inbox item **IDs** loaded at the start of Step 0
  /// plus the current navigation cursor. items == null until loaded;
  /// ordered oldest-first (FIFO).
  ///
  /// Storing only IDs (not full [Todo] rows) keeps the snapshot's role
  /// narrow — it pins the order the user is walking through, while the
  /// authoritative attributes are read live from Drift via
  /// [taskDetailTodoProvider]. Edits autosave on change, so there is no
  /// "draft vs. snapshot vs. DB" divergence to reconcile.
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
  /// Loaded once when Step 1 is entered; the DB is never queried for "next".
  /// items == null until step 1 is entered; an empty list short-circuits the
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
      );
}

final focusSessionPlanningProvider =
    NotifierProvider<FocusSessionPlanningNotifier, FocusSessionPlanningState>(
  FocusSessionPlanningNotifier.new,
);

class FocusSessionPlanningNotifier extends Notifier<FocusSessionPlanningState> {
  bool _loadingInboxSnapshot = false;

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
    Future.microtask(_preloadRolloverIds);
    return const FocusSessionPlanningState();
  }

  GtdDatabase get _db => ref.read(databaseProvider);
  String get _userId => ref.read(currentUserIdProvider);

  /// Pre-populates [pendingSelectedTaskIds] with rollover tasks from the most
  /// recently closed session so they appear pre-selected in the plan summary.
  Future<void> _preloadRolloverIds() async {
    final ids = await _db.focusSessionDao
        .getLastClosedSessionRolloverTaskIds();
    if (ids.isEmpty) return;
    final current = Set.of(state.pendingSelectedTaskIds);
    final newIds = ids.where((id) => !current.contains(id)).toList();
    if (newIds.isNotEmpty) {
      state = state.copyWith(
        pendingSelectedTaskIds: [
          ...newIds,
          ...state.pendingSelectedTaskIds,
        ],
      );
    }
  }

  // ---- Step navigation -------------------------------------------------------

  Future<void> advanceStep() async {
    int next = state.currentStep + 1;
    if (next == 1) {
      // Load the review snapshot. Skip step 1 entirely if nothing needs review.
      final items = await _db.todoDao.getNeedsReview();
      if (!ref.mounted) return;
      if (items.isEmpty) {
        next = 2;
      } else {
        // Batched person-tag lookup so the stale waiting-for card variant
        // can render delegate names without a per-frame DAO call.
        final personTags = await _db.todoDao.getPersonTagsForTodos(
          items.map((t) => t.id).toSet(),
        );
        if (!ref.mounted) return;
        state = state.copyWith(
          reviewNav: SnapshotNav<Todo>(items: items),
          reviewActions: {},
          reviewPersonTags: personTags,
        );
      }
    }
    state = state.copyWith(currentStep: next.clamp(0, _maxStepIndex));
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

  // ---- Inbox clarification (Step 0) — snapshot navigation -------------------

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
      final items = await _db.inboxDao.watchInbox().first;
      state = state.copyWith(
        inboxNav: state.inboxNav
            .withItems(items.reversed.map((t) => t.id).toList()),
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

  /// Applies a routing transition to the snapshot row at [idx], delegating
  /// the DB matrix to [TodoDao.applyRouting]. Records [kind] in
  /// [inboxRoutings] and advances the cursor.
  ///
  /// Bails out without mutating state if the snapshot row no longer exists
  /// in the DB (deleted between snapshot load and apply). Idempotent under
  /// rapid re-taps: the cursor advance check at the end discards a second
  /// call's state mutation when the first call has already advanced.
  ///
  /// Note: PowerSync exposes [todos] as a SQLite VIEW backed by an
  /// INSTEAD OF trigger, so Drift's "affected rows" return value is always
  /// 0 even on a successful update. We pre-check for row existence via
  /// [TodoDao.getTodo] and otherwise trust the snapshot's claim that the
  /// row exists.
  Future<void> _routeInboxItem(
    String id, {
    required RoutingKind to,
    String? nextActionText,
  }) async {
    final idx = state.inboxNav.index;
    final exists = await _db.todoDao.getTodo(id);
    if (exists == null) return;
    await _db.todoDao.applyRouting(
      id,
      to: to,
      nextActionText: nextActionText,
      userId: _userId,
    );
    if (state.inboxNav.index != idx) return;
    state = state.copyWith(
      inboxRoutings: {
        ...state.inboxRoutings,
        idx: to,
      },
    );
    nextInboxItem();
  }

  /// Persists attribute edits on a todo. Used by the inbox clarify card to
  /// autosave Title/Notes/Energy/Time/Due as the user types or taps —
  /// attribute persistence is decoupled from any Process-to routing
  /// decision, so edits survive Skip / Back even without a routing call.
  Future<void> updateInboxItemFields(
    String id, {
    String? title,
    String? notes,
    String? energyLevel,
    int? timeEstimate,
    DateTime? dueDate,
    bool clearEnergyLevel = false,
    bool clearTimeEstimate = false,
    bool clearDueDate = false,
  }) =>
      _db.todoDao.updateFields(
        id,
        title: title,
        notes: notes,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
        dueDate: dueDate,
        clearEnergyLevel: clearEnergyLevel,
        clearTimeEstimate: clearTimeEstimate,
        clearDueDate: clearDueDate,
      );

  /// Routes the current inbox item to Next Actions and records [title] as
  /// the task's next-action text.
  ///
  /// Setting `next_action_text` prevents the task from immediately surfacing
  /// as Actionless in the re-clarification surface after inbox-clarify.
  Future<void> processInboxItem(String id, {required String title}) =>
      _routeInboxItem(id, to: RoutingKind.nextAction, nextActionText: title);

  /// Routes the current inbox item to Waiting For. Person-tag assignment is
  /// performed externally (by the picker) before this is invoked.
  Future<void> processInboxItemToWaitingFor(String id,
          {required String title}) =>
      _routeInboxItem(id, to: RoutingKind.waitingFor, nextActionText: title);

  /// Routes the current inbox item to Someday/Maybe.
  Future<void> processInboxItemToMaybe(String id) =>
      _routeInboxItem(id, to: RoutingKind.maybe);

  /// Routes the current inbox item to Trash. Soft-delete: the row remains in
  /// the DB so the user can re-route on Back.
  Future<void> processInboxItemToTrash(String id) =>
      _routeInboxItem(id, to: RoutingKind.trash);

  /// Routes the current inbox item to Done.
  Future<void> processInboxItemToDone(String id) =>
      _routeInboxItem(id, to: RoutingKind.done);

  /// Returns the IDs of person-typed tags currently assigned to [todoId].
  /// Used to pre-seed the Waiting For person picker on revisit.
  Future<Set<String>> getPersonTagIds(String todoId) =>
      _db.todoDao.getPersonTagIdsForTodo(todoId);

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

  Future<void> deferTask(String id) => _db.todoDao.deferTaskToMaybe(id);

  // ---- Task mutations (Step 3 — Scheduled review) ----------------------------

  /// Adds [id] to the pending day's plan (same as [selectTask]).
  void confirmScheduledTask(String id) => selectTask(id);

  Future<void> rescheduleTask(String id, DateTime newDate) =>
      _db.todoDao.rescheduleTask(id, newDate);

  // ---- Task mutations (Step 4 — Time Estimates) ------------------------------

  Future<void> setTimeEstimate(String id, int minutes) =>
      _db.todoDao.updateFields(id, timeEstimate: minutes);

  // ---- Task Review (Step 1) --------------------------------------------------

  /// "Still relevant" — only available for Stale tasks. Routes through
  /// [TodoDao.applyRouting] so a prior in-session resolution (markDone /
  /// sendToSomeday / trash) is undone in the same write that stamps
  /// `last_clarified_at`.
  Future<void> confirmReviewItemRelevant(String id) async {
    final idx = state.reviewNav.index;
    await _db.todoDao.applyRouting(
      id,
      to: RoutingKind.nextAction,
      userId: _userId,
    );
    if (state.reviewNav.index != idx) return;
    _recordAndAdvance(
      const ReviewActionRecord(kind: ReviewActionKind.stillRelevant),
    );
  }

  /// "Waiting for…" — called after [PersonTagPickerSheet] assigns a person
  /// tag. Routing is intent-only; `next_action_text` is on an orthogonal
  /// axis and is not touched here. The (now-removed) "Waiting for…"
  /// placeholder for actionless tasks belonged to the user-action axis,
  /// not the routing axis — the next-action dialog is the user-facing
  /// path for setting the phrase.
  Future<void> markReviewItemWaitingFor(String id) async {
    final idx = state.reviewNav.index;
    await _db.todoDao.applyRouting(
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

  /// "Update next action" — sets next_action_text and stamps last_clarified_at.
  /// Blank text normalises the column to NULL; the task stays Actionless and
  /// the cursor does not advance.
  Future<void> updateReviewItemNextAction(String id, String text) async {
    final idx = state.reviewNav.index;
    final trimmed = text.trim();
    await _db.todoDao.applyRouting(
      id,
      to: RoutingKind.nextAction,
      nextActionText: text,
      userId: _userId,
    );
    if (state.reviewNav.index != idx) return;
    if (trimmed.isNotEmpty) {
      _recordAndAdvance(ReviewActionRecord(
        kind: ReviewActionKind.updateNextAction,
        nextActionText: trimmed,
      ));
    } else {
      // Blank text normalises to NULL and the cursor does not advance, but
      // any stale action record must be cleared so the dialog does not
      // pre-fill with the old text when the user navigates back.
      if (state.reviewActions.containsKey(idx)) {
        state = state.copyWith(
          reviewActions: Map.of(state.reviewActions)..remove(idx),
        );
      }
    }
  }

  /// "Mark done" — sets done_at and stamps last_clarified_at.
  Future<void> markReviewItemDone(String id) async {
    final idx = state.reviewNav.index;
    await _db.todoDao.applyRouting(
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
    await _db.todoDao.applyRouting(
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
    await _db.todoDao.applyRouting(
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

  /// Removes the action record at the current review index without
  /// advancing the cursor. Used when the user saves a blank
  /// `next_action_text` via the [nextActionDialog] modifier — the task
  /// stays Actionless and the cursor does not move.
  void clearCurrentReviewAction() {
    final index = state.reviewNav.index;
    if (!state.reviewActions.containsKey(index)) return;
    state = state.copyWith(
      reviewActions: Map.of(state.reviewActions)..remove(index),
    );
  }

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
  /// Energy level and available time are preserved. Inbox snapshot resets so
  /// it is re-loaded fresh on the next visit to Step 0.
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
