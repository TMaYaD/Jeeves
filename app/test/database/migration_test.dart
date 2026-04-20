import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

const _userId = 'test-user';

void main() {
  setUpAll(configureSqliteForTests);

  group('Schema migration', () {
    test('v2 schema: timeSpentMinutes defaults to 0 when not supplied', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // Insert without specifying the new columns (they use DB defaults).
      final now = DateTime.now();
      await db.inboxDao.insertTodo(TodosCompanion(
        id: const Value('a'),
        title: const Value('Test task'),
        userId: Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));

      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items.length, 1);
      expect(items.first.timeSpentMinutes, 0);
      expect(items.first.inProgressSince, equals(null));
      expect(items.first.blockedByTodoId, equals(null));
    });

    test('v2 schema: inProgressSince and blockedByTodoId can be set', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      final now = DateTime.now();
      final nowIso = now.toIso8601String();
      await db.customInsert(
        'INSERT INTO todos (id, title, state, user_id, created_at, '
        'in_progress_since, time_spent_minutes, blocked_by_todo_id) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('b'),
          Variable.withString('Blocked task'),
          Variable.withString('next_action'),
          Variable.withString(_userId),
          Variable.withDateTime(now),
          Variable.withString(nowIso),
          Variable.withInt(15),
          Variable.withString('other-id'),
        ],
      );

      final todos = await (db.select(db.todos)
            ..where((t) => t.id.equals('b')))
          .get();
      expect(todos.length, 1);
      expect(todos.first.inProgressSince, nowIso);
      expect(todos.first.timeSpentMinutes, 15);
      expect(todos.first.blockedByTodoId, 'other-id');
    });

    test('v2 schema: old data (no new columns) survives intact', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      final now = DateTime.now();
      // Insert a row simulating "pre-v2" data by omitting the new columns.
      await db.customInsert(
        'INSERT INTO todos (id, title, state, user_id, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('legacy'),
          Variable.withString('Legacy task'),
          Variable.withString('inbox'),
          Variable.withString(_userId),
          Variable.withDateTime(now),
          Variable.withDateTime(now),
        ],
      );

      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items.length, 1);
      expect(items.first.title, 'Legacy task');
      expect(items.first.timeSpentMinutes, 0);
      expect(items.first.inProgressSince, equals(null));
      expect(items.first.blockedByTodoId, equals(null));
    });

    test('v5→v6 migration: existing todo_tags rows get backfilled id', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // Recreate todo_tags with the v5 shape (no id column).
      await db.customStatement('DROP TABLE IF EXISTS todo_tags');
      await db.customStatement(
        'CREATE TABLE todo_tags ('
        '  todo_id TEXT NOT NULL,'
        '  tag_id TEXT NOT NULL,'
        '  user_id TEXT NOT NULL,'
        '  PRIMARY KEY (todo_id, tag_id)'
        ')',
      );

      // Seed a legacy junction row.
      await db.customStatement(
        "INSERT INTO todo_tags (todo_id, tag_id, user_id) "
        "VALUES ('todo1', 'tag1', '$_userId')",
      );

      // Run the production v6 migration steps directly.
      await db.customStatement('ALTER TABLE todo_tags ADD COLUMN id TEXT');
      await db.customStatement(
        "UPDATE todo_tags SET id = lower(hex(randomblob(16))) WHERE id IS NULL",
      );

      final rows = await db.customSelect('SELECT id FROM todo_tags').get();
      expect(rows.length, 1);
      final id = rows.first.read<String?>('id');
      expect(id, isA<String>());
      expect(id!.length, greaterThan(0));
    });

    test('v1→v2 migration: legacy rows survive upgrade with correct defaults',
        () async {
      // Open a fresh in-memory DB.  onCreate runs and creates the current (v2)
      // schema on the first query; we then drop and recreate the todos table
      // without the v2 columns to simulate a v1 database, insert legacy rows,
      // and finally re-run the production addColumn migration steps to prove
      // they restore the full schema while keeping the existing data.
      final db = _openInMemory();
      addTearDown(db.close);

      // Recreate todos with the v1 shape (no in_progress_since,
      // time_spent_minutes, or blocked_by_todo_id columns).
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
        '  user_id TEXT NOT NULL'
        ')',
      );

      // Insert a legacy row (v1 data — no v2 columns).
      final now = DateTime.now();
      await db.customInsert(
        'INSERT INTO todos (id, title, state, user_id, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('legacy-v1'),
          Variable.withString('Legacy v1 task'),
          Variable.withString('inbox'),
          Variable.withString(_userId),
          Variable.withDateTime(now),
          Variable.withDateTime(now),
        ],
      );

      // Run the production v2 migration (same addColumn calls as onUpgrade).
      final m = db.createMigrator();
      await m.addColumn(db.todos, db.todos.inProgressSince);
      await m.addColumn(db.todos, db.todos.timeSpentMinutes);
      await m.addColumn(db.todos, db.todos.blockedByTodoId);

      // Legacy data must survive and new columns must carry correct defaults.
      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items.length, 1);
      expect(items.first.title, 'Legacy v1 task');
      expect(items.first.timeSpentMinutes, 0);
      expect(items.first.inProgressSince, equals(null));
      expect(items.first.blockedByTodoId, equals(null));
    });
  });
}
