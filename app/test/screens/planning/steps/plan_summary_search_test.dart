/// Widget tests for search on the Plan Summary step (#696).
///
/// Harness mirrors [plan_summary_peek_test.dart]: the list providers are
/// overridden with values over in-memory lists, so no live Drift `watch()` runs
/// under fake time. The Up Next and selected/skipped providers are streams; the
/// off-Up-Next provider is a plain provider, as in production.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/planning/steps/plan_summary_step.dart';
import 'package:jeeves/widgets/outcome_peek_sheet.dart';

import '../../../test_helpers.dart';

Todo _todo(String id, String title, {String intent = 'next'}) {
  final now = DateTime.now();
  return Todo(
    id: id,
    title: title,
    intent: intent,
    clarified: true,
    createdAt: now,
    updatedAt: now,
    userId: 'local',
    timeEstimate: 30,
  );
}

final _upNext = [
  _todo('n1', 'Write report'),
  _todo('n2', 'Call the plumber'),
];
final _offUpNext = <OffUpNextCandidate>[
  (todo: _todo('s1', 'Report on garden', intent: 'maybe'),
      reason: OffUpNextReason.someday),
  (todo: _todo('w1', 'Chase REPORT sign-off'),
      reason: OffUpNextReason.waitingFor),
  (todo: _todo('s2', 'Learn the banjo', intent: 'maybe'),
      reason: OffUpNextReason.someday),
];

Widget _harness(GtdDatabase db) {
  final everything = [..._upNext, ..._offUpNext.map((c) => c.todo)];
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      nextForFocusSessionPlanningProvider.overrideWith((ref) {
        final s = ref.watch(focusSessionPlanningProvider);
        final taken = {...s.reviewedTaskIds, ...s.pendingSelectedTaskIds};
        return Stream.value(
            _upNext.where((t) => !taken.contains(t.id)).toList());
      }),
      focusSessionPlanningSelectedTasksProvider.overrideWith((ref) {
        final ids = ref.watch(focusSessionPlanningProvider
            .select((s) => s.pendingSelectedTaskIds));
        return Stream.value(
            everything.where((t) => ids.contains(t.id)).toList());
      }),
      skippedNextForFocusSessionPlanningProvider.overrideWith((ref) {
        final s = ref.watch(focusSessionPlanningProvider);
        final skipped = s.reviewedTaskIds
            .where((id) => !s.pendingSelectedTaskIds.contains(id));
        return Stream.value(
            everything.where((t) => skipped.contains(t.id)).toList());
      }),
      offUpNextForFocusSessionPlanningProvider.overrideWith((ref) {
        final s = ref.watch(focusSessionPlanningProvider);
        return _offUpNext
            .where((c) => !s.pendingSelectedTaskIds.contains(c.todo.id))
            .toList();
      }),
    ],
    child: const MaterialApp(home: Scaffold(body: PlanSummaryStep())),
  );
}

Future<void> _pump(WidgetTester tester, GtdDatabase db) async {
  await tester.pumpWidget(_harness(db));
  await tester.pumpAndSettle();
}

Future<void> _search(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pumpAndSettle();
}

FocusSessionPlanningState _state(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(PlanSummaryStep)))
        .read(focusSessionPlanningProvider);

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() => db = GtdDatabase(NativeDatabase.memory()));
  tearDown(() async => db.close());

  testWidgets('shows Up Next matches, then a separate Not in Up Next group',
      (tester) async {
    await _pump(tester, db);
    await _search(tester, 'report');

    expect(find.text('UP NEXT (1)'), findsOneWidget);
    expect(find.text('NOT IN UP NEXT (2)'), findsOneWidget);
    expect(find.text('Write report'), findsOneWidget);
    expect(find.text('Report on garden'), findsOneWidget);
    expect(find.text('Chase REPORT sign-off'), findsOneWidget);
    expect(find.text('Call the plumber'), findsNothing);
    expect(find.text('Learn the banjo'), findsNothing);
    expect(find.text('Someday'), findsOneWidget);
    expect(find.text('Waiting For'), findsOneWidget);

    final upNextY = tester.getTopLeft(find.text('Write report')).dy;
    final groupY = tester.getTopLeft(find.text('NOT IN UP NEXT (2)')).dy;
    expect(upNextY, lessThan(groupY));
  });

  testWidgets('second-group rows offer Select but no Skip', (tester) async {
    await _pump(tester, db);
    await _search(tester, 'banjo');

    expect(find.byTooltip('Select for today'), findsOneWidget);
    expect(find.byTooltip('Skip for today'), findsNothing);
  });

  testWidgets('Select on a Someday result plans it and clearing restores',
      (tester) async {
    await _pump(tester, db);
    await _search(tester, 'banjo');

    await tester.tap(find.byTooltip('Select for today'));
    await tester.pumpAndSettle();

    expect(_state(tester).pendingSelectedTaskIds, ['s2']);
    expect(find.text('No matches.'), findsOneWidget);
    expect(find.textContaining('1 task · 30m planned'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();

    expect(find.text('TODAY\'S PLAN (1)'), findsOneWidget);
    expect(find.text('UP NEXT (2)'), findsOneWidget);
    expect(find.text('Learn the banjo'), findsOneWidget);
  });

  testWidgets('tapping a result opens the peek sheet', (tester) async {
    await _pump(tester, db);
    await _search(tester, 'banjo');

    await tester.tap(find.text('Learn the banjo'));
    await tester.pumpAndSettle();

    expect(find.byType(OutcomePeekSheet), findsOneWidget);
    expect(_state(tester).pendingSelectedTaskIds, isEmpty);
  });

  testWidgets('long-press on a result does not enter multi-select',
      (tester) async {
    await _pump(tester, db);
    await _search(tester, 'report');

    await tester.longPress(find.text('Write report'));
    await tester.pumpAndSettle();

    expect(find.text('1 selected'), findsNothing);
  });

  testWidgets('the field is disabled while multi-select is active',
      (tester) async {
    await _pump(tester, db);
    await tester.longPress(find.text('Write report'));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
  });

  testWidgets('the default view does not read the off-Up-Next provider',
      (tester) async {
    var reads = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        nextForFocusSessionPlanningProvider
            .overrideWith((_) => Stream.value(_upNext)),
        focusSessionPlanningSelectedTasksProvider
            .overrideWith((_) => Stream.value(const <Todo>[])),
        skippedNextForFocusSessionPlanningProvider
            .overrideWith((_) => Stream.value(const <Todo>[])),
        offUpNextForFocusSessionPlanningProvider.overrideWith((_) {
          reads++;
          return const <OffUpNextCandidate>[];
        }),
      ],
      child: const MaterialApp(home: Scaffold(body: PlanSummaryStep())),
    ));
    await tester.pumpAndSettle();

    expect(reads, 0);
    expect(find.text('UP NEXT (2)'), findsOneWidget);
  });
}
