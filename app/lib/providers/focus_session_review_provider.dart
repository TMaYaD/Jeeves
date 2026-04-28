/// Provider and state for the focus session review ritual (PR K).
///
/// The review screen calls [FocusSessionReviewNotifier.initFromSession] once
/// to load session tasks, then drives [setDisposition] per task until all
/// pending tasks are reviewed.  [submitReview] commits dispositions to the DB,
/// closes the session, and resets [focusSessionPlanningCompletionNotifier].
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../models/review_disposition.dart';
import 'database_provider.dart';
import 'focus_session_planning_provider.dart';

export '../database/gtd_database.dart' show Todo;
export '../models/review_disposition.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class FocusSessionReviewState {
  const FocusSessionReviewState({
    this.sessionId,
    this.sessionTasks = const [],
    this.dispositions = const {},
    this.isSubmitting = false,
  });

  final String? sessionId;
  final List<Todo> sessionTasks;

  /// Maps task ID → chosen [ReviewDisposition] (pending tasks only).
  final Map<String, ReviewDisposition> dispositions;
  final bool isSubmitting;

  List<Todo> get pendingTasks =>
      sessionTasks.where((t) => t.doneAt == null).toList();

  List<Todo> get completedTasks =>
      sessionTasks.where((t) => t.doneAt != null).toList();

  /// True when every pending task has been assigned a disposition.
  bool get allPendingReviewed =>
      pendingTasks.isEmpty ||
      pendingTasks.every((t) => dispositions.containsKey(t.id));

  FocusSessionReviewState copyWith({
    String? sessionId,
    List<Todo>? sessionTasks,
    Map<String, ReviewDisposition>? dispositions,
    bool? isSubmitting,
  }) =>
      FocusSessionReviewState(
        sessionId: sessionId ?? this.sessionId,
        sessionTasks: sessionTasks ?? this.sessionTasks,
        dispositions: dispositions ?? this.dispositions,
        isSubmitting: isSubmitting ?? this.isSubmitting,
      );
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

final focusSessionReviewProvider = NotifierProvider<FocusSessionReviewNotifier,
    FocusSessionReviewState>(FocusSessionReviewNotifier.new);

class FocusSessionReviewNotifier extends Notifier<FocusSessionReviewState> {
  @override
  FocusSessionReviewState build() => const FocusSessionReviewState();

  GtdDatabase get _db => ref.read(databaseProvider);

  /// Loads session tasks and initialises the review state.
  ///
  /// Must be called once when the review screen mounts.
  Future<void> initFromSession(String sessionId) async {
    final tasks =
        await _db.focusSessionDao.watchSessionTasks(sessionId).first;
    state = state.copyWith(
      sessionId: sessionId,
      sessionTasks: tasks,
      dispositions: const {},
    );
  }

  /// Records [disposition] for [taskId] in the in-memory map.
  void setDisposition(String taskId, ReviewDisposition disposition) {
    state = state.copyWith(
      dispositions: {...state.dispositions, taskId: disposition},
    );
  }

  /// Commits all dispositions to the DB, closes the session, and resets the
  /// planning completion flag so the next planning ritual starts fresh.
  ///
  /// Throws [StateError] if called before [initFromSession] or when not all
  /// pending tasks have been assigned a disposition.
  Future<void> submitReview({DateTime? now}) async {
    if (state.sessionId == null) {
      throw StateError('submitReview called before initFromSession');
    }
    if (!state.allPendingReviewed) {
      throw StateError('Not all pending tasks have been reviewed');
    }

    state = state.copyWith(isSubmitting: true);
    try {
      // Build the string map expected by the DAO (done tasks excluded).
      final stringDispositions = {
        for (final entry in state.dispositions.entries)
          entry.key: entry.value.dbValue,
      };

      await _db.focusSessionDao.reviewAndCloseSession(
        sessionId: state.sessionId!,
        dispositions: stringDispositions,
        now: now,
      );

      focusSessionPlanningCompletionNotifier.value = false;
    } finally {
      state = state.copyWith(isSubmitting: false);
    }
  }
}
