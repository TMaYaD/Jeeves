import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/widgets/app_title_bar/action_budget.dart';

/// Pure maths behind the bar's slot allocation. Deliberately
/// exercised without pumping a widget: the budget is a function of the
/// breakpoint, never of measured available width, so it is testable as
/// arithmetic and stays deterministic across devices.
void main() {
  group('actionBudget', () {
    test('phone widths get 3 slots', () {
      expect(actionBudget(0), 3);
      expect(actionBudget(375), 3);
      expect(actionBudget(599), 3);
      expect(actionBudget(599.9), 3);
    });

    test('mid widths get 4 slots', () {
      expect(actionBudget(600), 4);
      expect(actionBudget(800), 4);
      expect(actionBudget(1023), 4);
      expect(actionBudget(1023.9), 4);
    });

    test('desktop widths get 5 slots', () {
      expect(actionBudget(1024), 5);
      expect(actionBudget(1440), 5);
      expect(actionBudget(4000), 5);
    });
  });

  group('splitActions — everything fits', () {
    test('no actions, no pinned', () {
      final split =
          splitActions(budget: 3, actionCount: 0, hasPinned: false);
      expect(split.visible, 0);
      expect(split.hasOverflow, isFalse);
    });

    test('no actions, pinned', () {
      final split = splitActions(budget: 3, actionCount: 0, hasPinned: true);
      expect(split.visible, 0);
      expect(split.hasOverflow, isFalse);
    });

    test('phone: two actions + pinned exactly fill the budget — no overflow',
        () {
      final split = splitActions(budget: 3, actionCount: 2, hasPinned: true);
      expect(split.visible, 2,
          reason: 'owner ruling: [Action 2][Action 1][Capture], no ⋮');
      expect(split.hasOverflow, isFalse);
    });

    test('phone: three actions without a pinned slot still fit', () {
      final split = splitActions(budget: 3, actionCount: 3, hasPinned: false);
      expect(split.visible, 3);
      expect(split.hasOverflow, isFalse);
    });

    test('desktop: four actions + pinned fill the budget', () {
      final split = splitActions(budget: 5, actionCount: 4, hasPinned: true);
      expect(split.visible, 4);
      expect(split.hasOverflow, isFalse);
    });
  });

  group('splitActions — overflowing', () {
    test('phone: three actions + pinned leave one visible and a ⋮', () {
      final split = splitActions(budget: 3, actionCount: 3, hasPinned: true);
      expect(split.visible, 1,
          reason: 'owner ruling: [Action 1][Capture][⋮ → Action 2, Action 3]');
      expect(split.hasOverflow, isTrue);
    });

    test('phone: four actions without pinned leave two visible and a ⋮', () {
      final split = splitActions(budget: 3, actionCount: 4, hasPinned: false);
      expect(split.visible, 2);
      expect(split.hasOverflow, isTrue);
    });

    test('mid: four actions + pinned leave two visible and a ⋮', () {
      final split = splitActions(budget: 4, actionCount: 4, hasPinned: true);
      expect(split.visible, 2);
      expect(split.hasOverflow, isTrue);
    });

    test('desktop: six actions + pinned leave three visible and a ⋮', () {
      final split = splitActions(budget: 5, actionCount: 6, hasPinned: true);
      expect(split.visible, 3);
      expect(split.hasOverflow, isTrue);
    });

    test('visible count never goes negative on a starved budget', () {
      final split = splitActions(budget: 1, actionCount: 3, hasPinned: true);
      expect(split.visible, 0);
      expect(split.hasOverflow, isTrue,
          reason: 'the pinned slot survives; every page action overflows');
    });
  });
}
