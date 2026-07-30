/// Widget tests for the Outcome peek affordance on the Plan Summary step (#462).
///
/// A plain tap on a card (outside multi-select) opens the read-only
/// [OutcomePeekSheet]; the tap never selects/skips/undoes, and dismissal
/// restores scroll and selection. Inside multi-select, tap keeps its
/// selection meaning on Pending cards and is inert on Today/Skipped cards —
/// whose action buttons stay fully functional (call-site `onPeek` gating,
/// test 3b).
///
/// Harness mirrors [plan_summary_scroll_test.dart]: the three list streams are
/// overridden with streams over an in-memory todo source (avoiding drift's
/// `StreamQueryStore` teardown timer), and emit asynchronously via
/// [_delayedStream] so the scroll-preservation test (5) exercises a real reload
/// window. The peek sheet's time-logged read hits the in-memory
/// [databaseProvider] and resolves to 0 (no `time_logs` rows) — enough to prove
/// the sheet opens.
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

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

final _testTodosProvider = Provider<List<Todo>>((_) => const []);

const _reloadDelay = Duration(milliseconds: 300);

Stream<List<Todo>> _delayedStream(List<Todo> Function() compute) =>
    Stream.fromFuture(Future.delayed(_reloadDelay, compute));

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

List<Todo> _manyTodos(int n) => [
      for (var i = 0; i < n; i++)
        _todo(
          id: 't${i.toString().padLeft(2, '0')}',
          title: 'Task ${i.toString().padLeft(2, '0')}',
          timeEstimate: 30,
        ),
    ];

