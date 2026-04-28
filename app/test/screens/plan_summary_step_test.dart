/// Widget tests for [PlanSummaryStep] — verifies that tasks remain in their
/// original positions when selected or skipped (Issue #227).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/planning/steps/plan_summary_step.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Todo _todo(String id, String title) => Todo(
      id: id,
      title: title,
      notes: null,
      doneAt: null,
      priority: null,
      dueDate: null,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: null,
      clarified: true,
      intent: 'next',
      timeEstimate: null,
      energyLevel: null,
      captureSource: null,
      locationId: null,
      userId: 'local',
      timeSpentMinutes: 0,
    );

/// Fake notifier that returns a fixed [FocusSessionPlanningState] so tests
/// can pre-set selection/skip state without needing database access.
///
/// Overriding [build] replaces the parent's implementation entirely, so the
/// library-private [_preloadRolloverIds] microtask is never scheduled.
class _FakePlanningNotifier extends FocusSessionPlanningNotifier {
  _FakePlanningNotifier(this._initial);

  final FocusSessionPlanningState _initial;

  @override
  FocusSessionPlanningState build() => _initial;
}

Widget _buildStep({
  required List<Todo> allTasks,
  FocusSessionPlanningState? planningState,
}) {
  final state = planningState ?? const FocusSessionPlanningState();
  final notifier = _FakePlanningNotifier(state);

  // Build selected-task list from state for the capacity bar.
  final selectedTodos = allTasks
      .where((t) => state.pendingSelectedTaskIds.contains(t.id))
      .toList();

  return ProviderScope(
    overrides: [
      focusSessionPlanningProvider.overrideWith(() => notifier),
      allNextActionsForPlanningReviewProvider
          .overrideWith((_) => Stream.value(allTasks)),
      focusSessionPlanningSelectedTasksProvider
          .overrideWith((_) => Stream.value(selectedTodos)),
    ],
    child: const MaterialApp(
      home: Scaffold(body: PlanSummaryStep()),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('PlanSummaryStep', () {
    testWidgets('renders all tasks in original order', (tester) async {
      final tasks = [
        _todo('a', 'Alpha'),
        _todo('b', 'Beta'),
        _todo('c', 'Gamma'),
      ];

      await tester.pumpWidget(_buildStep(allTasks: tasks));
      await tester.pump();

      // All three titles visible.
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Gamma'), findsOneWidget);

      // Verify vertical ordering: Alpha above Beta above Gamma.
      final alphaY = tester.getTopLeft(find.text('Alpha')).dy;
      final betaY = tester.getTopLeft(find.text('Beta')).dy;
      final gammaY = tester.getTopLeft(find.text('Gamma')).dy;
      expect(alphaY, lessThan(betaY));
      expect(betaY, lessThan(gammaY));
    });

    testWidgets('tasks do not move after one is selected', (tester) async {
      final tasks = [
        _todo('a', 'Alpha'),
        _todo('b', 'Beta'),
        _todo('c', 'Gamma'),
      ];

      // Record positions before any selection.
      await tester.pumpWidget(_buildStep(allTasks: tasks));
      await tester.pump();

      final betaYBefore = tester.getTopLeft(find.text('Beta')).dy;
      final gammaYBefore = tester.getTopLeft(find.text('Gamma')).dy;

      // Simulate state after Alpha is selected.
      await tester.pumpWidget(_buildStep(
        allTasks: tasks,
        planningState: const FocusSessionPlanningState(
          pendingSelectedTaskIds: ['a'],
        ),
      ));
      await tester.pump();

      // Beta and Gamma must stay at the same vertical position.
      expect(tester.getTopLeft(find.text('Beta')).dy, betaYBefore);
      expect(tester.getTopLeft(find.text('Gamma')).dy, gammaYBefore);

      // Alpha is still visible in the list (not moved to a separate section).
      expect(find.text('Alpha'), findsOneWidget);
    });

    testWidgets('selected task shows green tint card', (tester) async {
      final tasks = [_todo('a', 'Alpha')];

      await tester.pumpWidget(_buildStep(
        allTasks: tasks,
        planningState: const FocusSessionPlanningState(
          pendingSelectedTaskIds: ['a'],
        ),
      ));
      await tester.pump();

      // The Card widget for a selected task should have the green background.
      final card = tester.widget<Card>(find.byType(Card).first);
      expect(card.color, const Color(0xFFF0FDF4));
    });

    testWidgets('skipped task retains original position', (tester) async {
      final tasks = [
        _todo('a', 'Alpha'),
        _todo('b', 'Beta'),
      ];

      await tester.pumpWidget(_buildStep(allTasks: tasks));
      await tester.pump();
      final betaYBefore = tester.getTopLeft(find.text('Beta')).dy;

      // Simulate state after Alpha is skipped.
      await tester.pumpWidget(_buildStep(
        allTasks: tasks,
        planningState: const FocusSessionPlanningState(
          reviewedTaskIds: ['a'],
        ),
      ));
      await tester.pump();

      expect(tester.getTopLeft(find.text('Beta')).dy, betaYBefore);
      expect(find.text('Alpha'), findsOneWidget);
    });

    testWidgets('footer summary counts selected and pending', (tester) async {
      final tasks = [
        _todo('a', 'Alpha'),
        _todo('b', 'Beta'),
        _todo('c', 'Gamma'),
      ];

      await tester.pumpWidget(_buildStep(
        allTasks: tasks,
        planningState: const FocusSessionPlanningState(
          pendingSelectedTaskIds: ['a'],
          reviewedTaskIds: ['b'],
        ),
      ));
      await tester.pump();

      // Footer: "1 selected · 1 pending · 1 skipped"
      expect(find.text('1 selected · 1 pending · 1 skipped'), findsOneWidget);
    });

    testWidgets('empty state shows no-tasks message', (tester) async {
      await tester.pumpWidget(_buildStep(allTasks: []));
      await tester.pump();

      expect(find.text('No tasks to review!'), findsOneWidget);
    });
  });
}
