/// Wizard state for the Weekly Review ceremony (issue #54).
///
/// State is transient — discarded by [completeReview]. The provider is not
/// auto-disposed so a user can navigate away mid-ceremony and resume; only
/// finishing the wizard wipes the in-session snapshots and cursors.
/// Per-step list iteration is delegated to [SnapshotNav<T>]; per-step
/// snapshots are loaded once on step entry and never re-subscribed during
/// navigation.
///
/// Durable state (last-completed timestamp, banner toggle, notification
/// settings) lives on [periodicReviewSettingsProvider] which is a thin wrapper
/// over [SyncedPreferencesNotifier].
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/focus_session_dao.dart' show BypassedOutcome;
import '../database/gtd_database.dart';
import '../models/todo.dart' show RoutingKind;
import '../utils/snapshot_nav.dart';
import 'bypassed_outcomes_provider.dart';
import 'clarify_retention_provider.dart';
import 'database_provider.dart';
import 'clock_provider.dart';
import 'periodic_review_ranker.dart';
import 'synced_preferences_provider.dart';
import 'periodic_review_settings_provider.dart';

export '../database/gtd_database.dart' show Todo;
export '../models/todo.dart' show RoutingKind;

class PeriodicReviewState {
  const PeriodicReviewState({
    this.currentStep = 0,
    this.sessionStarted = false,
    this.isFinalSession = true,
    this.inboxNav = const SnapshotNav<String>(),
    this.bypassedNav = const SnapshotNav<Todo>(),
    this.waitingForNav = const SnapshotNav<Todo>(),
    this.nextNav = const SnapshotNav<Todo>(),
    this.somedayNav = const SnapshotNav<Todo>(),
    this.bypassedPassCounts = const {},
    this.bypassedDeferredCount = 0,
    this.bypassedDecidedIds = const {},
    this.bypassedDecisionPending = false,
    this.waitingForPersonTags = const {},
    this.actionTexts = const {},
    this.inboxRoutings = const {},
    this.waitingForRoutings = const {},
    this.nextRoutings = const {},
    this.somedayRoutings = const {},
    this.inboxLoadError,
    this.bypassedLoadError,
    this.waitingForLoadError,
    this.nextLoadError,
    this.somedayLoadError,
  });

  final int currentStep;
  final bool sessionStarted;
  final bool isFinalSession;

  /// Snapshot of inbox todo IDs to clarify (oldest-first).
  final SnapshotNav<String> inboxNav;

  /// Bypassed Outcomes this session decides, between Process Inbox and Review
  /// Waiting For. The step is shown only when this holds at least one.
  final SnapshotNav<Todo> bypassedNav;

  /// How many FocusSessions passed each Outcome in [bypassedNav] over, keyed by
  /// Outcome id; the card says "Bypassed N times".
  final Map<String, int> bypassedPassCounts;

  /// Bypassed Outcomes a short session left out; they wait for a longer one.
  /// Never in any step, so the step's completion line says how many there are.
  final int bypassedDeferredCount;

  /// Outcomes in [bypassedNav] that already have a decision. Navigation never
  /// changes it: a decided Outcome is not offered again, however the user
  /// moves Back and forth.
  final Set<String> bypassedDecidedIds;

  /// True while a decision is being written; the step disables both buttons.
  final bool bypassedDecisionPending;

  /// The first Outcome in [bypassedNav] without a decision, or null when
  /// every one is decided (or the snapshot is not loaded).
  Todo? get bypassedNextUndecided {
    for (final todo in bypassedNav.items ?? const <Todo>[]) {
      if (!bypassedDecidedIds.contains(todo.id)) return todo;
    }
    return null;
  }

  bool get bypassedAllDecided =>
      bypassedNav.isLoaded && bypassedNextUndecided == null;
  final SnapshotNav<Todo> waitingForNav;
  final SnapshotNav<Todo> nextNav;
  final SnapshotNav<Todo> somedayNav;

  /// Person tags attached to each todo in [waitingForNav], keyed by todo id.
  /// Loaded once with the snapshot so the Waiting For card can render the
  /// delegate name(s) inline without a per-item DAO call.
  final Map<String, List<Tag>> waitingForPersonTags;

