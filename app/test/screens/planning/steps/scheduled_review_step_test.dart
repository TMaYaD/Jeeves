import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/day_timeline_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/planning/steps/scheduled_review_step.dart';
import 'package:jeeves/widgets/day_timeline/day_timeline.dart';
import 'package:jeeves/widgets/outcome_row.dart';

/// The planning draft without its database preloads: this test renders one step.
class _PlanningWithNoDatabase extends FocusSessionPlanningNotifier {
  @override
  FocusSessionPlanningState build() => const FocusSessionPlanningState();
}

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
          planningTimeContextsProvider.overrideWith((_) async => const {}),
          planningSprintMarksProvider.overrideWith((_) async => const []),
          dayTimelineSettingsProvider
              .overrideWithValue(const DayTimelineSettings()),
          focusSessionPlanningProvider
              .overrideWith(_PlanningWithNoDatabase.new),
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

  testWidgets('the timeline lays out the Plan in Plan order, not due-date order',
      (tester) async {
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
          planningTimeContextsProvider.overrideWith((_) async => const {}),
          planningSprintMarksProvider.overrideWith((_) async => const []),
          dayTimelineSettingsProvider
              .overrideWithValue(const DayTimelineSettings()),
          focusSessionPlanningProvider
              .overrideWith(_PlanningWithNoDatabase.new),
          focusSessionPlanningSelectedTasksProvider.overrideWith(
            (_) => Stream.value([
              todo('first in Plan', DateTime(2030, 3, 16)),
              todo('second in Plan', DateTime(2030, 3, 15)),
            ]),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ScheduledReviewStep())),
      ),
    );
    await tester.pump();
    final timeline = tester.widget<DayTimeline>(find.byType(DayTimeline));
    expect(timeline.entries.map((e) => e.outcomeId),
        ['first in Plan', 'second in Plan']);
    final rows = tester.widgetList<OutcomeRow>(find.byType(OutcomeRow));
    expect(rows.map((r) => r.title), ['second in Plan', 'first in Plan']);
  });

  group('wide layout', () {
    Future<void> pumpAtWidth(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            planningTimeContextsProvider.overrideWith((_) async => const {}),
            planningSprintMarksProvider.overrideWith((_) async => const []),
            dayTimelineSettingsProvider
                .overrideWithValue(const DayTimelineSettings()),
            focusSessionPlanningProvider
                .overrideWith(_PlanningWithNoDatabase.new),
            focusSessionPlanningSelectedTasksProvider.overrideWith(
              (_) => Stream.value([
                Todo(
                  id: 'a',
                  title: 'Write the report',
                  userId: 'local',
                  createdAt: DateTime(2030),
                  intent: 'next',
                  timeEstimate: 30,
                ),
              ]),
            ),
          ],
          child:
              const MaterialApp(home: Scaffold(body: ScheduledReviewStep())),
        ),
      );
      await tester.pump();
    }

    testWidgets('a wide screen shows the Plan rows beside the timeline',
        (tester) async {
      await pumpAtWidth(tester, 1200);
      expect(find.byKey(const ValueKey('plan-timeline-two-panes')),
          findsOneWidget);
      final row = tester.getTopLeft(find.byType(OutcomeRow));
      final timeline = tester.getTopLeft(find.byType(DayTimeline));
      expect(row.dx, lessThan(timeline.dx));
      expect(find.text('Start Day'), findsOneWidget);
    });

    testWidgets('a narrow screen stacks the timeline above the Plan rows',
        (tester) async {
      await pumpAtWidth(tester, 400);
      expect(find.byKey(const ValueKey('plan-timeline-stacked')),
          findsOneWidget);
      final row = tester.getTopLeft(find.byType(OutcomeRow));
      final timeline = tester.getTopLeft(find.byType(DayTimeline));
      expect(timeline.dy, lessThan(row.dy));
    });
  });
}
