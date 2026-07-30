/// Widget tests pinning the *derived* time-logged total on both Evening
/// Shutdown Review steps (issue #604, continuing #480).
///
/// Time spent on an Outcome is derived from `SUM(time_logs)` — there is no
/// stored total anywhere for a stale value to leak from. These are the
/// consumer-level pins for that derivation: insert real `time_logs` rows, render
/// the step, and assert the rendered label. Both steps are covered because they
/// read the total independently (a summary bar plus per-card chips on step 0, a
/// single card chip on step 1).
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/shutdown/steps/completed_review_step.dart';
import 'package:jeeves/screens/shutdown/steps/unfinished_tasks_step.dart';

import '../../helpers/settle.dart';
import '../../test_helpers.dart';

const _userId = 'local';

Future<void> _insertTodo(
  GtdDatabase db,
  String id, {
  int? timeEstimate,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Task $id'),
        clarified: const Value(true),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
        timeEstimate: Value(timeEstimate),
      ));
}

/// A closed stint of [minutes] against [taskId], attributed to [sessionId].
Future<void> _insertClosedLog(
  GtdDatabase db, {
  required String id,
  required String taskId,
  required String sessionId,
  required DateTime startedAt,
  required int minutes,
}) async {
  await db.into(db.timeLogs).insert(TimeLogsCompanion(
        id: Value(id),
        userId: const Value(_userId),
        taskId: Value(taskId),
        startedAt: Value(startedAt.toUtc().toIso8601String()),
        endedAt: Value(
          startedAt.toUtc().add(Duration(minutes: minutes)).toIso8601String(),
        ),
        focusSessionId: Value(sessionId),
      ));
}

(Widget, ProviderContainer) _host(GtdDatabase db, Widget step) {
  final container = ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(db)],
  );
  return (
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: step)),
    ),
    container,
  );
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late GtdDatabase db;

  setUp(() => db = GtdDatabase(NativeDatabase.memory()));
  tearDown(() async => db.close());

  testWidgets(
      'Completed Review sums time logged from time_logs, per card and in the '
      'summary bar', (tester) async {
    await _insertTodo(db, 't1', timeEstimate: 30);
    final sessionId = await db.focusSessionDao
        .openSession(userId: _userId, taskIds: ['t1']);
    // Two stints on the same Outcome, in the same session: 25m + 10m.
    await _insertClosedLog(db,
        id: 'tl-1',
        taskId: 't1',
        sessionId: sessionId,
        startedAt: DateTime.utc(2026, 5, 1, 9, 30),
        minutes: 25);
    await _insertClosedLog(db,
        id: 'tl-2',
        taskId: 't1',
        sessionId: sessionId,
        startedAt: DateTime.utc(2026, 5, 1, 10, 0),
        minutes: 10);
    await db.todoDao.markDone('t1');

    final (widget, container) = _host(db, const CompletedReviewStep());
    addTearDown(container.dispose);
    await tester.pumpWidget(widget);
    await settleWithRealAsync(tester);

    expect(find.text('Actual 35m'), findsOneWidget,
        reason: 'the card chip is SUM(time_logs) across both stints');
    // The summary bar's ACTUAL stat is the same derivation, folded over the
    // completed set.
    expect(find.text('35m'), findsOneWidget);
    expect(find.text('Est 30m'), findsOneWidget);

    await _dispose(tester);
  });

  testWidgets('Resolve Unfinished shows the logged total from time_logs',
      (tester) async {
    await _insertTodo(db, 't2', timeEstimate: 60);
    final sessionId = await db.focusSessionDao
        .openSession(userId: _userId, taskIds: ['t2']);
    await _insertClosedLog(db,
        id: 'tl-3',
        taskId: 't2',
        sessionId: sessionId,
        startedAt: DateTime.utc(2026, 5, 1, 9, 0),
        minutes: 90);

    final (widget, container) = _host(db, const UnfinishedTasksStep());
    addTearDown(container.dispose);
    await tester.pumpWidget(widget);
    await settleWithRealAsync(tester);

    expect(find.text('1h 30m logged'), findsOneWidget,
        reason: 'derived from time_logs, formatted h/m');
    expect(find.text('Est 1h'), findsOneWidget);

    await _dispose(tester);
  });

  testWidgets(
      'Resolve Unfinished renders no logged chip for an Outcome with no stints',
      (tester) async {
    await _insertTodo(db, 't3');
    await db.focusSessionDao.openSession(userId: _userId, taskIds: ['t3']);

    final (widget, container) = _host(db, const UnfinishedTasksStep());
    addTearDown(container.dispose);
    await tester.pumpWidget(widget);
    await settleWithRealAsync(tester);

    expect(find.textContaining('logged'), findsNothing);

    await _dispose(tester);
  });

  testWidgets(
      'the logged total spans earlier sessions, not just the open one',
      (tester) async {
    await _insertTodo(db, 't4');
    final priorId = await db.focusSessionDao.openSession(
      userId: _userId,
      taskIds: ['t4'],
      now: DateTime(2026, 4, 30, 9, 0),
    );
    await _insertClosedLog(db,
        id: 'tl-prior',
        taskId: 't4',
        sessionId: priorId,
        startedAt: DateTime.utc(2026, 4, 30, 9, 30),
        minutes: 20);
    await db.focusSessionDao
        .closeSession(sessionId: priorId, now: DateTime(2026, 4, 30, 17, 0));

    final sessionId = await db.focusSessionDao.openSession(
      userId: _userId,
      taskIds: ['t4'],
      now: DateTime(2026, 5, 1, 9, 0),
    );
    await _insertClosedLog(db,
        id: 'tl-today',
        taskId: 't4',
        sessionId: sessionId,
        startedAt: DateTime.utc(2026, 5, 1, 9, 30),
        minutes: 15);

    final (widget, container) = _host(db, const UnfinishedTasksStep());
    addTearDown(container.dispose);
    await tester.pumpWidget(widget);
    await settleWithRealAsync(tester);

    expect(find.text('35m logged'), findsOneWidget,
        reason: '20m from the prior session + 15m today (cumulative)');

    await _dispose(tester);
  });
}
