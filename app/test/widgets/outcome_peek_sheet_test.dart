/// Widget tests for [OutcomePeekSheet] — the editable Outcome peek (#462, #698).
///
/// The sheet reads its "time logged" total from the real `time_logs` table via
/// [TimeLogDao.totalMinutesForTask] against an in-memory drift database — no
/// mocks ("test real behavior only"). The live row/tag/plan streams are stubbed
/// with `Stream.value` (a live Drift `watch()` hangs `pumpAndSettle`, see
/// TESTING.md); writes still land in the real in-memory database, which the
/// assertions read back. Opening and dismissing without an edit leaves the
/// `todos` row byte-identical.
library;

import 'dart:async';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/widgets/outcome_peek_sheet.dart';

import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

const _userId = 'test-user';

Todo _todo({
  required String id,
  String title = 'Ship the release',
  String? notes,
  int? timeEstimate,
  String? energyLevel,
  DateTime? dueDate,
}) {
  final now = DateTime.now();
  return Todo(
    id: id,
    title: title,
    notes: notes,
    intent: 'next',
    clarified: true,
    createdAt: now,
    updatedAt: now,
    userId: _userId,
    timeEstimate: timeEstimate,
    energyLevel: energyLevel,
    dueDate: dueDate,
  );
}

Future<void> _insertTodo(GtdDatabase db, Todo todo) async {
  await db.into(db.todos).insert(
        TodosCompanion(
          id: Value(todo.id),
          title: Value(todo.title),
          notes: Value(todo.notes),
          clarified: const Value(true),
          userId: Value(todo.userId),
          createdAt: Value(todo.createdAt),
          updatedAt: Value(todo.updatedAt),
          timeEstimate: Value(todo.timeEstimate),
          energyLevel: Value(todo.energyLevel),
          dueDate: Value(todo.dueDate),
        ),
      );
}