  /// Current Action text for the Outcomes in every list-driven snapshot,
  /// keyed by Outcome id. An absent key is an Actionless Outcome.
  ///
  /// Loaded alongside each snapshot from `actions` — the Action entity is the
  /// only next-action grain, and what the steps render and the re-clarify
  /// dialog prefills (ADR-0001 story 3). One map across the steps
  /// because Outcome ids are unique; each loader merges its slice in.
  final Map<String, String> actionTexts;

  /// In-session record of the last [RoutingKind] applied at each cursor index
  /// for each list-driven step. Drives the "previously selected" affordance
  /// when the user backs up to revisit an item.
  final Map<int, RoutingKind> inboxRoutings;
  final Map<int, RoutingKind> waitingForRoutings;
  final Map<int, RoutingKind> nextRoutings;
  final Map<int, RoutingKind> somedayRoutings;

  /// Non-null when the matching snapshot load failed; rendered inline by the
  /// step (no toasts in the wizard) with a Retry affordance.
  final String? inboxLoadError;
  final String? bypassedLoadError;
  final String? waitingForLoadError;
  final String? nextLoadError;
  final String? somedayLoadError;

  PeriodicReviewState copyWith({
    int? currentStep,
    bool? sessionStarted,
    bool? isFinalSession,
    SnapshotNav<String>? inboxNav,
    SnapshotNav<Todo>? bypassedNav,
    SnapshotNav<Todo>? waitingForNav,
    SnapshotNav<Todo>? nextNav,
    SnapshotNav<Todo>? somedayNav,
    Map<String, int>? bypassedPassCounts,
    int? bypassedDeferredCount,
    Set<String>? bypassedDecidedIds,
    bool? bypassedDecisionPending,
    Map<String, List<Tag>>? waitingForPersonTags,
    Map<String, String>? actionTexts,
    Map<int, RoutingKind>? inboxRoutings,
    Map<int, RoutingKind>? waitingForRoutings,
    Map<int, RoutingKind>? nextRoutings,
    Map<int, RoutingKind>? somedayRoutings,
    String? inboxLoadError,
    bool clearInboxLoadError = false,
    String? bypassedLoadError,
    bool clearBypassedLoadError = false,
    String? waitingForLoadError,
    bool clearWaitingForLoadError = false,
    String? nextLoadError,
    bool clearNextLoadError = false,
    String? somedayLoadError,
    bool clearSomedayLoadError = false,
  }) =>
      PeriodicReviewState(
        currentStep: currentStep ?? this.currentStep,
        sessionStarted: sessionStarted ?? this.sessionStarted,
        isFinalSession: isFinalSession ?? this.isFinalSession,
        inboxNav: inboxNav ?? this.inboxNav,
        bypassedNav: bypassedNav ?? this.bypassedNav,
        bypassedPassCounts: bypassedPassCounts ?? this.bypassedPassCounts,
        bypassedDeferredCount:
            bypassedDeferredCount ?? this.bypassedDeferredCount,
        bypassedDecidedIds: bypassedDecidedIds ?? this.bypassedDecidedIds,
        bypassedDecisionPending:
            bypassedDecisionPending ?? this.bypassedDecisionPending,
        waitingForNav: waitingForNav ?? this.waitingForNav,
        nextNav: nextNav ?? this.nextNav,
        somedayNav: somedayNav ?? this.somedayNav,
        waitingForPersonTags:
            waitingForPersonTags ?? this.waitingForPersonTags,
        actionTexts: actionTexts ?? this.actionTexts,
        inboxRoutings: inboxRoutings ?? this.inboxRoutings,
        waitingForRoutings: waitingForRoutings ?? this.waitingForRoutings,
        nextRoutings: nextRoutings ?? this.nextRoutings,
        somedayRoutings: somedayRoutings ?? this.somedayRoutings,
        inboxLoadError: clearInboxLoadError
            ? null
            : (inboxLoadError ?? this.inboxLoadError),
        bypassedLoadError: clearBypassedLoadError
            ? null
            : (bypassedLoadError ?? this.bypassedLoadError),
        waitingForLoadError: clearWaitingForLoadError
            ? null
            : (waitingForLoadError ?? this.waitingForLoadError),
        nextLoadError: clearNextLoadError
            ? null
            : (nextLoadError ?? this.nextLoadError),
        somedayLoadError: clearSomedayLoadError
            ? null
            : (somedayLoadError ?? this.somedayLoadError),
      );
}

