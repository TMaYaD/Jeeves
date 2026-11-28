import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/day_timeline_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/timeboxed_limit_provider.dart';
import 'package:jeeves/screens/planning/steps/scheduled_review_step.dart';
import 'package:jeeves/widgets/day_timeline/day_timeline.dart';
import 'package:jeeves/widgets/outcome_row.dart';

/// The planning draft without its database preloads: this test renders one step.
class _PlanningWithNoDatabase extends FocusSessionPlanningNotifier {
  @override
  FocusSessionPlanningState build() => const FocusSessionPlanningState();
}

/// The limit edge drawn over a day timeline tile's bottom, or null when the
/// tile has none.
///
/// A Timeboxed Outcome's tile draws the heavier edge (issue #923); every
/// other tile keeps the ordinary one.
bool _hasLimitEdge(WidgetTester tester, String outcomeId) =>
    find.byKey(Key('day_timeline_limit_edge_${outcomeId}_1')).evaluate().isNotEmpty;

/// Pumps until [done] holds, or gives up after ten frames.
///
/// Which Outcomes are Timeboxed reaches the step through a stream, so the
/// state lands a frame or two after the first build. The test waits for the
/// state rather than counting the frames it takes.
Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 10 && !done(); i++) {
    await tester.pump();
  }
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
          planningTimeWindowsProvider.overrideWith((_) async => const {}),
          planningSprintMarksProvider.overrideWith((_) async => const []),
          // Which Outcomes are Timeboxed (issue #923). Stubbed: a live Drift
          // watch would outlive the test.
          currentTimeboxedProvider
              .overrideWith((_) => Stream.value(const <String, bool>{})),
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
          planningTimeWindowsProvider.overrideWith((_) async => const {}),
          planningSprintMarksProvider.overrideWith((_) async => const []),
          // Which Outcomes are Timeboxed (issue #923). Stubbed: a live Drift
          // watch would outlive the test.
          currentTimeboxedProvider
              .overrideWith((_) => Stream.value(const <String, bool>{})),
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

  testWidgets('a Timeboxed Outcome carries the limit edge on its tile', (
    tester,
  ) async {
    // The planning timeline's tile of a Timeboxed Outcome draws the heavier
    // bottom edge (issue #923). The state comes from the Action, so the step
    // has to hand it to the timeline: this is that wiring.
    Todo todo(String id) => Todo(
      id: id,
      title: id,
      userId: 'local',
      createdAt: DateTime(2030),
      intent: 'next',
      timeEstimate: 30,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          planningTimeContextsProvider.overrideWith((_) async => const {}),
          planningTimeWindowsProvider.overrideWith((_) async => const {}),
          planningSprintMarksProvider.overrideWith((_) async => const []),
          currentTimeboxedProvider
              .overrideWith((_) => Stream.value(const {'bounded': true})),
          dayTimelineSettingsProvider
              .overrideWithValue(const DayTimelineSettings()),
          focusSessionPlanningProvider
              .overrideWith(_PlanningWithNoDatabase.new),
          focusSessionPlanningSelectedTasksProvider.overrideWith(
            (_) => Stream.value([todo('bounded'), todo('open')]),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ScheduledReviewStep())),
      ),
    );
    await tester.pump();
    await _pumpUntil(tester, () => _hasLimitEdge(tester, 'bounded'));

    final timeline = tester.widget<DayTimeline>(find.byType(DayTimeline));
    expect(timeline.entries.map((e) => e.isTimeboxed), [true, false]);
    expect(_hasLimitEdge(tester, 'bounded'), isTrue);
    expect(_hasLimitEdge(tester, 'open'), isFalse);
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
            planningTimeWindowsProvider.overrideWith((_) async => const {}),
            planningSprintMarksProvider.overrideWith((_) async => const []),
            // Which Outcomes are Timeboxed (issue #923). Stubbed: a live Drift
            // watch would outlive the test.
            currentTimeboxedProvider
                .overrideWith((_) => Stream.value(const <String, bool>{})),
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