/// Harness: a Scaffold with an "open" button that shows the peek sheet for
/// [todo], backed by [db] via the database provider override.
Widget _harness(GtdDatabase db, Todo todo, {Stream<Todo?>? todoStream}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      taskDetailTodoProvider(todo.id)
          .overrideWith((_) => todoStream ?? Stream.value(todo)),
      taskTagsProvider(todo.id).overrideWith((_) => Stream.value([])),
      currentActionProvider(todo.id).overrideWith((_) => Stream.value(null)),
      plannedActionsProvider(todo.id).overrideWith((_) => Stream.value([])),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => OutcomePeekSheet.show(context, todo),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<Todo> _row(WidgetTester tester, GtdDatabase db, String id) async {
  final row = await tester.runAsync(() =>
      (db.select(db.todos)..where((t) => t.id.equals(id))).getSingle());
  return row!;
}

Future<void> _drainWrites(WidgetTester tester) async {
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(configureSqliteForTests);

  group('OutcomePeekSheet (#462)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets('renders title, notes, energy, time estimate, and due date',
        (tester) async {
      final todo = _todo(
        id: 't1',
        title: 'Draft the proposal',
        notes: 'Include the budget appendix.',
        timeEstimate: 90,
        energyLevel: 'high',
        dueDate: DateTime(2026, 8, 15),
      );
      await _insertTodo(db, todo);

      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_harness(db, todo));
      await _openSheet(tester);

      expect(find.text('Draft the proposal'), findsOneWidget);
      expect(find.text('Include the budget appendix.'), findsOneWidget);
      expect(find.text('High'), findsOneWidget);
      expect(find.text('1h 30m'), findsOneWidget); // time estimate
      expect(find.text('Aug 15, 2026'), findsOneWidget); // due date
      // Read-only surface announced for screen readers.
      expect(
        find.bySemanticsLabel(RegExp('Outcome details')),
        findsWidgets,
      );
      handle.dispose();
    });

    testWidgets('unset energy/time/due render as prompts, not values',
        (tester) async {
      final todo = _todo(
        id: 't2',
        title: 'Bare outcome',
        // notes, energyLevel, timeEstimate, dueDate all null.
      );
      await _insertTodo(db, todo);

      await tester.pumpWidget(_harness(db, todo));
      await _openSheet(tester);

      expect(find.text('Bare outcome'), findsOneWidget);
      // Notes is an empty field, not text.
      expect(find.text('Add notes'), findsOneWidget);
      // No energy label leaks through.
      expect(find.text('Low'), findsNothing);
      expect(find.text('Medium'), findsNothing);
      expect(find.text('High'), findsNothing);
      expect(find.text('Energy'), findsOneWidget);
      expect(find.text('Time'), findsOneWidget);
      expect(find.text('Due'), findsOneWidget);
    });

    testWidgets('time logged sums real time_logs rows (with ceiling rounding)',
        (tester) async {
      final todo = _todo(id: 't3', title: 'Logged outcome');
      await _insertTodo(db, todo);

      final base = DateTime(2024, 1, 1, 10, 0, 0).toUtc();
      // Stint 1: exactly 2 minutes.
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('log1'),
            userId: const Value(_userId),
            taskId: const Value('t3'),
            startedAt: Value(base.toIso8601String()),
            endedAt:
                Value(base.add(const Duration(minutes: 2)).toIso8601String()),
          ));
      // Stint 2: 95 seconds → ceils to 2 minutes.
      final gap = base.add(const Duration(minutes: 10));
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('log2'),
            userId: const Value(_userId),
            taskId: const Value('t3'),
            startedAt: Value(gap.toIso8601String()),
            endedAt:
                Value(gap.add(const Duration(seconds: 95)).toIso8601String()),
          ));

      await tester.pumpWidget(_harness(db, todo));
      await _openSheet(tester);

      // 2 + ceil(95s) = 2 + 2 = 4 minutes.
      expect(find.text('4m'), findsOneWidget);
    });

    testWidgets('shows "no time logged yet" when there are no time_logs rows',
        (tester) async {
      final todo = _todo(id: 't4', title: 'Never worked on');
      await _insertTodo(db, todo);

      await tester.pumpWidget(_harness(db, todo));
      await _openSheet(tester);

      expect(find.text('No time logged yet'), findsOneWidget);
    });

    testWidgets(
        'time logged is re-read fresh on reopen, not cached from first open '
        '(outcomePeekTimeLoggedProvider must stay autoDispose)',
        (tester) async {
      final todo = _todo(id: 't6', title: 'Reopened outcome');
      await _insertTodo(db, todo);

      final base = DateTime(2024, 1, 1, 10, 0, 0).toUtc();
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('log-a'),
            userId: const Value(_userId),
            taskId: const Value('t6'),
            startedAt: Value(base.toIso8601String()),
            endedAt:
                Value(base.add(const Duration(minutes: 5)).toIso8601String()),
          ));

      await tester.pumpWidget(_harness(db, todo));

      // First open: 5 minutes logged so far.
      await _openSheet(tester);
      expect(find.text('5m'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      // More time gets logged while the sheet is closed.
      final later = base.add(const Duration(hours: 1));
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('log-b'),
            userId: const Value(_userId),
            taskId: const Value('t6'),
            startedAt: Value(later.toIso8601String()),
            endedAt: Value(
                later.add(const Duration(minutes: 10)).toIso8601String()),
          ));

      // Re-opening for the same task must show the updated total (15m),
      // not the stale first-ever value (5m) from a cached provider.
      await _openSheet(tester);
      expect(find.text('15m'), findsOneWidget);
      expect(find.text('5m'), findsNothing);
    });

    testWidgets('open + dismiss without an edit writes nothing',
        (tester) async {
      final todo = _todo(
        id: 't5',
        title: 'Immutable outcome',
        notes: 'Do not edit me.',
        timeEstimate: 30,
        energyLevel: 'medium',
        dueDate: DateTime(2026, 9, 1),
      );
      await _insertTodo(db, todo);
      final before = await _row(tester, db, 't5');

      await tester.pumpWidget(_harness(db, todo));
      await _openSheet(tester);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await _drainWrites(tester);

      expect(find.text('Immutable outcome'), findsNothing);
      expect(await _row(tester, db, 't5'), before); // incl. updated_at
    });

    testWidgets('a title edit is saved when the field loses focus',
        (tester) async {
      final todo = _todo(id: 'e1', title: 'Old title');
      await _insertTodo(db, todo);
      await tester.pumpWidget(_harness(db, todo));
      await _openSheet(tester);

      await tester.enterText(
          find.byKey(const Key('outcome_peek_title')), '  New title ');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await _drainWrites(tester);

      final row = await _row(tester, db, 'e1');
      expect(row.title, 'New title');
      expect(row.lastClarifiedAt, isNotNull);
    });

    testWidgets('a title edit still focused at dismissal is flushed',
        (tester) async {
      final todo = _todo(id: 'e2', title: 'Old title');
      await _insertTodo(db, todo);
      await tester.pumpWidget(_harness(db, todo));
      await _openSheet(tester);

      await tester.enterText(
          find.byKey(const Key('outcome_peek_title')), 'Flushed title');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await _drainWrites(tester);

      expect((await _row(tester, db, 'e2')).title, 'Flushed title');
    });

    testWidgets('an unchanged title on blur issues no write', (tester) async {
      final todo = _todo(id: 'e3', title: 'Same title');
      await _insertTodo(db, todo);
      final before = await _row(tester, db, 'e3');
      await tester.pumpWidget(_harness(db, todo));
      await _openSheet(tester);

      await tester.tap(find.byKey(const Key('outcome_peek_title')));
      await tester.pump();
      await tester.enterText(
          find.byKey(const Key('outcome_peek_title')), 'Same title  ');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await _drainWrites(tester);

      expect(await _row(tester, db, 'e3'), before);
    });

    testWidgets('emptied notes null the column', (tester) async {
      final todo = _todo(id: 'e4', notes: 'Some notes');
      await _insertTodo(db, todo);
      await tester.pumpWidget(_harness(db, todo));
      await _openSheet(tester);

      await tester.enterText(find.byKey(const Key('outcome_peek_notes')), '');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await _drainWrites(tester);

      expect((await _row(tester, db, 'e4')).notes, isNull);
    });

    testWidgets('time estimate chip sets the estimate', (tester) async {
      final todo = _todo(id: 'e5');
      await _insertTodo(db, todo);
      await tester.pumpWidget(_harness(db, todo));
      await _openSheet(tester);

      await tester.tap(find.byKey(const Key('outcome_peek_time')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('45m'));
      await tester.pumpAndSettle();
      await _drainWrites(tester);

      expect((await _row(tester, db, 'e5')).timeEstimate, 45);
    });

    testWidgets('energy chip sets the energy level', (tester) async {
      final todo = _todo(id: 'e6');
      await _insertTodo(db, todo);
      await tester.pumpWidget(_harness(db, todo));
      await _openSheet(tester);

      await tester.tap(find.byKey(const Key('outcome_peek_energy')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('High'));
      await tester.pumpAndSettle();
      await _drainWrites(tester);

      expect((await _row(tester, db, 'e6')).energyLevel, 'high');
    });

    testWidgets('an Outcome deleted while open shows the missing state',
        (tester) async {
      final todo = _todo(id: 'e7', title: 'Doomed');
      await _insertTodo(db, todo);
      final stream = StreamController<Todo?>();
      addTearDown(stream.close);
      await tester.pumpWidget(_harness(db, todo, todoStream: stream.stream));
      await _openSheet(tester);

      stream.add(null);
      await tester.pump();
      await tester.pump();

      expect(find.text('This item is no longer here'), findsOneWidget);
      expect(find.byKey(const Key('outcome_peek_title')), findsNothing);
    });
  });
}