final periodicReviewProvider =
    NotifierProvider<PeriodicReviewNotifier, PeriodicReviewState>(
  PeriodicReviewNotifier.new,
);

class PeriodicReviewNotifier extends Notifier<PeriodicReviewState> {
  // Step indices — referenced by the screen and by tests. Capture happens
  // throughout the week (no dedicated brain-dump step in the wizard).
  //
  // Step 0 is the duration-estimate intro (#486): a real first PageView step
  // excluded from the progress count, so the four working steps still read
  // "Step 1 of 4" … "Step 4 of 4". The intro loads no snapshot — the mount's
  // loadAllSnapshots already covers every step.
  //
  // [kStepBypassed] exists only for a session that holds a Bypassed Outcome;
  // otherwise [advanceStep] and [previousStep] step over it and the working
  // steps number from 1 to 4 as before.
  static const int kStepIntro = 0;
  static const int kStepInbox = 1;
  static const int kStepBypassed = 2;
  static const int kStepWaitingFor = 3;
  static const int kStepNext = 4;
  static const int kStepSomeMaybe = 5;
  static const int kStepSummary = 6;

  static const int _kMaxStep = kStepSummary;

  /// Re-entrancy guard for [advanceStep] / [goToStep]. Prevents concurrent
  /// step transitions (rapid Next taps, or an auto-skip firing while a slow
  /// snapshot load is still in flight) from racing on [state.currentStep].
  bool _isTransitioning = false;
  bool _startingSession = false;
  Future<void>? _allSnapshotsLoad;
  final Map<String, DateTime> _captureCreatedAtCache = {};

  /// Idempotency guards for the per-step snapshot loaders. Prevent duplicate
  /// in-flight reads (post-frame callbacks fire on every rebuild while the
  /// nav is unloaded) and let re-entry preserve the user's per-item cursor.
  bool _loadingInboxSnapshot = false;
  bool _loadingBypassedSnapshot = false;
  bool _loadingWaitingForSnapshot = false;
  bool _loadingNextSnapshot = false;
  bool _loadingSomedaySnapshot = false;

  @override
  PeriodicReviewState build() => const PeriodicReviewState();

  GtdDatabase get _db => ref.read(databaseProvider);

  // ---------------------------------------------------------------------------
  // Snapshot loaders — each awaits the first emission of its source provider
  // ---------------------------------------------------------------------------

  Future<void> loadInboxSnapshot() async {
    if (state.inboxNav.isLoaded || _loadingInboxSnapshot) return;
    _loadingInboxSnapshot = true;
    state = state.copyWith(clearInboxLoadError: true);
    try {
      // Captures with `clarified_at IS NULL` (ADR-0006) — the snapshot holds
      // Capture ids, and the zero-inbox step clarifies each into an Outcome.
      final captures = await _db.captureDao.watchInbox().first;
      _captureCreatedAtCache.addAll({for (final capture in captures) capture.id: capture.createdAt});
      final ids = captures.reversed.map((c) => c.id).toList();
      state = state.copyWith(inboxNav: state.inboxNav.withItems(ids));
    } catch (e) {
      state = state.copyWith(inboxLoadError: e.toString());
    } finally {
      _loadingInboxSnapshot = false;
    }
  }

  /// Every Bypassed Outcome at the current threshold, most-passed-over first.
  Future<List<BypassedOutcome>> _bypassedOutcomes() => _db.focusSessionDao
      .getBypassedOutcomes(ref.read(bypassThresholdProvider));

  /// Outcome ids the Bypassed step owns, whether or not a short session keeps
  /// them: they never also appear in Review Waiting For or Review Next.
  Future<Set<String>> _bypassedIds() async =>
      {for (final bypassed in await _bypassedOutcomes()) bypassed.outcome.id};

