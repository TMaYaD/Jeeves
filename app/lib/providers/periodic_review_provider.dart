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

import '../database/gtd_database.dart';
import '../models/todo.dart' show RoutingKind;
import '../utils/snapshot_nav.dart';
import 'database_provider.dart';
import 'periodic_review_settings_provider.dart';

export '../database/gtd_database.dart' show Todo;
export '../models/todo.dart' show RoutingKind;

class PeriodicReviewState {
  const PeriodicReviewState({
    this.currentStep = 0,
    this.inboxNav = const SnapshotNav<String>(),
    this.waitingForNav = const SnapshotNav<Todo>(),
    this.nextNav = const SnapshotNav<Todo>(),
    this.somedayNav = const SnapshotNav<Todo>(),
    this.waitingForPersonTags = const {},
    this.inboxRoutings = const {},
    this.waitingForRoutings = const {},
    this.nextRoutings = const {},
    this.somedayRoutings = const {},
    this.inboxLoadError,
    this.waitingForLoadError,
    this.nextLoadError,
    this.somedayLoadError,
  });

  final int currentStep;

  /// Snapshot of inbox todo IDs to clarify (oldest-first).
  final SnapshotNav<String> inboxNav;
  final SnapshotNav<Todo> waitingForNav;
  final SnapshotNav<Todo> nextNav;
  final SnapshotNav<Todo> somedayNav;

  /// Person tags attached to each todo in [waitingForNav], keyed by todo id.
  /// Loaded once with the snapshot so the Waiting For card can render the
  /// delegate name(s) inline without a per-item DAO call.
  final Map<String, List<Tag>> waitingForPersonTags;

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
  final String? waitingForLoadError;
  final String? nextLoadError;
  final String? somedayLoadError;

  PeriodicReviewState copyWith({
    int? currentStep,
    SnapshotNav<String>? inboxNav,
    SnapshotNav<Todo>? waitingForNav,
    SnapshotNav<Todo>? nextNav,
    SnapshotNav<Todo>? somedayNav,
    Map<String, List<Tag>>? waitingForPersonTags,
    Map<int, RoutingKind>? inboxRoutings,
    Map<int, RoutingKind>? waitingForRoutings,
    Map<int, RoutingKind>? nextRoutings,
    Map<int, RoutingKind>? somedayRoutings,
    String? inboxLoadError,
    bool clearInboxLoadError = false,
    String? waitingForLoadError,
    bool clearWaitingForLoadError = false,
    String? nextLoadError,
    bool clearNextLoadError = false,
    String? somedayLoadError,
    bool clearSomedayLoadError = false,
  }) =>
      PeriodicReviewState(
        currentStep: currentStep ?? this.currentStep,
        inboxNav: inboxNav ?? this.inboxNav,
        waitingForNav: waitingForNav ?? this.waitingForNav,
        nextNav: nextNav ?? this.nextNav,
        somedayNav: somedayNav ?? this.somedayNav,
        waitingForPersonTags:
            waitingForPersonTags ?? this.waitingForPersonTags,
        inboxRoutings: inboxRoutings ?? this.inboxRoutings,
        waitingForRoutings: waitingForRoutings ?? this.waitingForRoutings,
        nextRoutings: nextRoutings ?? this.nextRoutings,
        somedayRoutings: somedayRoutings ?? this.somedayRoutings,
        inboxLoadError: clearInboxLoadError
            ? null
            : (inboxLoadError ?? this.inboxLoadError),
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
  static const int kStepInbox = 0;
  static const int kStepWaitingFor = 1;
  static const int kStepNext = 2;
  static const int kStepSomeMaybe = 3;
  static const int kStepSummary = 4;

  static const int _kMaxStep = kStepSummary;

  /// Re-entrancy guard for [advanceStep] / [goToStep]. Prevents concurrent
  /// step transitions (rapid Next taps, or an auto-skip firing while a slow
  /// snapshot load is still in flight) from racing on [state.currentStep].
  bool _isTransitioning = false;

  /// Idempotency guards for the per-step snapshot loaders. Prevent duplicate
  /// in-flight reads (post-frame callbacks fire on every rebuild while the
  /// nav is unloaded) and let re-entry preserve the user's per-item cursor.
  bool _loadingInboxSnapshot = false;
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
      final todos = await _db.inboxDao.watchInbox().first;
      final ids = todos.reversed.map((t) => t.id).toList();
      state = state.copyWith(inboxNav: state.inboxNav.withItems(ids));
    } catch (e) {
      state = state.copyWith(inboxLoadError: e.toString());
    } finally {
      _loadingInboxSnapshot = false;
    }
  }

  Future<void> loadWaitingForSnapshot() async {
    if (state.waitingForNav.isLoaded || _loadingWaitingForSnapshot) return;
    _loadingWaitingForSnapshot = true;
    state = state.copyWith(clearWaitingForLoadError: true);
    try {
      final todos = await _db.todoDao.watchPersonTagged().first;
      // Batch the person-tag lookup so the card can render delegate names
      // without spawning one DAO call per item.
      final tags = await _db.todoDao
          .getPersonTagsForTodos({for (final t in todos) t.id});
      state = state.copyWith(
        waitingForNav: state.waitingForNav.withItems(todos),
        waitingForPersonTags: tags,
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
      final todos = await _db.todoDao.getNextExcludingPersonTagged();
      state = state.copyWith(
          nextNav: state.nextNav.withItems(todos));
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
      final todos = await _db.todoDao.watchMaybe().first;
      state = state.copyWith(somedayNav: state.somedayNav.withItems(todos));
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
  Future<void> loadAllSnapshots() async {
    await Future.wait<void>([
      loadInboxSnapshot(),
      loadWaitingForSnapshot(),
      loadNextSnapshot(),
      loadSomedaySnapshot(),
    ]);
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
    await _transitionTo((state.currentStep + 1).clamp(0, _kMaxStep));
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
    _loadingInboxSnapshot = false;
    _loadingWaitingForSnapshot = false;
    _loadingNextSnapshot = false;
    _loadingSomedaySnapshot = false;
    state = const PeriodicReviewState();
  }
}
