/// Routing destination for a clarification step.
///
/// Unifies the inbox-clarify and re-clarification review surfaces under one
/// vocabulary. [TodoDao.applyRouting] uses this to decide which columns on
/// `todos` to write or leave alone for each (from, to) transition.
enum RoutingKind {
  nextAction,
  waitingFor,
  maybe,
  done,
  trash,
}
