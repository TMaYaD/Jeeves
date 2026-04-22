/// Sprint timer state management for Epic 3 / Epic 4 (Issue #49).
///
/// A sprint is a 20-minute focus block tied to a single task.  When the
/// timer expires an interstitial forces the user to pick Complete, Extend,
/// or Defer before any break can begin.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../models/todo.dart' show GtdState;
import 'auth_provider.dart';
import 'database_provider.dart';

export '../database/gtd_database.dart' show Todo;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Duration of a single focus sprint in seconds.
const int kSprintDurationSeconds = 20 * 60;

/// Duration of the break between sprints in seconds.
const int kBreakDurationSeconds = 3 * 60;

// ---------------------------------------------------------------------------
// Phase enum
// ---------------------------------------------------------------------------

enum SprintPhase {
  /// No sprint is active.
  idle,

  /// Countdown is running.
  running,

  /// Timer hit zero — user must resolve before continuing.
  expired,

  /// User is on a break between sprints.
  onBreak,
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class SprintState {
  const SprintState({
    required this.phase,
    this.activeTask,
    this.remainingSeconds = kSprintDurationSeconds,
    this.sprintCount = 0,
  });

  final SprintPhase phase;

  /// The task currently being worked on (null when idle or on break).
  final Todo? activeTask;

  /// Seconds left in the current countdown (sprint or break).
  final int remainingSeconds;

  /// How many complete sprints have been run for [activeTask] this session.
  final int sprintCount;

  SprintState copyWith({
    SprintPhase? phase,
    Todo? activeTask,
    bool clearActiveTask = false,
    int? remainingSeconds,
    int? sprintCount,
  }) {
    return SprintState(
      phase: phase ?? this.phase,
      activeTask: clearActiveTask ? null : (activeTask ?? this.activeTask),
      remainingSeconds: remainingSeconds ?? this.remainingSeconds,
      sprintCount: sprintCount ?? this.sprintCount,
    );
  }
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

class SprintNotifier extends Notifier<SprintState> {
  Timer? _ticker;

  @override
  SprintState build() => const SprintState(phase: SprintPhase.idle);

  /// Starts a 20-minute sprint for [task].
  ///
  /// Transitions the task to `in_progress` via the DAO (which sets
  /// [inProgressSince]) so time is logged accurately when the sprint ends.
  Future<void> startSprint(Todo task) async {
    _cancelTicker();
    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);

    if (task.state != GtdState.inProgress.value) {
      await db.todoDao.transitionState(task.id, userId, GtdState.inProgress);
    }

    final updated = await db.todoDao.getTodo(task.id, userId);
    state = SprintState(
      phase: SprintPhase.running,
      activeTask: updated ?? task,
      remainingSeconds: kSprintDurationSeconds,
      sprintCount: state.activeTask?.id == task.id ? state.sprintCount : 0,
    );
    _startTicker();
  }

  /// Resolves the expired sprint as "Complete": logs time and marks task done.
  Future<void> resolveComplete() async {
    final task = state.activeTask;
    if (task == null) return;
    _cancelTicker();

    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    await db.todoDao.transitionState(task.id, userId, GtdState.done);

    state = SprintState(
      phase: SprintPhase.onBreak,
      remainingSeconds: kBreakDurationSeconds,
      sprintCount: state.sprintCount + 1,
    );
    _startTicker();
  }

  /// Resolves the expired sprint as "Extend": allocates another 20-min block.
  ///
  /// The task stays in `in_progress`; the caller is responsible for prompting
  /// the user to punt the lowest-priority remaining task via [puntTask].
  Future<void> resolveExtend() async {
    if (state.activeTask == null) return;
    _cancelTicker();

    state = state.copyWith(
      phase: SprintPhase.running,
      remainingSeconds: kSprintDurationSeconds,
      sprintCount: state.sprintCount + 1,
    );
    _startTicker();
  }

  /// Punts [task] from today's plan to make room for an extended sprint.
  Future<void> puntTask(Todo task) async {
    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    await db.todoDao.unselectFromToday(task.id, userId);
  }

  /// Resolves the expired sprint as "Defer": logs partial time and parks task.
  Future<void> resolveDefer() async {
    final task = state.activeTask;
    if (task == null) return;
    _cancelTicker();

    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    await db.todoDao.resolveSprintDefer(task.id, userId);

    state = const SprintState(phase: SprintPhase.idle);
  }

  /// Ends the current break and returns to idle.
  void endBreak() {
    _cancelTicker();
    state = const SprintState(phase: SprintPhase.idle);
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _startTicker() {
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _cancelTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _tick() {
    final remaining = state.remainingSeconds - 1;
    if (remaining <= 0) {
      _cancelTicker();
      if (state.phase == SprintPhase.running) {
        state = state.copyWith(
          phase: SprintPhase.expired,
          remainingSeconds: 0,
        );
      } else if (state.phase == SprintPhase.onBreak) {
        state = const SprintState(phase: SprintPhase.idle);
      }
    } else {
      state = state.copyWith(remainingSeconds: remaining);
    }
  }

  @override
  void dispose() {
    _cancelTicker();
    super.dispose();
  }
}

final sprintProvider = NotifierProvider<SprintNotifier, SprintState>(
  SprintNotifier.new,
);
