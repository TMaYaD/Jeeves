import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/planning/steps/scheduled_review_step.dart';
import 'package:jeeves/widgets/outcome_row.dart';

void main() {
  testWidgets('scheduled Outcomes use read-only rows in due-date order', (
    tester,
  ) async {
    Todo todo(String id, DateTime? due) => Todo(
      id: id,
      title: id,
      userId: 'local',
      createdAt: DateTime(2030),
      intent: 'next',
      dueDate: due,
      timeEstimate: 30,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          focusSessionPlanningSelectedTasksProvider.overrideWith(
            (_) => Stream.value([
              todo('No due date', null),
              todo('Later', DateTime(2030, 3, 16)),
              todo('Earlier', DateTime(2030, 3, 15)),
            ]),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ScheduledReviewStep())),
      ),
    );
    await tester.pump();
    final rows = tester
        .widgetList<OutcomeRow>(find.byType(OutcomeRow))
        .toList();
    expect(rows.map((row) => row.title), ['Earlier', 'Later', 'No due date']);
    expect(rows.every((row) => row.onTap == null), isTrue);
    expect(
      find.descendant(
        of: find.byType(OutcomeRow),
        matching: find.byType(InkWell),
      ),
      findsNothing,
    );
  });
}