  Future<void> loadBypassedSnapshot() async {
    if (state.bypassedNav.isLoaded || _loadingBypassedSnapshot) return;
    _loadingBypassedSnapshot = true;
    state = state.copyWith(clearBypassedLoadError: true);
    try {
      await ref.read(syncedPreferencesProvider.future);
      final bypassed = await _bypassedOutcomes();
      final todos = _uncovered([for (final b in bypassed) b.outcome]);
      final actionTexts = await _db.actionDao
          .getCurrentActionTexts({for (final t in todos) t.id});
      state = state.copyWith(
        bypassedNav: state.bypassedNav.withItems(todos),
        bypassedPassCounts: {
          for (final b in bypassed) b.outcome.id: b.passedOverSessionCount,
        },
        actionTexts: {...state.actionTexts, ...actionTexts},
      );
    } catch (e) {
      state = state.copyWith(bypassedLoadError: e.toString());
    } finally {
      _loadingBypassedSnapshot = false;
    }
  }

  Future<void> loadWaitingForSnapshot() async {
    if (state.waitingForNav.isLoaded || _loadingWaitingForSnapshot) return;
    _loadingWaitingForSnapshot = true;
    state = state.copyWith(clearWaitingForLoadError: true);
    try {
      await ref.read(syncedPreferencesProvider.future);
      final bypassedIds = await _bypassedIds();
      final todos = _uncovered(await _db.todoDao.watchPersonTagged().first)
          .where((todo) => !bypassedIds.contains(todo.id))
          .toList();
      // Batch the person-tag lookup so the card can render delegate names
      // without spawning one DAO call per item.
      final tags = await _db.todoDao
          .getPersonTagsForTodos({for (final t in todos) t.id});
      final actionTexts = await _db.actionDao
          .getCurrentActionTexts({for (final t in todos) t.id});
      state = state.copyWith(
        waitingForNav: state.waitingForNav.withItems(todos),
        waitingForPersonTags: tags,
        actionTexts: {...state.actionTexts, ...actionTexts},
      );
    } catch (e) {
      state = state.copyWith(waitingForLoadError: e.toString());
    } finally {
      _loadingWaitingForSnapshot = false;
    }
  }

  Future<void> loadNextSnapshot() async {
    if (state.nextNav.isLoaded || _loadingNextSnapshot) return;
    _loadingNextSnapshot = true;
    state = state.copyWith(clearNextLoadError: true);
    try {
      await ref.read(syncedPreferencesProvider.future);
      final bypassedIds = await _bypassedIds();
      final todos = _uncovered(await _db.todoDao.getNextExcludingPersonTagged())
          .where((todo) => !bypassedIds.contains(todo.id))
          .toList();
      // Batched current-Action lookup so the card renders the concrete
      // commitment without one DAO call per item.
      final actionTexts = await _db.actionDao
          .getCurrentActionTexts({for (final t in todos) t.id});
      state = state.copyWith(
        nextNav: state.nextNav.withItems(todos),
        actionTexts: {...state.actionTexts, ...actionTexts},
      );
    } catch (e) {
      state = state.copyWith(nextLoadError: e.toString());
    } finally {
      _loadingNextSnapshot = false;
    }
  }

  Future<void> loadSomedaySnapshot() async {
    if (state.somedayNav.isLoaded || _loadingSomedaySnapshot) return;
    _loadingSomedaySnapshot = true;
    state = state.copyWith(clearSomedayLoadError: true);
    try {
      await ref.read(syncedPreferencesProvider.future);
      final todos = _uncovered(await _db.todoDao.watchSomedayMaybe().first);
      final actionTexts = await _db.actionDao
          .getCurrentActionTexts({for (final t in todos) t.id});
      state = state.copyWith(
        somedayNav: state.somedayNav.withItems(todos),
        actionTexts: {...state.actionTexts, ...actionTexts},
      );
    } catch (e) {
      state = state.copyWith(somedayLoadError: e.toString());
    } finally {
      _loadingSomedaySnapshot = false;
    }
  }

