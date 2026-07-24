/// Widget tests for [OutcomePeekSheet] — the read-only Outcome peek (#462).
///
/// The sheet reads its "time logged" total from the real `time_logs` table via
/// [TimeLogDao.totalMinutesForTask] against an in-memory drift database — no
/// mocks ("test real behavior only"). The read-only assertion pins that opening
/// and dismissing the sheet leaves the underlying `todos` row byte-identical.
library;

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
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
    timeSpentMinutes: 0,
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
Widget _harness(GtdDatabase db, Todo todo) {
  return ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
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

    testWidgets('omits null fields — no notes/energy/due-date rows',
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
      expect(find.text('NOTES'), findsNothing);
      // No energy label leaks through.
      expect(find.text('Low'), findsNothing);
      expect(find.text('Medium'), findsNothing);
      expect(find.text('High'), findsNothing);
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
        'is read-only: no text fields, and the todos row is unchanged after '
        'open + dismiss', (tester) async {
      final todo = _todo(
        id: 't5',
        title: 'Immutable outcome',
        notes: 'Do not edit me.',
        timeEstimate: 30,
        energyLevel: 'medium',
        dueDate: DateTime(2026, 9, 1),
      );
      await _insertTodo(db, todo);

      final before = await (db.select(db.todos)
            ..where((t) => t.id.equals('t5')))
          .getSingle();

      await tester.pumpWidget(_harness(db, todo));
      await _openSheet(tester);

      // No editable surfaces anywhere in the sheet.
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(EditableText), findsNothing);

      // Dismiss via the close button.
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Immutable outcome'), findsNothing);

      final after = await (db.select(db.todos)
            ..where((t) => t.id.equals('t5')))
          .getSingle();
      expect(after, before); // byte-identical row
    });
  });
}
