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
import '../models/todo.dart' show Intent;
import '../services/notification_service.dart';
import '../utils/snapshot_nav.dart';
import 'auth_provider.dart';
import 'database_provider.dart';
import 'synced_preferences_provider.dart';
import 'tag_filter_provider.dart';

export '../database/gtd_database.dart' show Todo, FocusSession;

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

/// Next-action tasks not yet reviewed in today's planning session.
final nextActionsForFocusSessionPlanningProvider =
    StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final planningState = ref.watch(focusSessionPlanningProvider);
  final reviewed = {
    ...planningState.reviewedTaskIds,
    ...planningState.pendingSelectedTaskIds,
  };
  return db.todoDao
      .watchNextActions()
      .map((all) => all.where((t) => !reviewed.contains(t.id)).toList());
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
// Inbox routing record — what was done to an item and how to undo it
// ---------------------------------------------------------------------------

/// Records a routing applied to an inbox item during planning, plus the
/// pre-routing state needed to undo it on re-route. The record's [kind] drives
/// the "previously selected" affordance on revisit; the prior fields let the
/// revert path restore the exact pre-routing state instead of resetting to
/// inbox defaults (which would drop pre-existing intent / person tags from
/// import or sync).
class InboxRoutingRecord {
  const InboxRoutingRecord({
    required this.kind,
    required this.priorClarified,
    required this.priorIntent,
    required this.priorDoneAt,
    required this.priorPersonTagIds,
  });

  /// Routing kind: 'next_action' | 'waiting_for' | 'maybe' | 'done'.
  final String kind;