  /// Loads every list-driven step's snapshot up front. Called from the
  /// wizard screen when it first mounts so an item routed in one step (e.g.
  /// inbox → maybe) does not surface in a later step (Someday/Maybe) where
  /// the user already decided what to do with it. Each loader is idempotent
  /// so repeat calls are no-ops.
  Future<void> loadAllSnapshots() =>
      _allSnapshotsLoad ??= _loadAllSnapshots().whenComplete(() => _allSnapshotsLoad = null);

  Future<void> _loadAllSnapshots() async {
    await ref.read(syncedPreferencesProvider.future);
    await Future.wait<void>([
      loadInboxSnapshot(),
      loadBypassedSnapshot(),
      loadWaitingForSnapshot(),
      loadNextSnapshot(),
      loadSomedaySnapshot(),
    ]);
  }

  List<Todo> _uncovered(List<Todo> todos) {
    final opened = ref.read(periodicReviewOpenSinceProvider);
    if (opened == null) return todos;
    return todos.where((todo) => todo.lastClarifiedAt == null ||
        todo.lastClarifiedAt!.isBefore(opened)).toList();
  }

  List<PeriodicReviewCandidate> _candidates() {
    PeriodicReviewCandidate outcome(Todo todo, PeriodicReviewStepKind step) =>
        PeriodicReviewCandidate(
          step: step,
          id: todo.id,
          lastClarifiedAt: todo.lastClarifiedAt,
          createdAt: todo.createdAt,
        );
    return [
      for (final id in state.inboxNav.items!)
        PeriodicReviewCandidate(
          step: PeriodicReviewStepKind.inbox, id: id,
          lastClarifiedAt: null, createdAt: _captureCreatedAtCache[id]!,
        ),
      for (final todo in state.bypassedNav.items!)
        outcome(todo, PeriodicReviewStepKind.bypassed),
      for (final todo in state.waitingForNav.items!)
        outcome(todo, PeriodicReviewStepKind.waitingFor),
      for (final todo in state.nextNav.items!)
        outcome(todo, PeriodicReviewStepKind.next),
      for (final todo in state.somedayNav.items!)
        outcome(todo, PeriodicReviewStepKind.someday),
    ];
  }

  /// Chooses membership once; Back to the intro preserves this session's cursors.
  Future<void> startSession({int? budgetMinutes}) async {
    if (_startingSession) return;
    _startingSession = true;
    try {
      if (state.sessionStarted) {
        await advanceStep();
        return;
      }
      await loadAllSnapshots();
      if (!state.inboxNav.isLoaded || !state.bypassedNav.isLoaded ||
          !state.waitingForNav.isLoaded ||
          !state.nextNav.isLoaded || !state.somedayNav.isLoaded) {
        throw StateError('Could not load the review. Please try again.');
      }
      final count = state.inboxNav.length + state.bypassedNav.length +
          state.waitingForNav.length +
          state.nextNav.length + state.somedayNav.length;
      final budget = budgetMinutes == null ? count : weeklyReviewItemBudget(budgetMinutes);
      if (budgetMinutes != null && budget <= 0) {
        throw ArgumentError.value(budgetMinutes, 'budgetMinutes');
      }
      if (budget < count) {
        final candidates = _candidates();
        final ranked = await ref.read(periodicReviewRankerProvider)
            .rank(List.unmodifiable(candidates));
        // The strategy supplies only an ordering. Canonical candidates supply
        // membership: ignore foreign keys, dedupe, and append any omissions.
        final validKeys = {for (final candidate in candidates) (candidate.step, candidate.id)};
        final selected = <(PeriodicReviewStepKind, String)>{};
        for (final candidate in [...ranked, ...candidates]) {
          final key = (candidate.step, candidate.id);
          if (validKeys.contains(key)) selected.add(key);
          if (selected.length == budget) break;
        }
        if (ref.read(periodicReviewOpenSinceProvider) == null) {
          await syncedPrefs(ref).set(kPeriodicReviewOpenSinceKey,
              ref.read(clockProvider)().toUtc().toIso8601String());
        }
        List<Todo> selectedTodos(List<Todo> todos, PeriodicReviewStepKind step) =>
            todos.where((todo) => selected.contains((step, todo.id))).toList();
        state = state.copyWith(
          inboxNav: state.inboxNav.withItems(state.inboxNav.items!
              .where((id) => selected.contains((PeriodicReviewStepKind.inbox, id))).toList()),
          bypassedNav: state.bypassedNav.withItems(selectedTodos(
              state.bypassedNav.items!, PeriodicReviewStepKind.bypassed)),
          bypassedDeferredCount: state.bypassedNav.length -
              selectedTodos(state.bypassedNav.items!,
                  PeriodicReviewStepKind.bypassed).length,
          waitingForNav: state.waitingForNav.withItems(selectedTodos(
              state.waitingForNav.items!, PeriodicReviewStepKind.waitingFor)),
          nextNav: state.nextNav.withItems(selectedTodos(
              state.nextNav.items!, PeriodicReviewStepKind.next)),
          somedayNav: state.somedayNav.withItems(selectedTodos(
              state.somedayNav.items!, PeriodicReviewStepKind.someday)),
          isFinalSession: false,
          sessionStarted: true,
        );
      } else {
        state = state.copyWith(isFinalSession: true, sessionStarted: true);
      }
      await advanceStep();
    } finally {
      _startingSession = false;
    }
  }

