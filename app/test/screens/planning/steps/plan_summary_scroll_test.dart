/// Widget tests pinning the Plan Summary list's scroll behaviour (#459).
///
/// Symptom: selecting (picking up) a Pending Review task jumped the whole list
/// back to the top, while Skip reorganised in place. The cause was a loading
/// guard that returned a spinner whenever any watched stream was *reloading*,
/// unmounting the un-keyed `ListView` and discarding its scroll offset. The fix
/// gates the spinner on "no data yet" (`hasValue`) so the list stays mounted
/// after the initial load and every mutation reorganises in place.
///
/// As with [plan_summary_multi_select_test.dart], the three list streams are
/// overridden with streams over an in-memory todo source so the test does not
/// subscribe to drift's `StreamQueryStore` (which would leave a pending
/// `markAsClosed` timer behind on teardown). Unlike that file, the overrides
/// here emit *asynchronously* (see [_delayedStream]): every planning-state
/// change re-executes all three providers and presents a real reloading window,
/// which is what the production query pays when its bound ids change. A
/// `Stream.value` override resolves inside one pump and would hide the bug.
///
/// The test therefore pins the *symptom* — does a reload remount the list and
/// reset its scroll offset — not the production Drift stream-cache asymmetry
/// between Select (cache miss) and Skip (cache hit); under these overrides both
/// interactions take the same reload path.
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

final _testTodosProvider = Provider<List<Todo>>((_) => const []);

/// A reload latency long enough to span the discrete frames pumped after an
/// interaction. `Stream.value` would resolve within a single pump and never
/// present a loading frame — but the production streams pay an async round-trip
/// to sqlite whenever the query's bound ids change (the exact reload that used
/// to flash a spinner). Modelling that async gap is what makes the un-fixed
/// guard observably remount the list here.
const _reloadDelay = Duration(milliseconds: 300);

/// Emits [compute]'s result after [_reloadDelay]. Each `ref.watch`-driven
/// re-execution re-arms the delay, so a planning-state change presents a
/// genuine reloading window before the new data lands.
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
    timeSpentMinutes: 0,
    timeEstimate: timeEstimate,
  );
}

/// Enough tasks to make the list taller than the test viewport (800×600).
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
      // Pending Review: next-action todos minus anything already reviewed.
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
      // Today's Plan: pending selected, ordered by selection.
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
      // Skipped: reviewed but not selected.
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

/// The single scrollable owned by the task [ListView].
double _scrollOffset(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    )
    .position
    .pixels;

/// Pumps a few discrete frames, failing if a spinner appears in any of them —
/// this is where the pre-fix code flashed the `CircularProgressIndicator` that
/// unmounted the list.
Future<void> _expectNoSpinnerAcrossFrames(WidgetTester tester) async {
  // Frames inside the reload window (< _reloadDelay). The pre-fix guard flashed
  // a `CircularProgressIndicator` here, unmounting the list.
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(CircularProgressIndicator), findsNothing);
  }
  // Advance past the reload so the delayed streams emit and no timer is left
  // pending at teardown, then let the rebuilt tree settle.
  await tester.pump(_reloadDelay);
  await tester.pumpAndSettle();
  expect(find.byType(CircularProgressIndicator), findsNothing);
}

void main() {
  setUpAll(configureSqliteForTests);

  group('PlanSummaryStep — scroll preservation (#459)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'selecting a mid-list pending task keeps scroll position (no jump, '
        'no spinner)', (tester) async {
      await _pumpStep(tester, db, _manyTodos(20));

      const target = 'Task 12';
      await tester.scrollUntilVisible(find.text(target), 120);
      await tester.pumpAndSettle();

      final before = _scrollOffset(tester);
      expect(before, greaterThan(0),
          reason: 'test must genuinely scroll away from the top');

      await tester.tap(
        find.descendant(
          of: _cardWithTitle(target),
          matching: find.byTooltip('Select for today'),
        ),
      );
      await _expectNoSpinnerAcrossFrames(tester);

      // The pick-up was committed (its Today's Plan header now sits above the
      // viewport — off-screen precisely because the list did NOT jump to top).
      expect(_planningState(tester).pendingSelectedTaskIds, contains('t12'));
      // The list did not jump back to the top; the offset is preserved.
      final after = _scrollOffset(tester);
      expect(after, greaterThan(0));
      expect(after, closeTo(before, 150));
    });

    testWidgets('skipping a mid-list task keeps scroll position (regression pin)',
        (tester) async {
      await _pumpStep(tester, db, _manyTodos(20));

      const target = 'Task 12';
      await tester.scrollUntilVisible(find.text(target), 120);
      await tester.pumpAndSettle();

      final before = _scrollOffset(tester);
      expect(before, greaterThan(0));

      await tester.tap(
        find.descendant(
          of: _cardWithTitle(target),
          matching: find.byTooltip('Skip for today'),
        ),
      );
      await _expectNoSpinnerAcrossFrames(tester);

      expect(_planningState(tester).reviewedTaskIds, contains('t12'));
      final after = _scrollOffset(tester);
      expect(after, greaterThan(0));
      expect(after, closeTo(before, 150));
    });

    testWidgets(
        'multi-select Add to Today keeps scroll position (no jump, no spinner)',
        (tester) async {
      await _pumpStep(tester, db, _manyTodos(20));

      const first = 'Task 10';
      const second = 'Task 11';
      await tester.scrollUntilVisible(find.text(first), 120);
      await tester.pumpAndSettle();

      // Enter selection mode and pick two adjacent mid-list tasks.
      await tester.longPress(_cardWithTitle(first).first);
      await tester.pumpAndSettle();
      await tester.tap(_cardWithTitle(second).first);
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      // Capture the offset with the selection bar already present, so the
      // commit is the only change under test.
      final before = _scrollOffset(tester);
      expect(before, greaterThan(0));

      await tester.tap(find.text('Add to Today'));
      await _expectNoSpinnerAcrossFrames(tester);

      expect(
        _planningState(tester).pendingSelectedTaskIds,
        containsAll(<String>['t10', 't11']),
      );
      final after = _scrollOffset(tester);
      expect(after, greaterThan(0));
      expect(after, closeTo(before, 200));
    });
  });
}
