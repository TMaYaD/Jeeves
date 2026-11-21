/// Which Habits a Habit may be anchored to without closing a loop.
///
/// Pure Dart. The rule is the one `HabitDao.setAnchor` enforces, so a
/// candidate offered here is never refused there. Stack order is not decided
/// here — it is `habitStackChains`.
library;

import '../../database/gtd_database.dart' show Habit;

/// The Habits [habit] may be anchored to, after or before.
///
/// A candidate is active ([activeIds]), is not [habit] itself, and does not
/// lead back to [habit]: following the candidate's own anchors through
/// [allHabits] (paused ones included, as the store does) never reaches
/// [habit]. [habit]'s own current anchor is ignored, because choosing a new
/// one replaces it. Both "after" and "before" close a loop through the same
/// chain, so one list serves both.
List<Habit> anchorCandidates(
  Habit habit,
  Iterable<Habit> allHabits,
  Set<String> activeIds,
) {
  final byId = {for (final other in allHabits) other.id: other};
  bool reachesHabit(Habit start) {
    var current = start;
    final seen = <String>{};
    while (true) {
      if (current.id == habit.id) return true;
      if (!seen.add(current.id)) return false;
      final next = byId[current.anchorHabitId];
      if (next == null) return false;
      current = next;
    }
  }

  return [
    for (final other in byId.values)
      if (other.id != habit.id &&
          activeIds.contains(other.id) &&
          !reachesHabit(other))
        other,
  ];
}