  /// Re-read durable progress, including skips and Captures added this session.
  Future<int> remainingItemCount() async {
    await ref.read(syncedPreferencesProvider.future);
    final captures = await _db.captureDao.watchInbox().first;
    final waiting = _uncovered(await _db.todoDao.watchPersonTagged().first);
    final next = _uncovered(await _db.todoDao.getNextExcludingPersonTagged());
    final someday = _uncovered(await _db.todoDao.watchSomedayMaybe().first);
    return captures.length + waiting.length + next.length + someday.length;
  }

  // ---------------------------------------------------------------------------
  // Per-item navigation
  // ---------------------------------------------------------------------------

  void advanceInbox() =>
      state = state.copyWith(inboxNav: state.inboxNav.next());

  void previousInbox() {
    if (!state.inboxNav.canGoBack) return;
    state = state.copyWith(inboxNav: state.inboxNav.previous());
  }

  /// Records one decision for [outcomeId]. Writes are serialized (a second tap
  /// while one is pending is ignored) and an Outcome that already has a
  /// decision is never decided again. Only a successful write marks it
  /// decided, keyed by id, so navigation during the write cannot misattribute
  /// it.
  ///
  /// [decision] reports whether the write landed. When it did not (the Outcome
  /// was deleted after the snapshot) the Outcome is removed from the step
  /// without being credited as decided.
  Future<void> decideBypassed(
    String outcomeId,
    Future<bool> Function(String outcomeId) decision,
  ) async {
    if (state.bypassedDecisionPending ||
        state.bypassedDecidedIds.contains(outcomeId)) {
      return;
    }
    state = state.copyWith(bypassedDecisionPending: true);
    try {
      final landed = await decision(outcomeId);
      if (landed) {
        state = state.copyWith(
          bypassedDecidedIds: {...state.bypassedDecidedIds, outcomeId},
        );
      } else {
        state = state.copyWith(
          bypassedNav: state.bypassedNav.withItems(
            state.bypassedNav.items!.where((t) => t.id != outcomeId).toList(),
          ),
        );
      }
    } finally {
      state = state.copyWith(bypassedDecisionPending: false);
    }
  }

  void advanceWaitingFor() =>
      state = state.copyWith(waitingForNav: state.waitingForNav.next());

  void previousWaitingFor() {
    if (!state.waitingForNav.canGoBack) return;
    state = state.copyWith(waitingForNav: state.waitingForNav.previous());
  }

  void advanceNext() =>
      state = state.copyWith(nextNav: state.nextNav.next());

  void previousNext() {
    if (!state.nextNav.canGoBack) return;
    state =
        state.copyWith(nextNav: state.nextNav.previous());
  }

  void advanceSomeday() =>
      state = state.copyWith(somedayNav: state.somedayNav.next());

  void previousSomeday() {
    if (!state.somedayNav.canGoBack) return;
    state = state.copyWith(somedayNav: state.somedayNav.previous());
  }

  // ---------------------------------------------------------------------------
  // Routing history — drives the "previously selected" affordance when the
  // user backs up to an item they've already routed in this session.
  // ---------------------------------------------------------------------------

