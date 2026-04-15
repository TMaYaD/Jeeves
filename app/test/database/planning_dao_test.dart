/// Tests for TodoDao daily-planning methods added in Issue #82.
///
/// All tests use an in-memory Drift database — no mocks.
library;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase.forTesting(NativeDatabase.memory());

const _userId = 'test-user';
const _today = '2026-04-16';
const _yesterday = '2026-04-15';

/// Inserts a todo and optionally transitions it to a target state.
Future<String> _insert(
  GtdDatabase db, {
  required String id,
  required String title,
  String state = 'inbox',
  DateTime? dueDate,
  int? timeEstimate,
}) async {
  final now = DateTime.now();
  await db.inboxDao.insertTodo(TodosCompanion(
    id: Value(id),
    title: Value(title),
    state: const Value('inbox'),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
    dueDate: dueDate != null ? Value(dueDate) : const Value.absent(),
    timeEstimate:
        timeEstimate != null ? Value(timeEstimate) : const Value.absent(),
  ));
  if (state != 'inbox') {
    await (db.update(db.todos)..where((t) => t.id.equals(id)))
        .write(TodosCompanion(state: Value(state)));
  }
  return id;
}

void main() {
  setUpAll(configureSqliteForTests);

  // ---------------------------------------------------------------------------
  // watchNextActionsForPlanning
  // ---------------------------------------------------------------------------

  group('watchNextActionsForPlanning', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('returns next_action tasks not yet reviewed today', () async {
      await _insert(db, id: 'a', title: 'Action A', state: 'next_action');
      await _insert(db, id: 'b', title: 'Action B', state: 'next_action');

      final items =
          await db.todoDao.watchNextActionsForPlanning(_userId, _today).first;
      expect(items.map((t) => t.id), containsAll(['a', 'b']));
    });

    test('excludes tasks already reviewed today (any selection value)',
        () async {
      await _insert(db, id: 'a', title: 'Action A', state: 'next_action');
      await _insert(db, id: 'b', title: 'Action B', state: 'next_action');

      // Mark 'a' as selected for today
      await db.todoDao.selectForToday('a', _userId, _today);

      final items =
          await db.todoDao.watchNextActionsForPlanning(_userId, _today).first;
      expect(items.map((t) => t.id), isNot(contains('a')));
      expect(items.map((t) => t.id), contains('b'));
    });

    test('shows tasks reviewed on a different day (stale selection)', () async {
      await _insert(db, id: 'a', title: 'Action A', state: 'next_action');
      await db.todoDao.selectForToday('a', _userId, _yesterday);

      final items =
          await db.todoDao.watchNextActionsForPlanning(_userId, _today).first;
      // Yesterday's selection is stale — the task appears again.
      expect(items.map((t) => t.id), contains('a'));
    });

    test('excludes non-next_action tasks', () async {
      await _insert(db, id: 'a', title: 'Inbox item', state: 'inbox');
      await _insert(db, id: 'b', title: 'Someday', state: 'someday_maybe');

      final items =
          await db.todoDao.watchNextActionsForPlanning(_userId, _today).first;
      expect(items, isEmpty);
    });

    test('excludes tasks blocked by an incomplete blocker', () async {
      await _insert(db, id: 'blocker', title: 'Blocker', state: 'next_action');
      await _insert(db, id: 'blocked', title: 'Blocked task',
          state: 'next_action');
      await (db.update(db.todos)..where((t) => t.id.equals('blocked'))).write(
        const TodosCompanion(blockedByTodoId: Value('blocker')),
      );

      final items =
          await db.todoDao.watchNextActionsForPlanning(_userId, _today).first;
      expect(items.map((t) => t.id), isNot(contains('blocked')));
      expect(items.map((t) => t.id), contains('blocker'));
    });
  });

  // ---------------------------------------------------------------------------
  // watchScheduledDueToday
  // ---------------------------------------------------------------------------

  group('watchScheduledDueToday', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('returns scheduled tasks with dueDate on today', () async {
      final todayDt = DateTime(2026, 4, 16);
      await _insert(db,
          id: 'a',
          title: 'Today event',
          state: 'scheduled',
          dueDate: todayDt);

      final items =
          await db.todoDao.watchScheduledDueToday(_userId, _today).first;
      expect(items.length, 1);
      expect(items.first.id, 'a');
    });

    test('excludes scheduled tasks due on a different day', () async {
      await _insert(db,
          id: 'a',
          title: 'Tomorrow event',
          state: 'scheduled',
          dueDate: DateTime(2026, 4, 17));

      final items =
          await db.todoDao.watchScheduledDueToday(_userId, _today).first;
      expect(items, isEmpty);
    });

    test('excludes tasks already confirmed today', () async {
      final todayDt = DateTime(2026, 4, 16);
      await _insert(db,
          id: 'a',
          title: 'Today event',
          state: 'scheduled',
          dueDate: todayDt);
      await db.todoDao.selectForToday('a', _userId, _today);

      final items =
          await db.todoDao.watchScheduledDueToday(_userId, _today).first;
      expect(items, isEmpty);
    });

    test('excludes tasks without a due date', () async {
      await _insert(db, id: 'a', title: 'No date', state: 'scheduled');

      final items =
          await db.todoDao.watchScheduledDueToday(_userId, _today).first;
      expect(items, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // watchSelectedForToday
  // ---------------------------------------------------------------------------

  group('watchSelectedForToday', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('returns only tasks selected for today', () async {
      await _insert(db, id: 'a', title: 'A', state: 'next_action');
      await _insert(db, id: 'b', title: 'B', state: 'next_action');
      await db.todoDao.selectForToday('a', _userId, _today);

      final items =
          await db.todoDao.watchSelectedForToday(_userId, _today).first;
      expect(items.length, 1);
      expect(items.first.id, 'a');
    });

    test('skipped tasks (selectedForToday=false) do not appear', () async {
      await _insert(db, id: 'a', title: 'A', state: 'next_action');
      await db.todoDao.skipForToday('a', _userId, _today);

      final items =
          await db.todoDao.watchSelectedForToday(_userId, _today).first;
      expect(items, isEmpty);
    });

    test('stale selections from yesterday do not appear', () async {
      await _insert(db, id: 'a', title: 'A', state: 'next_action');
      await db.todoDao.selectForToday('a', _userId, _yesterday);

      final items =
          await db.todoDao.watchSelectedForToday(_userId, _today).first;
      expect(items, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // selectForToday / skipForToday
  // ---------------------------------------------------------------------------

  group('selectForToday and skipForToday', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('selectForToday sets selectedForToday=true and dailySelectionDate',
        () async {
      await _insert(db, id: 'a', title: 'A', state: 'next_action');
      await db.todoDao.selectForToday('a', _userId, _today);

      final row = await db.todoDao.getTodo('a', _userId);
      expect(row?.selectedForToday, true);
      expect(row?.dailySelectionDate, _today);
    });

    test('skipForToday sets selectedForToday=false and dailySelectionDate',
        () async {
      await _insert(db, id: 'a', title: 'A', state: 'next_action');
      await db.todoDao.skipForToday('a', _userId, _today);

      final row = await db.todoDao.getTodo('a', _userId);
      expect(row?.selectedForToday, false);
      expect(row?.dailySelectionDate, _today);
    });
  });

  // ---------------------------------------------------------------------------
  // undoReview
  // ---------------------------------------------------------------------------

  group('undoReview', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('resets selectedForToday and dailySelectionDate to null', () async {
      await _insert(db, id: 'a', title: 'A', state: 'next_action');
      await db.todoDao.selectForToday('a', _userId, _today);

      await db.todoDao.undoReview('a', _userId);

      final row = await db.todoDao.getTodo('a', _userId);
      expect(row?.selectedForToday, equals(null));
      expect(row?.dailySelectionDate, equals(null));
    });
  });

  // ---------------------------------------------------------------------------
  // deferTaskToSomeday
  // ---------------------------------------------------------------------------

  group('deferTaskToSomeday', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('transitions a next_action task to someday_maybe', () async {
      await _insert(db, id: 'a', title: 'A', state: 'next_action');
      await db.todoDao.deferTaskToSomeday('a', _userId);

      final row = await db.todoDao.getTodo('a', _userId);
      expect(row?.state, GtdState.somedayMaybe.value);
    });

    test('task no longer appears in watchNextActionsForPlanning after deferral',
        () async {
      await _insert(db, id: 'a', title: 'A', state: 'next_action');
      await db.todoDao.deferTaskToSomeday('a', _userId);

      final items =
          await db.todoDao.watchNextActionsForPlanning(_userId, _today).first;
      expect(items, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // rescheduleTask
  // ---------------------------------------------------------------------------

  group('rescheduleTask', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('updates dueDate without changing state', () async {
      final todayDt = DateTime(2026, 4, 16);
      final newDate = DateTime(2026, 4, 20);
      await _insert(db,
          id: 'a',
          title: 'A',
          state: 'scheduled',
          dueDate: todayDt);

      await db.todoDao.rescheduleTask('a', _userId, newDate);

      final row = await db.todoDao.getTodo('a', _userId);
      expect(row?.state, GtdState.scheduled.value);
      expect(row?.dueDate, newDate);
    });

    test('rescheduled task disappears from watchScheduledDueToday', () async {
      final todayDt = DateTime(2026, 4, 16);
      await _insert(db,
          id: 'a',
          title: 'A',
          state: 'scheduled',
          dueDate: todayDt);
      await db.todoDao
          .rescheduleTask('a', _userId, DateTime(2026, 4, 20));

      final items =
          await db.todoDao.watchScheduledDueToday(_userId, _today).first;
      expect(items, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // clearTodaySelections
  // ---------------------------------------------------------------------------

  group('clearTodaySelections', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('resets all selections for the given date', () async {
      await _insert(db, id: 'a', title: 'A', state: 'next_action');
      await _insert(db, id: 'b', title: 'B', state: 'next_action');
      await db.todoDao.selectForToday('a', _userId, _today);
      await db.todoDao.skipForToday('b', _userId, _today);

      await db.todoDao.clearTodaySelections(_userId, _today);

      final rowA = await db.todoDao.getTodo('a', _userId);
      final rowB = await db.todoDao.getTodo('b', _userId);
      expect(rowA?.selectedForToday, equals(null));
      expect(rowA?.dailySelectionDate, equals(null));
      expect(rowB?.selectedForToday, equals(null));
      expect(rowB?.dailySelectionDate, equals(null));
    });

    test('does not reset selections from a different date', () async {
      await _insert(db, id: 'a', title: 'A', state: 'next_action');
      await db.todoDao.selectForToday('a', _userId, _yesterday);

      await db.todoDao.clearTodaySelections(_userId, _today);

      final row = await db.todoDao.getTodo('a', _userId);
      // Yesterday's selection is untouched.
      expect(row?.selectedForToday, true);
      expect(row?.dailySelectionDate, _yesterday);
    });
  });

  // ---------------------------------------------------------------------------
  // watchSelectedTasksMissingEstimates
  // ---------------------------------------------------------------------------

  group('watchSelectedTasksMissingEstimates', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('returns selected tasks with no time estimate', () async {
      await _insert(db, id: 'a', title: 'A', state: 'next_action');
      await _insert(db,
          id: 'b', title: 'B', state: 'next_action', timeEstimate: 30);
      await db.todoDao.selectForToday('a', _userId, _today);
      await db.todoDao.selectForToday('b', _userId, _today);

      final items = await db.todoDao
          .watchSelectedTasksMissingEstimates(_userId, _today)
          .first;
      expect(items.length, 1);
      expect(items.first.id, 'a');
    });

    test('returns empty list when all selected tasks have estimates', () async {
      await _insert(db,
          id: 'a', title: 'A', state: 'next_action', timeEstimate: 15);
      await db.todoDao.selectForToday('a', _userId, _today);

      final items = await db.todoDao
          .watchSelectedTasksMissingEstimates(_userId, _today)
          .first;
      expect(items, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // v3 migration
  // ---------------------------------------------------------------------------

  group('v3 migration', () {
    test('new columns default to null for existing rows', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      final now = DateTime.now();
      await db.inboxDao.insertTodo(TodosCompanion(
        id: const Value('legacy'),
        title: const Value('Legacy task'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));

      final row = await db.todoDao.getTodo('legacy', _userId);
      expect(row?.selectedForToday, equals(null));
      expect(row?.dailySelectionDate, equals(null));
    });

    test('v2→v3 migration: addColumn restores schema with null defaults',
        () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // Simulate a v2 database (no selectedForToday / dailySelectionDate cols).
      await db.customStatement('DROP TABLE IF EXISTS todos');
      await db.customStatement(
        'CREATE TABLE todos ('
        '  id TEXT NOT NULL PRIMARY KEY,'
        '  title TEXT NOT NULL,'
        '  notes TEXT,'
        '  completed INTEGER NOT NULL DEFAULT 0,'
        '  priority INTEGER,'
        '  due_date INTEGER,'
        '  created_at INTEGER NOT NULL,'
        '  updated_at INTEGER,'
        '  state TEXT NOT NULL DEFAULT \'inbox\','
        '  time_estimate INTEGER,'
        '  energy_level TEXT,'
        '  capture_source TEXT,'
        '  location_id TEXT,'
        '  user_id TEXT NOT NULL,'
        '  in_progress_since TEXT,'
        '  time_spent_minutes INTEGER NOT NULL DEFAULT 0,'
        '  blocked_by_todo_id TEXT'
        ')',
      );

      // Insert a v2 row.
      final now = DateTime.now();
      await db.customInsert(
        'INSERT INTO todos (id, title, state, user_id, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('v2-row'),
          Variable.withString('v2 task'),
          Variable.withString('inbox'),
          Variable.withString(_userId),
          Variable.withDateTime(now),
          Variable.withDateTime(now),
        ],
      );

      // Run the v3 migration steps.
      final m = db.createMigrator();
      await m.addColumn(db.todos, db.todos.selectedForToday);
      await m.addColumn(db.todos, db.todos.dailySelectionDate);

      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items.length, 1);
      expect(items.first.title, 'v2 task');
      expect(items.first.selectedForToday, equals(null));
      expect(items.first.dailySelectionDate, equals(null));
    });
  });
}
