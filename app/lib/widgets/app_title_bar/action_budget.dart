/// Slot arithmetic for [AppTitleBar] (ADR-0021).
///
/// The bar budgets its action buttons by **screen-width breakpoint**, never by
/// measured available width: a fixed budget is deterministic and unit-testable
/// where width-measuring creates layout feedback loops and per-device
/// surprises. Both functions here are pure — the widget reads the width once
/// and delegates.
library;

/// Total action buttons the bar may render at [width], counting the pinned
/// capture action and the ⋮ overflow button.
int actionBudget(double width) => width < 600 ? 3 : (width < 1024 ? 4 : 5);

/// How many page actions render in the bar, and whether a ⋮ is needed.
///
/// Page actions are held in priority order (index 0 = highest), so overflow
/// takes from the tail. The pinned action never overflows and always costs a
/// slot when present; the ⋮ costs a slot too, but only when something actually
/// overflows — when everything fits there is no ⋮ at all.
({int visible, bool hasOverflow}) splitActions({
  required int budget,
  required int actionCount,
  required bool hasPinned,
}) {
  final pinnedSlots = hasPinned ? 1 : 0;
  if (actionCount + pinnedSlots <= budget) {
    return (visible: actionCount, hasOverflow: false);
  }
  final visible = budget - pinnedSlots - 1;
  return (visible: visible < 0 ? 0 : visible, hasOverflow: true);
}