  final bool priorClarified;
  final String priorIntent;
  final String? priorDoneAt;
  final Set<String> priorPersonTagIds;
}

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

  /// Maps [inboxNav.items] index → routing record (kind + captured prior state).
  /// An absent key means the item at that index has not yet been processed.
  final Map<int, InboxRoutingRecord> inboxRoutings;

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

  FocusSessionPlanningState copyWith({
    int? currentStep,
    int? availableMinutes,
    bool? availableTimeSet,
    String? energyLevel,
    bool clearEnergyLevel = false,
    SnapshotNav<String>? inboxNav,
    Map<int, InboxRoutingRecord>? inboxRoutings,
    List<String>? pendingSelectedTaskIds,
    List<String>? reviewedTaskIds,
    SnapshotNav<Todo>? reviewNav,
    Map<int, ReviewActionRecord>? reviewActions,
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
    // Update banner-dismissed ValueNotifier when Drift receives cross-device sync.
    ref.listen(syncedPreferencesProvider, (_, next) {
      if (next is AsyncData<SyncedPreferences>) {
        final today = planningToday();
        final dismissed = next.value.get<String>(_kBannerDismissedDateKey);
        focusSessionPlanningBannerDismissedNotifier.value = dismissed == today;

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
        state = state.copyWith(
          reviewNav: SnapshotNav<Todo>(items: items),
          reviewActions: {},
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
  /// The tag filter is captured at load time; later filter changes do not
  /// affect the snapshot.
  Future<void> loadInboxSnapshot() async {
    if (state.inboxNav.isLoaded || _loadingInboxSnapshot) return;
    _loadingInboxSnapshot = true;
    try {
      final tagIds = ref.read(tagFilterProvider);
      final items = await _db.inboxDao.watchInbox(tagIds: tagIds).first;
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

  /// Reverts the DB state for the item at [idx] back to the captured
  /// pre-routing state and removes [idx] from [inboxRoutings].
  ///
  /// Restores intent / clarified / done_at via [InboxDao.unprocessInboxItem]
  /// and the person-tag set via [InboxDao.setPersonTagsForTodo]; both targets
  /// come from the [InboxRoutingRecord] captured at routing time. Pre-existing
  /// person-tag associations (from import / sync) are preserved.
  ///
  /// Both writes run in a single DB transaction so the revert is all-or-
  /// nothing: a failure in the tag restore does not leave the row back in
  /// inbox state with the wrong assignees, and [inboxRoutings] is only
  /// cleared after the transaction commits.
  ///
  /// Note: we cannot gate on Drift's "affected rows" return value here
  /// because PowerSync exposes [todos] as a SQLite VIEW backed by an
  /// INSTEAD OF trigger, and `sqlite3_changes()` does not count rows
  /// touched by triggers — Drift always reports 0. We trust that the
  /// snapshot already vouches for the row's existence at routing time.
  Future<void> _revertProcessedInboxItem(int idx) async {
    final id = state.inboxNav.items![idx];
    final record = state.inboxRoutings[idx];
    if (record == null) return;
    await _db.transaction(() async {
      await _db.inboxDao.unprocessInboxItem(
        id,
        priorClarified: record.priorClarified,
        priorIntent: record.priorIntent,
        priorDoneAt: record.priorDoneAt,
      );
      await _db.inboxDao.setPersonTagsForTodo(
        id,
        record.priorPersonTagIds,
        _userId,
      );
    });
    state = state.copyWith(
      inboxRoutings: Map.from(state.inboxRoutings)..remove(idx),
    );
  }

  /// Captures the current pre-routing state of the item at [idx] by reading
  /// all four fields (clarified / intent / done_at / person tags) from the
  /// live DB at apply time, not from the snapshot. Returns null if the row
  /// no longer exists in the DB; callers must bail out without mutating
  /// state in that case (the snapshot row was deleted out from under us
  /// between snapshot load and routing apply, so there is nothing to
  /// route).
  ///
  /// Reading live keeps capture consistent across fields and lets revert
  /// preserve any external mutation (sync, import, ad-hoc edit) that landed
  /// between snapshot load and routing apply. The cost is one extra
  /// row-by-id query per routing call.
  Future<({
    bool clarified,
    String intent,
    String? doneAt,
    Set<String> personTagIds,
  })?> _capturePriorInboxState(int idx) async {
    final id = state.inboxNav.items![idx];
    final todo = await _db.todoDao.getTodo(id);
    if (todo == null) return null;
    final personTagIds = await _db.todoDao.getPersonTagIdsForTodo(id);
    return (
      clarified: todo.clarified,
      intent: todo.intent,
      doneAt: todo.doneAt,
      personTagIds: personTagIds,
    );
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

  /// Routes the current inbox item to Next Actions (clarified = true) and
  /// records [title] as the task's next-action text.
  ///
  /// If the item was previously routed, that routing is reverted first.
  /// Setting [next_action_text] prevents the task from immediately surfacing
  /// as Actionless in the re-clarification surface after inbox-clarify. If
  /// the DB UPDATE does not affect any row (item not found) the state is not
  /// changed.
  Future<void> processInboxItem(String id, {required String title}) async {
    final idx = state.inboxNav.index;
    if (state.inboxRoutings.containsKey(idx)) {
      await _revertProcessedInboxItem(idx);
    }
    final prior = await _capturePriorInboxState(idx);
    if (prior == null) return;
    await _db.transaction(() async {
      await _db.inboxDao.processInboxItem(id);
      await _db.todoDao.setNextActionText(id, title);
    });
    if (state.inboxNav.index != idx) return;
    state = state.copyWith(
      inboxRoutings: {
        ...state.inboxRoutings,
        idx: InboxRoutingRecord(
          kind: 'next_action',
          priorClarified: prior.clarified,
          priorIntent: prior.intent,
          priorDoneAt: prior.doneAt,
          priorPersonTagIds: prior.personTagIds,
        ),
      },
    );
    nextInboxItem();
  }

  /// Routes the current inbox item to Waiting For (clarified = true, person
  /// tags assigned by the caller before this is invoked) and records [title]
  /// as the task's next-action text.
  Future<void> processInboxItemToWaitingFor(String id,
      {required String title}) async {
    final idx = state.inboxNav.index;
    if (state.inboxRoutings.containsKey(idx)) {
      await _revertProcessedInboxItem(idx);
    }
    final prior = await _capturePriorInboxState(idx);
    if (prior == null) return;
    await _db.transaction(() async {
      await _db.inboxDao.processInboxItem(id);
      await _db.todoDao.setNextActionText(id, title);
    });
    if (state.inboxNav.index != idx) return;
    state = state.copyWith(
      inboxRoutings: {
        ...state.inboxRoutings,
        idx: InboxRoutingRecord(
          kind: 'waiting_for',
          priorClarified: prior.clarified,
          priorIntent: prior.intent,
          priorDoneAt: prior.doneAt,
          priorPersonTagIds: prior.personTagIds,
        ),
      },
    );
    nextInboxItem();
  }

  /// Routes the current inbox item to Someday/Maybe (clarified = true,
  /// intent = 'maybe').
  Future<void> processInboxItemToMaybe(String id) async {
    final idx = state.inboxNav.index;
    if (state.inboxRoutings.containsKey(idx)) {
      await _revertProcessedInboxItem(idx);
    }
    final prior = await _capturePriorInboxState(idx);
    if (prior == null) return;
    await _db.inboxDao.processInboxItem(id, intent: 'maybe');
    if (state.inboxNav.index != idx) return;
    state = state.copyWith(
      inboxRoutings: {
        ...state.inboxRoutings,
        idx: InboxRoutingRecord(
          kind: 'maybe',
          priorClarified: prior.clarified,
          priorIntent: prior.intent,
          priorDoneAt: prior.doneAt,
          priorPersonTagIds: prior.personTagIds,
        ),
      },
    );
    nextInboxItem();
  }

  /// Routes the current inbox item to Trash (clarified = true, intent =
  /// 'trash'). Soft-delete: the row remains in DB and revert restores the
  /// prior intent.
  Future<void> processInboxItemToTrash(String id) async {
    final idx = state.inboxNav.index;
    if (state.inboxRoutings.containsKey(idx)) {
      await _revertProcessedInboxItem(idx);
    }
    final prior = await _capturePriorInboxState(idx);
    if (prior == null) return;
    await _db.inboxDao.processInboxItem(id, intent: 'trash');
    if (state.inboxNav.index != idx) return;
    state = state.copyWith(
      inboxRoutings: {
        ...state.inboxRoutings,
        idx: InboxRoutingRecord(
          kind: 'trash',
          priorClarified: prior.clarified,
          priorIntent: prior.intent,
          priorDoneAt: prior.doneAt,
          priorPersonTagIds: prior.personTagIds,
        ),
      },
    );
    nextInboxItem();
  }

  /// Routes the current inbox item to Done (done_at = now). If the DB UPDATE
  /// does not affect any row (item deleted out from under us, etc.) the state
  /// is not changed.
  Future<void> processInboxItemToDone(String id) async {
    final idx = state.inboxNav.index;
    if (state.inboxRoutings.containsKey(idx)) {
      await _revertProcessedInboxItem(idx);
    }
    final prior = await _capturePriorInboxState(idx);
    if (prior == null) return;
    await _db.todoDao.markDone(id);
    if (state.inboxNav.index != idx) return;
    state = state.copyWith(
      inboxRoutings: {
        ...state.inboxRoutings,
        idx: InboxRoutingRecord(
          kind: 'done',
          priorClarified: prior.clarified,
          priorIntent: prior.intent,
          priorDoneAt: prior.doneAt,
          priorPersonTagIds: prior.personTagIds,
        ),
      },
    );
    nextInboxItem();
  }

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

    final allNextActions = await _db.todoDao.watchNextActions().first;
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

  // ---- Task Review (Step 1) --------------------------------------------------

  /// "Still relevant" — stamps last_clarified_at; only available for Stale tasks.
  Future<void> confirmReviewItemRelevant(String id) async {
    await _revertIfNeeded(ReviewActionKind.stillRelevant);
    await _db.todoDao.stampLastClarifiedAt(id);
    _recordAndAdvance(const ReviewActionRecord(kind: ReviewActionKind.stillRelevant));
  }

  /// "Waiting for…" — called after [PersonTagPickerSheet] assigns a person tag.
  ///
  /// For Stale tasks, stamps last_clarified_at explicitly to clear the stale
  /// predicate (does not rely on [assignPersonTag] as an implicit side-effect).
  /// For Actionless tasks, sets a default next_action_text so the task leaves
  /// the Actionless predicate.
  Future<void> markReviewItemWaitingFor(String id, {bool isActionless = false}) async {
    await _revertIfNeeded(ReviewActionKind.waitingFor);
    if (isActionless) {
      await _db.todoDao.setNextActionText(id, 'Waiting for…');
    } else {
      await _db.todoDao.stampLastClarifiedAt(id);
    }
    final tagIds = await _db.tagDao.getPersonTagIdsForTodo(id);
    _recordAndAdvance(ReviewActionRecord(
      kind: ReviewActionKind.waitingFor,
      personTagIds: tagIds,
    ));
  }

  /// "Update next action" — sets next_action_text and stamps last_clarified_at.
  /// Blank text is ignored: the task stays Actionless and the index does not advance.
  Future<void> updateReviewItemNextAction(String id, String text) async {
    await _revertIfNeeded(ReviewActionKind.updateNextAction);
    await _db.todoDao.setNextActionText(id, text);
    if (text.trim().isNotEmpty) {
      _recordAndAdvance(ReviewActionRecord(
        kind: ReviewActionKind.updateNextAction,
        nextActionText: text.trim(),
      ));
    } else {
      // Blank text normalises to NULL and the index does not advance, but any
      // stale action record must be cleared so the dialog doesn't pre-fill with
      // the old text when the user navigates back to this item.
      final idx = state.reviewNav.index;
      if (state.reviewActions.containsKey(idx)) {
        state = state.copyWith(
          reviewActions: Map.of(state.reviewActions)..remove(idx),
        );
      }
    }
  }

  /// "Mark done" — marks done_at and stamps last_clarified_at internally via DAO.
  Future<void> markReviewItemDone(String id) async {
    await _revertIfNeeded(ReviewActionKind.markDone);
    await _db.todoDao.markDone(id);
    _recordAndAdvance(const ReviewActionRecord(kind: ReviewActionKind.markDone));
  }

  /// "Send to Someday" — changes intent to maybe and stamps last_clarified_at.
  Future<void> deferReviewItemToSomeday(String id) async {
    await _revertIfNeeded(ReviewActionKind.sendToSomeday);
    await _db.todoDao.deferTaskToMaybe(id);
    _recordAndAdvance(const ReviewActionRecord(kind: ReviewActionKind.sendToSomeday));
  }

  /// "Trash" — sets intent to trash.
  Future<void> trashReviewItem(String id) async {
    await _revertIfNeeded(ReviewActionKind.trash);
    await _db.todoDao.setIntent(id, Intent.trash);
    _recordAndAdvance(const ReviewActionRecord(kind: ReviewActionKind.trash));
  }

  void _recordAndAdvance(ReviewActionRecord record) {
    final index = state.reviewNav.index;
    state = state.copyWith(
      reviewNav: state.reviewNav.next(),
      reviewActions: {...state.reviewActions, index: record},
    );
  }

  /// Cleans up only the DB fields that are invalid given the incoming [newKind],
  /// based on what was previously committed at the current review index.
  ///
  /// Rules (others are left untouched — next_action_text and last_clarified_at
  /// accumulate legitimately across re-selections):
  /// - Previous was [markDone]: clear done_at — completed_at is not valid
  ///   alongside any other resolution.
  /// - Previous was [sendToSomeday] or [trash] and new is a stamp/active action:
  ///   reset intent to 'next'. Intent is irrelevant for [markDone] tasks.
  Future<void> _revertIfNeeded(ReviewActionKind newKind) async {
    final idx = state.reviewNav.index;
    final previous = state.reviewActions[idx]?.kind;
    if (previous == null || idx >= state.reviewNav.length) return;

    final id = state.reviewNav.items![idx].id;

    if (previous == ReviewActionKind.markDone) {
      await _db.todoDao.clearDoneAt(id);
    }

    if ((previous == ReviewActionKind.sendToSomeday || previous == ReviewActionKind.trash) &&
        (newKind == ReviewActionKind.stillRelevant ||
            newKind == ReviewActionKind.waitingFor ||
            newKind == ReviewActionKind.updateNextAction)) {
      await _db.todoDao.setIntent(id, Intent.next);
    }
  }

  // ---- Banner dismissal ------------------------------------------------------

  /// Hides the planning banner for the rest of today.
  Future<void> dismissBannerForToday() async {
    final today = planningToday();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBannerDismissedDateKey, today);
    focusSessionPlanningBannerDismissedNotifier.value = true;
    await syncedPrefs(ref).set(_kBannerDismissedDateKey, today);
  }

  // ---- Notification skip / snooze --------------------------------------------

  /// Suppresses all planning nudges until the next calendar day and cancels
  /// any scheduled notification for today.
  Future<void> skipPlanningToday() async {
    await persistFocusSessionPlanningSkipToday(ref: ref);
    await NotificationService.instance.cancelFocusSessionPlanningReminder();
  }

  /// Snoozes the planning notification by [minutes] and reschedules it as a
  /// one-off fire.
  Future<void> snoozePlanningNotification(int minutes) async {
    final until = DateTime.now().add(Duration(minutes: minutes));
    await persistFocusSessionPlanningSnoozedUntil(until, ref: ref);
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