Widget _harness(GtdDatabase db, List<Todo> todos) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      _testTodosProvider.overrideWith((_) => todos),
      nextForFocusSessionPlanningProvider.overrideWith((ref) {
        final state = ref.watch(focusSessionPlanningProvider);
        final reviewed = {
          ...state.reviewedTaskIds,
          ...state.pendingSelectedTaskIds,
        };
        final all = ref.watch(_testTodosProvider);
        return _delayedStream(
          () => all.where((t) => !reviewed.contains(t.id)).toList(),
        );
      }),
      focusSessionPlanningSelectedTasksProvider.overrideWith((ref) {
        final ids = ref.watch(
          focusSessionPlanningProvider.select((s) => s.pendingSelectedTaskIds),
        );
        final all = ref.watch(_testTodosProvider);
        final indexById = {for (var i = 0; i < ids.length; i++) ids[i]: i};
        return _delayedStream(
          () => all.where((t) => ids.contains(t.id)).toList()
            ..sort((a, b) => indexById[a.id]!.compareTo(indexById[b.id]!)),
        );
      }),
      skippedNextForFocusSessionPlanningProvider.overrideWith((ref) {
        final state = ref.watch(focusSessionPlanningProvider);
        final skippedIds = state.reviewedTaskIds
            .where((id) => !state.pendingSelectedTaskIds.contains(id))
            .toSet();
        final all = ref.watch(_testTodosProvider);
        return _delayedStream(
          () => all.where((t) => skippedIds.contains(t.id)).toList(),
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

Finder _cardWithTitle(String title) => find.ancestor(
      of: find.text(title),
      matching: find.byType(Card),
    );

FocusSessionPlanningState _planningState(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(PlanSummaryStep)))
        .read(focusSessionPlanningProvider);

FocusSessionPlanningNotifier _planningNotifier(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(PlanSummaryStep)))
        .read(focusSessionPlanningProvider.notifier);

double _scrollOffset(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    )
    .position
    .pixels;

void main() {
  setUpAll(configureSqliteForTests);

  group('PlanSummaryStep — Outcome peek (#462)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'tapping a Pending card opens the peek sheet without selecting/skipping',
        (tester) async {
      await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Task one', timeEstimate: 30),
        _todo(id: 't2', title: 'Task two'),
      ]);

      await tester.tap(find.text('Task one'));
      await tester.pumpAndSettle();

      expect(find.byType(OutcomePeekSheet), findsOneWidget);
      // No side effect on planning state.
      final state = _planningState(tester);
      expect(state.reviewedTaskIds, isEmpty);
      expect(state.pendingSelectedTaskIds, isEmpty);
    });

    testWidgets('tapping a Today\'s Plan card and a Skipped card opens the sheet',
        (tester) async {
      await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Pending task'),
        _todo(id: 't2', title: 'Selected task'),
        _todo(id: 't3', title: 'Skipped task'),
      ]);

      _planningNotifier(tester).selectTask('t2');
      _planningNotifier(tester).skipTask('t3');
      await tester.pumpAndSettle();

      // Today's Plan card.
      await tester.tap(find.text('Selected task'));
      await tester.pumpAndSettle();
      expect(find.byType(OutcomePeekSheet), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(OutcomePeekSheet), findsNothing);

      // Skipped card.
      await tester.tap(find.text('Skipped task'));
      await tester.pumpAndSettle();
      expect(find.byType(OutcomePeekSheet), findsOneWidget);
    });

    testWidgets(
        'in multi-select mode, tap toggles a Pending card and does not peek; '
        'tap on a Today card is inert', (tester) async {
      await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Pending one'),
        _todo(id: 't2', title: 'Pending two'),
        _todo(id: 't3', title: 'Today task'),
      ]);

      _planningNotifier(tester).selectTask('t3');
      await tester.pumpAndSettle();

      // Enter multi-select via long-press on a pending card.
      await tester.longPress(_cardWithTitle('Pending one').first);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      // Tap another pending card → toggles selection, no sheet.
      await tester.tap(_cardWithTitle('Pending two').first);
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
      expect(find.byType(OutcomePeekSheet), findsNothing);

      // Tap the Today card → inert (no sheet, still 2 selected).
      await tester.tap(_cardWithTitle('Today task').first);
      await tester.pumpAndSettle();
      expect(find.byType(OutcomePeekSheet), findsNothing);
      expect(find.text('2 selected'), findsOneWidget);
    });

    testWidgets(
        'multi-select leaves Today/Skipped cards unchanged with working buttons '
        '(3b)', (tester) async {
      await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Pending task'),
        _todo(id: 't2', title: 'Today task'),
        _todo(id: 't3', title: 'Skipped task'),
      ]);

      _planningNotifier(tester).selectTask('t2');
      _planningNotifier(tester).skipTask('t3');
      await tester.pumpAndSettle();

      // Enter multi-select via the pending card.
      await tester.longPress(_cardWithTitle('Pending task').first);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      // Only the single pending card grew a checkbox; Today/Skipped did not.
      expect(find.byType(Checkbox), findsOneWidget);

      // Today card keeps its Undo + Skip buttons; Skipped keeps Select + Un-skip.
      final todayCard = _cardWithTitle('Today task');
      expect(
        find.descendant(
            of: todayCard, matching: find.byTooltip('Remove from today')),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: todayCard, matching: find.byTooltip('Skip for today')),
        findsOneWidget,
      );

      final skippedCard = _cardWithTitle('Skipped task');
      expect(
        find.descendant(
            of: skippedCard, matching: find.byTooltip('Select for today')),
        findsOneWidget,
      );

      // The Today card's Skip button still fires while multi-select is active.
      await tester.tap(
        find.descendant(
            of: todayCard, matching: find.byTooltip('Skip for today')),
      );
      await tester.pumpAndSettle();
      expect(_planningState(tester).reviewedTaskIds, contains('t2'));
      expect(find.byType(OutcomePeekSheet), findsNothing);
    });

    testWidgets('long-press still enters multi-select mode', (tester) async {
      await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Task one'),
        _todo(id: 't2', title: 'Task two'),
      ]);

      await tester.longPress(_cardWithTitle('Task one').first);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byType(OutcomePeekSheet), findsNothing);
    });

    testWidgets(
        'dismissing the peek restores scroll position and selection state',
        (tester) async {
      await _pumpStep(tester, db, _manyTodos(20));

      const target = 'Task 12';
      await tester.scrollUntilVisible(find.text(target), 120);
      await tester.pumpAndSettle();

      final before = _scrollOffset(tester);
      expect(before, greaterThan(0),
          reason: 'test must genuinely scroll away from the top');

      await tester.tap(find.text(target));
      await tester.pumpAndSettle();
      expect(find.byType(OutcomePeekSheet), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(OutcomePeekSheet), findsNothing);

      // Scroll offset preserved; nothing selected/skipped by the peek.
      final after = _scrollOffset(tester);
      expect(after, closeTo(before, 1));
      final state = _planningState(tester);
      expect(state.reviewedTaskIds, isEmpty);
      expect(state.pendingSelectedTaskIds, isEmpty);
    });

    testWidgets(
        'card-level tap does not shadow the Select/Skip icon buttons',
        (tester) async {
      await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Task one'),
      ]);

      // Tap the Select button → selects, and does NOT open the peek.
      await tester.tap(
        find.descendant(
          of: _cardWithTitle('Task one'),
          matching: find.byTooltip('Select for today'),
        ),
      );
      await tester.pumpAndSettle();

      expect(_planningState(tester).pendingSelectedTaskIds, contains('t1'));
      expect(find.byType(OutcomePeekSheet), findsNothing);
    });
  });
}
