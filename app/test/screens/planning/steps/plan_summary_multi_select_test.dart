/// Widget tests for the [PlanSummaryStep] multi-select flow (#247).
///
/// The three list streams ([nextForFocusSessionPlanningProvider],
/// [focusSessionPlanningSelectedTasksProvider], and
/// [skippedNextForFocusSessionPlanningProvider]) are overridden with
/// single-value streams over an in-memory todo source so the test does not
/// subscribe to drift's `StreamQueryStore` — that store leaves a pending
/// `markAsClosed` timer behind on widget-tree teardown, tripping
/// `!timersPending`. The overrides preserve the production filter logic so
/// task movement between sections (Up Next ↔ Today's Plan ↔ Skipped)
/// still flows through the real focusSessionPlanning state.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/planning/steps/plan_summary_step.dart';

import '../../../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

/// In-memory source of truth for the test's todo population. The harness
/// overrides this with the per-test list; consumers read it via
/// `ref.watch` so the stream-provider overrides re-emit when the planning
/// state changes (mutating reviewed/selected ids).
final _testTodosProvider = Provider<List<Todo>>((_) => const []);

Todo _todo({
  required String id,
  required String title,
  int? timeEstimate,
}) {
  final now = DateTime.now();
  return Todo(
    id: id,
    title: title,
    intent: 'next',
    clarified: true,
    createdAt: now,
    updatedAt: now,
    userId: 'local',
    timeEstimate: timeEstimate,
  );
}

Widget _harness(GtdDatabase db, List<Todo> todos) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      _testTodosProvider.overrideWith((_) => todos),
      // Up Next: next-action todos minus anything already reviewed.
      nextForFocusSessionPlanningProvider.overrideWith((ref) {
        final state = ref.watch(focusSessionPlanningProvider);
        final reviewed = {
          ...state.reviewedTaskIds,
          ...state.pendingSelectedTaskIds,
        };
        final all = ref.watch(_testTodosProvider);
        return Stream.value(
          all.where((t) => !reviewed.contains(t.id)).toList(),
        );
      }),
      // Today's Plan: pending selected, ordered by selection.
      focusSessionPlanningSelectedTasksProvider.overrideWith((ref) {
        final ids = ref.watch(
          focusSessionPlanningProvider
              .select((s) => s.pendingSelectedTaskIds),
        );
        final all = ref.watch(_testTodosProvider);
        final indexById = {for (var i = 0; i < ids.length; i++) ids[i]: i};
        final ordered = all.where((t) => ids.contains(t.id)).toList()
          ..sort((a, b) => indexById[a.id]!.compareTo(indexById[b.id]!));
        return Stream.value(ordered);
      }),
      // Skipped: reviewed but not selected.
      skippedNextForFocusSessionPlanningProvider
          .overrideWith((ref) {
        final state = ref.watch(focusSessionPlanningProvider);
        final skippedIds = state.reviewedTaskIds
            .where((id) => !state.pendingSelectedTaskIds.contains(id))
            .toSet();
        final all = ref.watch(_testTodosProvider);
        return Stream.value(
          all.where((t) => skippedIds.contains(t.id)).toList(),
        );
      }),
    ],
    child: const MaterialApp(
      home: Scaffold(body: PlanSummaryStep()),
    ),
  );
}

Future<void> _pumpStep(
  WidgetTester tester,
  GtdDatabase db,
  List<Todo> todos,
) async {
  await tester.pumpWidget(_harness(db, todos));
  await tester.pumpAndSettle();
}

Finder _cardWithTitle(String title) {
  return find.ancestor(
    of: find.text(title),
    matching: find.byType(Card),
  );
}

Future<void> _longPressCard(WidgetTester tester, String title) async {
  await tester.longPress(_cardWithTitle(title).first);
  await tester.pumpAndSettle();
}

