/// Widget tests for the "from HH:MM" mark on Up Next rows (#1077).
///
/// An Outcome whose time opens later in the planned day can be picked in Up
/// Next, though it cannot be done yet. The row says when its window opens.
///
/// The harness mirrors `plan_summary_search_test.dart`: the list providers and
/// [plannedDayTimeProvider] are overridden with values, so no live Drift
/// `watch()` runs under fake time (TESTING.md).
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/habit_progress_provider.dart';
import 'package:jeeves/screens/planning/steps/plan_summary_step.dart';
import 'package:jeeves/widgets/outcome_row.dart';

import '../../../test_helpers.dart';

Todo _todo(String id, String title) {
  final now = DateTime.now();
  return Todo(
    id: id,
    title: title,
    intent: 'next',
    createdAt: now,
    updatedAt: now,
    userId: 'local',
    timeEstimate: 30,
  );
}

final _plumber = _todo('later', 'Call the plumber');
final _report = _todo('plain', 'Write report');

/// The moment the plumber's window opens in the day being planned.
final _opensAtEleven = DateTime(2026, 11, 23, 11);

Widget _harness(
  GtdDatabase db, {
  List<Todo>? upNext,
  Map<String, DateTime> opensLaterAt = const {},
}) {
  final todos = upNext ?? [_plumber, _report];
  return ProviderScope(
    overrides: [
      // The Habits row watches live Drift streams; none of these tests are
      // about Habits, so keep it empty rather than leave a stream timer.
      activeHabitProgressProvider.overrideWithValue(const {}),
      habitsForTodayProvider.overrideWithValue(const {}),
      habitStackChainsProvider.overrideWithValue(const []),
      databaseProvider.overrideWithValue(db),
      plannedDayTimeProvider.overrideWithValue((
        notInPlannedDay: const <String>{},
        opensLaterAt: opensLaterAt,
      )),
      nextForFocusSessionPlanningProvider
          .overrideWith((_) => Stream.value(todos)),
      focusSessionPlanningSelectedTasksProvider
          .overrideWith((_) => Stream.value(const <Todo>[])),
      skippedNextForFocusSessionPlanningProvider
          .overrideWith((_) => Stream.value(const <Todo>[])),
      offUpNextForFocusSessionPlanningProvider
          .overrideWith((_) => const <OffUpNextCandidate>[]),
    ],
    child: const MaterialApp(home: Scaffold(body: PlanSummaryStep())),
  );
}

Future<void> _pump(WidgetTester tester, GtdDatabase db,
    {List<Todo>? upNext, Map<String, DateTime> opensLaterAt = const {}}) async {
  await tester.pumpWidget(_harness(db, upNext: upNext, opensLaterAt: opensLaterAt));
  await tester.pumpAndSettle();
}

/// The row that carries [title].
Finder _rowWith(String title) => find.ancestor(
      of: find.text(title),
      matching: find.byType(OutcomeRow),
    );

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() => db = GtdDatabase(NativeDatabase.memory()));
  tearDown(() async => db.close());

  testWidgets('an Up Next Outcome whose time opens later says when it opens',
      (tester) async {
    await _pump(tester, db, opensLaterAt: {'later': _opensAtEleven});

    expect(find.text('from 11:00'), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsOneWidget);

    final row = _rowWith('Call the plumber');
    expect(
      find.descendant(of: row, matching: find.text('from 11:00')),
      findsOneWidget,
    );
  });

  testWidgets('an Up Next Outcome with no opening time carries no mark',
      (tester) async {
    await _pump(tester, db, upNext: [_report]);

    expect(find.text('from 11:00'), findsNothing);
    expect(find.byIcon(Icons.schedule), findsNothing);
  });

  testWidgets('a search match still carries the mark', (tester) async {
    await _pump(tester, db, opensLaterAt: {'later': _opensAtEleven});

    await tester.enterText(find.byType(TextField), 'plumber');
    await tester.pumpAndSettle();

    expect(find.text('UP NEXT (1)'), findsOneWidget);
    expect(find.text('from 11:00'), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
  });
}
