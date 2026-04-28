import 'todo.dart';

/// Thrown when an attempted GTD state transition is not permitted.
class InvalidStateTransitionException implements Exception {
  const InvalidStateTransitionException({
    required this.from,
    required this.to,
  });

  final GtdState from;
  final GtdState to;

  @override
  String toString() =>
      'InvalidStateTransitionException: cannot transition from '
      '${from.value} to ${to.value}';
}

/// Enforces the GTD state machine at the model layer.
///
/// Only transitions listed in [allowedTransitions] are valid.
/// Call [validate] before any state change; it throws
/// [InvalidStateTransitionException] on invalid moves.
class GtdStateMachine {
  GtdStateMachine._();

  /// The complete set of valid state transitions.
  ///
  /// `done` is no longer a GTD state — completion is recorded via `done_at`.
  /// `inProgress` was retired in migration 0019 — the focused task is now
  /// tracked by `focus_sessions.current_task_id`. PR J removes this file.
  static const Map<GtdState, Set<GtdState>> allowedTransitions = {};

  /// Returns true when the [from] → [to] transition is permitted.
  static bool isValid(GtdState from, GtdState to) =>
      allowedTransitions[from]?.contains(to) ?? false;

  /// Throws [InvalidStateTransitionException] if [from] → [to] is not
  /// a permitted transition.
  static void validate(GtdState from, GtdState to) {
    if (!isValid(from, to)) {
      throw InvalidStateTransitionException(from: from, to: to);
    }
  }
}