  void recordInboxRouting(int index, RoutingKind kind) {
    state = state.copyWith(
      inboxRoutings: {...state.inboxRoutings, index: kind},
    );
  }

  void recordWaitingForRouting(int index, RoutingKind kind) {
    state = state.copyWith(
      waitingForRoutings: {...state.waitingForRoutings, index: kind},
    );
  }

  void recordNextRouting(int index, RoutingKind kind) {
    state = state.copyWith(
      nextRoutings: {...state.nextRoutings, index: kind},
    );
  }

  void recordSomedayRouting(int index, RoutingKind kind) {
    state = state.copyWith(
      somedayRoutings: {...state.somedayRoutings, index: kind},
    );
  }

  // ---------------------------------------------------------------------------
  // Step navigation
  // ---------------------------------------------------------------------------

  Future<void> advanceStep() async {
    if (_isTransitioning) return;
    var next = (state.currentStep + 1).clamp(0, _kMaxStep);
    if (next == kStepBypassed) {
      await loadBypassedSnapshot();
      if (!_hasBypassedStep) next++;
    }
    await _transitionTo(next);
  }

  /// Whether this session shows the Bypassed step: only when it holds at
  /// least one Bypassed Outcome.
  bool get _hasBypassedStep => state.bypassedNav.items?.isNotEmpty ?? false;

  /// Crosses to the previous step, over the Bypassed step when it is hidden.
  Future<void> previousStep() async {
    if (_isTransitioning) return;
    var previous = (state.currentStep - 1).clamp(0, _kMaxStep);
    if (previous == kStepBypassed && !_hasBypassedStep) previous--;
    await _transitionTo(previous);
  }

  Future<void> goToStep(int step) async {
    if (_isTransitioning) return;
    await _transitionTo(step.clamp(0, _kMaxStep));
  }

  /// Performs the step transition while holding [_isTransitioning].
  Future<void> _transitionTo(int step) async {
    _isTransitioning = true;
    try {
      state = state.copyWith(currentStep: step);
      await _onStepEnter(step);
    } finally {
      _isTransitioning = false;
    }
  }

  /// Loads the snapshot for the step that was just entered. Empty snapshots
  /// are shown to the user as an empty-state view inside the step body; the
  /// step does not auto-skip. The user clicks Next to advance.
  Future<void> _onStepEnter(int step) async {
    switch (step) {
      case kStepInbox:
        await loadInboxSnapshot();
      case kStepBypassed:
        await loadBypassedSnapshot();
      case kStepWaitingFor:
        await loadWaitingForSnapshot();
      case kStepNext:
        await loadNextSnapshot();
      case kStepSomeMaybe:
        await loadSomedaySnapshot();
    }
  }

  // ---------------------------------------------------------------------------
  // Completion
  // ---------------------------------------------------------------------------

  /// Persists the completion timestamp via the settings notifier and discards
  /// the in-session snapshots, cursors, and routing history so the next entry
  /// starts on a clean Step 0. The provider is not [AutoDisposeNotifier];
  /// without this, re-entering the screen would resume a finished ceremony
  /// with stale snapshots. Caller is responsible for navigating away.
  Future<void> completeReview() async {
    final settings = ref.read(periodicReviewSettingsProvider.notifier);
    await settings.completeReview();
    await finishSession();
  }

  /// Done on a partial session: stamps the session as the last review and
  /// ends the sitting. The durable review period stays open.
  Future<void> completeSession() async {
    await ref.read(periodicReviewSettingsProvider.notifier).markSessionFinished();
    await finishSession();
  }

  /// Ends only this sitting; the durable review remains open.
  Future<void> finishSession() async {
    _captureCreatedAtCache.clear();
    _loadingInboxSnapshot = false;
    _loadingBypassedSnapshot = false;
    _loadingWaitingForSnapshot = false;
    _loadingNextSnapshot = false;
    _loadingSomedaySnapshot = false;
    state = const PeriodicReviewState();
    // Retained clarify drafts are in-session working memory too — a draft that
    // outlived the review would seed a card in the next one.
    ref.read(clarifyRetentionProvider).clearAll();
  }
}
