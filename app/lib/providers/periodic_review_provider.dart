/// Wizard state for the Weekly Review ceremony (issue #54).
///
/// State is transient — discarded on completion or when the screen is left.
/// Per-step list iteration is delegated to [SnapshotNav<T>]; per-step
/// snapshots are loaded once on step entry and never re-subscribed during
/// navigation.
///
/// Durable state (last-completed timestamp, banner toggle, notification
/// settings, last objectives) lives on [periodicReviewSettingsProvider] which
/// is a thin wrapper over [SyncedPreferencesNotifier].
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
    this.projectsNav = const SnapshotNav<Todo>(),
    this.somedayNav = const SnapshotNav<Todo>(),
    this.waitingForPersonTags = const {},
    this.inboxRoutings = const {},
    this.waitingForRoutings = const {},
    this.projectsRoutings = const {},
    this.somedayRoutings = const {},
    this.objectives = const [],
    this.isComplete = false,
    this.inboxLoadError,
    this.waitingForLoadError,
    this.projectsLoadError,
    this.somedayLoadError,
  });

  final int currentStep;

  /// Snapshot of inbox todo IDs to clarify (oldest-first).
  final SnapshotNav<String> inboxNav;
  final SnapshotNav<Todo> waitingForNav;
  final SnapshotNav<Todo> projectsNav;
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
  final Map<int, RoutingKind> projectsRoutings;
  final Map<int, RoutingKind> somedayRoutings;

  final List<String> objectives;

  final bool isComplete;

  /// Non-null when the matching snapshot load failed; rendered inline by the
  /// step (no toasts in the wizard) with a Retry affordance.
  final String? inboxLoadError;
  final String? waitingForLoadError;
  final String? projectsLoadError;
  final String? somedayLoadError;

  PeriodicReviewState copyWith({
    int? currentStep,
    SnapshotNav<String>? inboxNav,
    SnapshotNav<Todo>? waitingForNav,
    SnapshotNav<Todo>? projectsNav,
    SnapshotNav<Todo>? somedayNav,
    Map<String, List<Tag>>? waitingForPersonTags,
    Map<int, RoutingKind>? inboxRoutings,
    Map<int, RoutingKind>? waitingForRoutings,
    Map<int, RoutingKind>? projectsRoutings,
    Map<int, RoutingKind>? somedayRoutings,
    List<String>? objectives,
    bool? isComplete,
    String? inboxLoadError,
    bool clearInboxLoadError = false,
    String? waitingForLoadError,
    bool clearWaitingForLoadError = false,
    String? projectsLoadError,
    bool clearProjectsLoadError = false,
    String? somedayLoadError,
    bool clearSomedayLoadError = false,
  }) =>
      PeriodicReviewState(
        currentStep: currentStep ?? this.currentStep,
        inboxNav: inboxNav ?? this.inboxNav,
        waitingForNav: waitingForNav ?? this.waitingForNav,
        projectsNav: projectsNav ?? this.projectsNav,
        somedayNav: somedayNav ?? this.somedayNav,
        waitingForPersonTags:
            waitingForPersonTags ?? this.waitingForPersonTags,
        inboxRoutings: inboxRoutings ?? this.inboxRoutings,
        waitingForRoutings: waitingForRoutings ?? this.waitingForRoutings,
        projectsRoutings: projectsRoutings ?? this.projectsRoutings,
        somedayRoutings: somedayRoutings ?? this.somedayRoutings,
        objectives: objectives ?? this.objectives,
        isComplete: isComplete ?? this.isComplete,
        inboxLoadError: clearInboxLoadError
            ? null
            : (inboxLoadError ?? this.inboxLoadError),
        waitingForLoadError: clearWaitingForLoadError
            ? null
            : (waitingForLoadError ?? this.waitingForLoadError),
        projectsLoadError: clearProjectsLoadError
            ? null
            : (projectsLoadError ?? this.projectsLoadError),
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
  static const int kStepProjects = 2;
  static const int kStepSomeMaybe = 3;
  static const int kStepObjectives = 4;
  static const int kStepSummary = 5;

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
  bool _loadingProjectsSnapshot = false;
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

  Future<void> loadProjectsSnapshot() async {
    if (state.projectsNav.isLoaded || _loadingProjectsSnapshot) return;
    _loadingProjectsSnapshot = true;
    state = state.copyWith(clearProjectsLoadError: true);
    try {
      final todos = await _db.todoDao.getNextActionsWithProjectTags();
      state =
          state.copyWith(projectsNav: state.projectsNav.withItems(todos));
    } catch (e) {
      state = state.copyWith(projectsLoadError: e.toString());
    } finally {
      _loadingProjectsSnapshot = false;
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
      loadProjectsSnapshot(),
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

  void advanceProjects() =>
      state = state.copyWith(projectsNav: state.projectsNav.next());

  void previousProjects() {
    if (!state.projectsNav.canGoBack) return;
    state = state.copyWith(projectsNav: state.projectsNav.previous());
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

  void recordProjectsRouting(int index, RoutingKind kind) {
    state = state.copyWith(
      projectsRoutings: {...state.projectsRoutings, index: kind},
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

  /// Performs the step transition while holding [_isTransitioning]. Internal
  /// callers (auto-skip in [_onStepEnter]) use this directly so the guard set
  /// by the outer [advanceStep] / [goToStep] does not block their reentry.
  Future<void> _transitionTo(int step) async {
    _isTransitioning = true;
    try {
      state = state.copyWith(currentStep: step);
      await _onStepEnter(step);
    } finally {
      _isTransitioning = false;
    }
  }

  Future<void> _onStepEnter(int step) async {
    switch (step) {
      case kStepInbox:
        await loadInboxSnapshot();
        // Auto-skip: empty inbox advances past Step 0 on entry. Loader has
        // already returned so we are outside any build phase, and the
        // _isTransitioning guard prevents external concurrent entries.
        if (state.currentStep == kStepInbox &&
            state.inboxNav.isLoaded &&
            state.inboxNav.isEmpty) {
          await _transitionTo((state.currentStep + 1).clamp(0, _kMaxStep));
        }
      case kStepWaitingFor:
        await loadWaitingForSnapshot();
        if (state.currentStep == kStepWaitingFor &&
            state.waitingForNav.isLoaded &&
            state.waitingForNav.isEmpty) {
          await _transitionTo((state.currentStep + 1).clamp(0, _kMaxStep));
        }
      case kStepProjects:
        await loadProjectsSnapshot();
        if (state.currentStep == kStepProjects &&
            state.projectsNav.isLoaded &&
            state.projectsNav.isEmpty) {
          await _transitionTo((state.currentStep + 1).clamp(0, _kMaxStep));
        }
      case kStepSomeMaybe:
        await loadSomedaySnapshot();
        if (state.currentStep == kStepSomeMaybe &&
            state.somedayNav.isLoaded &&
            state.somedayNav.isEmpty) {
          await _transitionTo((state.currentStep + 1).clamp(0, _kMaxStep));
        }
      case kStepObjectives:
        if (state.objectives.isEmpty) {
          final last = ref.read(periodicReviewLastObjectivesProvider);
          if (last.isNotEmpty) {
            state = state.copyWith(objectives: last);
          }
        }
    }
  }

  // ---------------------------------------------------------------------------
  // Objectives
  // ---------------------------------------------------------------------------

  void setObjectives(List<String> objectives) =>
      state = state.copyWith(objectives: objectives);

  // ---------------------------------------------------------------------------
  // Completion
  // ---------------------------------------------------------------------------

  /// Persists objectives + completion timestamp via the settings notifier and
  /// flips [PeriodicReviewState.isComplete]. Caller is responsible for
  /// navigating away after this resolves.
  ///
  /// Uses a single batched write so a partial failure cannot leave the user
  /// with persisted objectives but no completion timestamp — which would
  /// re-prompt the wizard and overwrite the half-saved objectives.
  Future<void> completeReview() async {
    final cleaned = state.objectives
        .map((o) => o.trim())
        .where((o) => o.isNotEmpty)
        .toList();
    final settings = ref.read(periodicReviewSettingsProvider.notifier);
    await settings.completeReviewWith(cleaned);
    state = state.copyWith(isComplete: true);
  }
}