Future<void> _tapCard(WidgetTester tester, String title) async {
  await tester.tap(_cardWithTitle(title).first);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(configureSqliteForTests);

  group('PlanSummaryStep — multi-select (#247)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets('long-press on a pending card enters selection mode',
        (tester) async {
      await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Task one', timeEstimate: 30),
        _todo(id: 't2', title: 'Task two', timeEstimate: 45),
        _todo(id: 't3', title: 'Task three'),
      ]);

      // No bar before long-press.
      expect(find.text('Add to Today'), findsNothing);

      await _longPressCard(tester, 'Task one');

      expect(find.text('1 selected'), findsOneWidget);
      expect(find.text('Add to Today'), findsOneWidget);
      // Preview overlay reflects the planned cost.
      expect(find.text('+30m planned'), findsOneWidget);
      // Trailing icon slot is hidden in selection mode.
      expect(find.byTooltip('Select for today'), findsNothing);
      expect(find.byTooltip('Skip for today'), findsNothing);
      // Leading checkbox visible on every pending card.
      expect(find.byType(Checkbox), findsNWidgets(3));
    });

    testWidgets('tap toggles selection while in mode', (tester) async {
      await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Task one', timeEstimate: 30),
        _todo(id: 't2', title: 'Task two', timeEstimate: 45),
      ]);

      await _longPressCard(tester, 'Task one');

      await _tapCard(tester, 'Task two');
      expect(find.text('2 selected'), findsOneWidget);
      expect(find.text('+1h 15m planned'), findsOneWidget);

      await _tapCard(tester, 'Task two');
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('Select all selects every visible pending task',
        (tester) async {
      await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Task one'),
        _todo(id: 't2', title: 'Task two'),
        _todo(id: 't3', title: 'Task three'),
      ]);

      await _longPressCard(tester, 'Task one');

      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();

      expect(find.text('3 selected'), findsOneWidget);
      expect(find.text('Select all'), findsNothing);
    });

    testWidgets(
        'Add to Today commits selected tasks, moves them to Today\'s Plan, '
        'and exits selection mode', (tester) async {
      await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Task one', timeEstimate: 30),
        _todo(id: 't2', title: 'Task two', timeEstimate: 45),
        _todo(id: 't3', title: 'Task three'),
      ]);

      // Before commit: pending section shows all three, no Today's Plan section.
      // Section labels are rendered upper-cased by [_SectionLabel].
      expect(find.text('UP NEXT (3)'), findsOneWidget);
      expect(find.textContaining('TODAY\'S PLAN'), findsNothing);

      await _longPressCard(tester, 'Task one');
      await _tapCard(tester, 'Task two');
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.text('Add to Today'));
      await tester.pumpAndSettle();

      // Selection bar gone, mode exited.
      expect(find.text('Add to Today'), findsNothing);
      expect(find.textContaining('selected'), findsNothing);

      // Two tasks moved to Today's Plan, one still pending.
      expect(find.text('TODAY\'S PLAN (2)'), findsOneWidget);
      expect(find.text('UP NEXT (1)'), findsOneWidget);

      // Capacity summary reflects the new totals.
      expect(find.textContaining('2 tasks · 1h 15m planned'), findsOneWidget);

      // Trailing icon slot is back for the remaining pending card.
      expect(find.byTooltip('Select for today'), findsWidgets);
    });

    testWidgets('Clear button exits selection mode without committing',
        (tester) async {
      await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Task one'),
        _todo(id: 't2', title: 'Task two'),
      ]);

      await _longPressCard(tester, 'Task one');
      await _tapCard(tester, 'Task two');
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear selection'));
      await tester.pumpAndSettle();

      expect(find.text('Add to Today'), findsNothing);
      expect(find.textContaining('TODAY\'S PLAN'), findsNothing);
      expect(find.text('UP NEXT (2)'), findsOneWidget);
    });

    testWidgets('deselecting the last item auto-exits selection mode',
        (tester) async {
      await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Task one'),
        _todo(id: 't2', title: 'Task two'),
      ]);

      await _longPressCard(tester, 'Task one');
      expect(find.text('1 selected'), findsOneWidget);

      // Tap the same card → deselect → mode exits.
      await _tapCard(tester, 'Task one');
      expect(find.text('Add to Today'), findsNothing);
      expect(find.byTooltip('Select for today'), findsWidgets);
    });

    testWidgets(
        "long-pressing a Today's Plan or Skipped card does not enter selection mode",
        (tester) async {
      await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Pending task'),
        _todo(id: 't2', title: 'Selected task'),
        _todo(id: 't3', title: 'Skipped task'),
      ]);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlanSummaryStep)),
      );
      container
          .read(focusSessionPlanningProvider.notifier)
          .selectTask('t2');
      container
          .read(focusSessionPlanningProvider.notifier)
          .skipTask('t3');
      await tester.pumpAndSettle();

      await _longPressCard(tester, 'Selected task');
      expect(find.text('Add to Today'), findsNothing);

      await _longPressCard(tester, 'Skipped task');
      expect(find.text('Add to Today'), findsNothing);

      await _longPressCard(tester, 'Pending task');
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('empty pending list never shows the bar', (tester) async {
      await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Only task'),
      ]);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlanSummaryStep)),
      );
      container
          .read(focusSessionPlanningProvider.notifier)
          .skipTask('t1');
      await tester.pumpAndSettle();

      expect(find.textContaining('UP NEXT'), findsNothing);
      expect(find.text('Add to Today'), findsNothing);
    });
  });
}
