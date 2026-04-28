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
  /// `done` is no longer a GTD state — completion is recorded via `done_at`
  /// on the todo row (see TodoDao.markDone). `inProgress` remains until PR I.
  /// `waitingFor` is no longer a GTD state — the Waiting For list is sourced
  /// from the `waiting_for` text column (see TodoDao.watchWaitingFor).
  static const Map<GtdState, Set<GtdState>> allowedTransitions = {
    GtdState.nextAction: {GtdState.inProgress},
    GtdState.inProgress: {},
  };

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
