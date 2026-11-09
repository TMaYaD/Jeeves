/// Journey: editing an Outcome from the Daily Planning peek (#698).
///
/// The real [PlanSummaryStep] over a real in-memory database — no stubbed
/// streams — so the card chip and the capacity summary are proven to follow a
/// saved edit. Live Drift watches are running, so the test pumps fixed
/// durations rather than `pumpAndSettle` (TESTING.md).
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/planning/steps/plan_summary_step.dart';

import '../test_helpers.dart';

Future<void> _insertOutcome(GtdDatabase db, String id, String title) =>
    db.into(db.todos).insert(TodosCompanion(
          id: Value(id),
          title: Value(title),
          intent: const Value('next'),
          clarified: const Value(true),
          userId: const Value('local'),
          createdAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ));

Future<void> _pumpFor(WidgetTester tester, [int steps = 4]) async {
  for (var i = 0; i < steps; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    await _insertOutcome(db, 'plan-me', 'Write the report');
    await _insertOutcome(db, 'up-next', 'Sort the garage');
    await db.tagDao.upsertTag(const TagsCompanion(
      id: Value('ctx-home'),
      name: Value('home'),
      type: Value('context'),
      userId: Value('local'),
    ));
  });
  tearDown(() async => db.close());

  testWidgets(
      'editing in the peek persists, shows on the card and capacity, and '
      'leaves planning state alone', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: Scaffold(body: PlanSummaryStep())),
    ));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(PlanSummaryStep)));
    container.read(focusSessionPlanningProvider.notifier).selectTask('plan-me');
    await _pumpFor(tester);
    final stateBefore = container.read(focusSessionPlanningProvider);
    final upNextBefore = (await tester
        .runAsync(() => db.todoDao.getTodo('up-next')))!;

    // Peek the Today's Plan card and set a time estimate.
    await tester.tap(find.text('Write the report'));
    await _pumpFor(tester);
    await tester.tap(find.byKey(const Key('outcome_peek_time')));
    await _pumpFor(tester);
    await tester.tap(find.text('10m').last);
    await _pumpFor(tester);

    // Edit notes, then close (flushes the field).
    await tester.enterText(
        find.byKey(const Key('outcome_peek_notes')), 'Draft by Friday');
    await tester.tap(find.byTooltip('Close'));
    await _pumpFor(tester);

    final planned = (await tester.runAsync(() => db.todoDao.getTodo('plan-me')))!;
    expect(planned.timeEstimate, 10);
    expect(planned.notes, 'Draft by Friday');
    expect(planned.lastClarifiedAt, isNotNull);

    // The card and the capacity total follow the saved estimate.
    expect(find.text('10m'), findsWidgets);
    expect(find.textContaining('10m planned'), findsOneWidget);

    // Peeking and editing never picked up, skipped or reviewed anything.
    final stateAfter = container.read(focusSessionPlanningProvider);
    expect(stateAfter.pendingSelectedTaskIds, stateBefore.pendingSelectedTaskIds);
    expect(stateAfter.reviewedTaskIds, stateBefore.reviewedTaskIds);

    // A context-tag-only edit is organising: no clarification stamp.
    await tester.tap(find.text('Sort the garage'));
    await _pumpFor(tester);
    await tester.tap(find.byKey(const Key('outcome_peek_add_context')));
    await _pumpFor(tester);
    await tester.tap(find.text('@home').last);
    await _pumpFor(tester);

    final tagged = await tester.runAsync(() => (db.select(db.todoTags)
          ..where((t) => t.todoId.equals('up-next')))
        .get());
    expect(tagged!.map((r) => r.tagId), ['ctx-home']);
    final upNextAfter =
        (await tester.runAsync(() => db.todoDao.getTodo('up-next')))!;
    expect(upNextAfter.lastClarifiedAt, upNextBefore.lastClarifiedAt);
  });
}
