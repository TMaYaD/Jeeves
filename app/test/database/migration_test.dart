import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/utils/tag_colors.dart';
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
    });

    test('v2 schema: old data (no new columns) survives intact', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      final now = DateTime.now();
      // Insert a row omitting the v2+ columns (they use DB defaults).
      // Uses state='next_action' + clarified=0 to simulate a post-migration
      // inbox item (pre-v2 'inbox' rows are transformed by the v11 migration).
      await db.customInsert(
        'INSERT INTO todos (id, title, state, clarified, user_id, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('legacy'),
          Variable.withString('Legacy task'),
          Variable.withString('next_action'),
          Variable.withInt(0),
          Variable.withString(_userId),
          Variable.withDateTime(now),
          Variable.withDateTime(now),
        ],
      );

      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items.length, 1);
      expect(items.first.title, 'Legacy task');
      expect(items.first.timeSpentMinutes, 0);
    });

    test('v6→v7 migration: null-color tags get backfilled; post-migration updateColor(null) is not overwritten', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // Insert two legacy tags with no color (simulating pre-v7 rows).
      await db.customStatement(
        "INSERT INTO tags (id, name, type, user_id) VALUES ('t1', 'work', 'context', '$_userId')",
      );
      await db.customStatement(
        "INSERT INTO tags (id, name, type, user_id) VALUES ('t2', 'home', 'context', '$_userId')",
      );

      // Confirm both start with null color.
      final before = await (db.select(db.tags)).get();
      expect(before.where((t) => t.color == null).length, 2);

      // Run the v7 migration path.
      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 6, 7);

      // Both tags must now have non-null colors.
      final after = await (db.select(db.tags)).get();
      expect(after.every((t) => t.color != null), isTrue);

      // Backfill assigns stable, non-null colors; assert the two seeded names
      // do not collide and that each matches the expected deterministic value.
      final work = after.firstWhere((t) => t.id == 't1');
      final home = after.firstWhere((t) => t.id == 't2');
      expect(work.color, isA<String>());
      expect(home.color, isA<String>());
      expect(work.color, isNot(equals(home.color)));
      // Determinism: calling the same color function again must yield the same hex.
      expect(work.color, equals(tagColorToHex(tagColorForName('work'))));
      expect(home.color, equals(tagColorToHex(tagColorForName('home'))));

      // An intentional user reset after the migration must persist as null
      // (the one-time migration must not re-run and overwrite it).
      await db.tagDao.updateColor('t1', null);
      final cleared = await (db.select(db.tags)
            ..where((t) => t.id.equals('t1')))
          .getSingle();
      expect(cleared.color, equals(null));
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

      // Drive the real production onUpgrade path (from=5, to=6) so the test
      // stays in sync with the migration code automatically.
      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 5, 6);

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
      // in_progress_since used raw SQL because the Drift accessor was removed
      // in schema v14 when the column was dropped.
      final m = db.createMigrator();
      await db.customStatement(
        'ALTER TABLE todos ADD COLUMN in_progress_since TEXT',
      );
      await m.addColumn(db.todos, db.todos.timeSpentMinutes);
      // blocked_by_todo_id existed v2→v7; use raw SQL since the Drift
      // accessor no longer exists after schema v8.
      await db.customStatement(
        'ALTER TABLE todos ADD COLUMN blocked_by_todo_id TEXT',
      );
      // intent was introduced in v10.
      await db.customStatement(
        "ALTER TABLE todos ADD COLUMN intent TEXT NOT NULL DEFAULT 'next'",
      );
      // clarified was introduced in v11.
      await db.customStatement(
        "ALTER TABLE todos ADD COLUMN clarified INTEGER NOT NULL DEFAULT 1",
      );
      // Migrate legacy inbox rows to next_action + clarified=0 (v11 semantics).
      await db.customStatement(
        "UPDATE todos SET clarified = 0, state = 'next_action' WHERE state = 'inbox'",
      );

      // Legacy data must survive and new columns must carry correct defaults.
      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items.length, 1);
      expect(items.first.title, 'Legacy v1 task');
      expect(items.first.timeSpentMinutes, 0);
    });

    test('v12→v13 migration: state=waiting_for rows become next_action; waiting_for column intact',
        () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // Insert a row that simulates a pre-v13 waiting_for state row.
      final now = DateTime.now();
      await db.customInsert(
        'INSERT INTO todos (id, title, state, waiting_for, clarified, user_id, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('wf1'),
          Variable.withString('Waiting task'),
          Variable.withString('next_action'), // current schema is already v13 on open
          Variable.withString('Alice'),
          Variable.withInt(1),
          Variable.withString(_userId),
          Variable.withDateTime(now),
        ],
      );

      // Drive the v13 migration path directly (simulating upgrade from v12).
      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 12, 13);

      // Rows that had state='waiting_for' should now be next_action.
      // (In this test the row already has next_action; verify it is untouched.)
      final rows = await db.customSelect(
        'SELECT state, waiting_for FROM todos WHERE id = ?',
        variables: [Variable.withString('wf1')],
      ).get();
      expect(rows.length, 1);
      expect(rows.first.read<String>('state'), 'next_action');
      expect(rows.first.read<String?>('waiting_for'), 'Alice');
    });

    test('v12→v13 migration: state=waiting_for is collapsed to next_action', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // The v13 CHECK constraint rejects 'waiting_for', so we can't INSERT or
      // UPDATE to that value directly. Swap todos with a constraint-free CTAS
      // copy (CREATE TABLE … AS SELECT creates no constraints), insert the
      // legacy row there, then run the real migration against it.
      await db.customStatement('ALTER TABLE todos RENAME TO _todos_v13');
      await db.customStatement(
        'CREATE TABLE todos AS SELECT * FROM _todos_v13 LIMIT 0',
      );
      final now = DateTime.now();
      await db.customStatement(
        "INSERT INTO todos (id, title, state, waiting_for, clarified, user_id, created_at) "
        "VALUES ('wf2', 'Legacy waiting', 'waiting_for', 'Bob', 1, '$_userId', '${now.toIso8601String()}')",
      );

      // Drive the real v13 migration.
      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 12, 13);

      final rows = await db.customSelect(
        'SELECT state, waiting_for FROM todos WHERE id = ?',
        variables: [Variable.withString('wf2')],
      ).get();
      expect(rows.length, 1);
      expect(rows.first.read<String>('state'), 'next_action');
      expect(rows.first.read<String?>('waiting_for'), 'Bob');
    });

    test('v13→v14 migration: in_progress rows become next_action; retired columns dropped; new tables created',
        () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // Simulate a v13 database by adding the columns that v14 drops.
      await db.customStatement(
        'ALTER TABLE todos ADD COLUMN in_progress_since TEXT',
      );
      await db.customStatement(
        'ALTER TABLE todos ADD COLUMN selected_for_today INTEGER',
      );
      await db.customStatement(
        'ALTER TABLE todos ADD COLUMN daily_selection_date TEXT',
      );

      // The v14 CHECK constraint rejects 'in_progress', so we use a
      // constraint-free CTAS copy to seed the legacy row.
      await db.customStatement('ALTER TABLE todos RENAME TO _todos_v13');
      await db.customStatement(
        'CREATE TABLE todos AS SELECT * FROM _todos_v13 LIMIT 0',
      );
      final now = DateTime.now();
      await db.customStatement(
        "INSERT INTO todos (id, title, state, clarified, user_id, created_at) "
        "VALUES ('ip1', 'In-progress task', 'in_progress', 1, '$_userId', '${now.toIso8601String()}')",
      );
      // Also insert a normal next_action row to verify it is untouched.
      await db.customStatement(
        "INSERT INTO todos (id, title, state, clarified, user_id, created_at) "
        "VALUES ('na1', 'Next action task', 'next_action', 1, '$_userId', '${now.toIso8601String()}')",
      );

      // Drop the new tables so the migration can recreate them.
      await db.customStatement('DROP TABLE IF EXISTS focus_session_tasks');
      await db.customStatement('DROP TABLE IF EXISTS focus_sessions');

      // Drive the real v14 migration path.
      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 13, 14);

      // in_progress → next_action.
      final rows = await db.customSelect(
        'SELECT id, state FROM todos ORDER BY id',
      ).get();
      expect(rows.length, 2);
      expect(rows.every((r) => r.read<String>('state') == 'next_action'), isTrue);

      // Retired columns must be gone.
      final cols = await db.customSelect('PRAGMA table_info(todos)').get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      expect(colNames, isNot(contains('in_progress_since')));
      expect(colNames, isNot(contains('selected_for_today')));
      expect(colNames, isNot(contains('daily_selection_date')));

      // New tables must exist.
      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name IN ('focus_sessions','focus_session_tasks')",
          )
          .get();
      final tableNames = tables.map((r) => r.read<String>('name')).toSet();
      expect(tableNames, containsAll(['focus_sessions', 'focus_session_tasks']));

      // focus_session_id must have been added to time_logs.
      final tlCols =
          await db.customSelect('PRAGMA table_info(time_logs)').get();
      final tlColNames = tlCols.map((r) => r.read<String>('name')).toSet();
      expect(tlColNames, contains('focus_session_id'));
    });

    test('v7→v8 migration drops blocked_by_todo_id column', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // Simulate a pre-v8 database by adding the column that v8 drops.
      await db.customStatement(
        'ALTER TABLE todos ADD COLUMN blocked_by_todo_id TEXT',
      );

      // Insert a row that previously had a blocker set.
      final now = DateTime.now();
      await db.customInsert(
        'INSERT INTO todos (id, title, state, blocked_by_todo_id, user_id, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('was-blocked'),
          Variable.withString('Was blocked task'),
          Variable.withString('next_action'),
          Variable.withString('some-blocker-id'),
          Variable.withString(_userId),
          Variable.withDateTime(now),
        ],
      );

      // Drive the real v8 migration path.
      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 7, 8);

      // Column must be gone.
      final cols =
          await db.customSelect('PRAGMA table_info(todos)').get();
      final colNames = cols.map((r) => r.read<String>('name')).toList();
      expect(colNames, isNot(contains('blocked_by_todo_id')));

      // Row data must have survived.
      final rows = await db.customSelect(
        'SELECT * FROM todos WHERE id = ?',
        variables: [Variable.withString('was-blocked')],
      ).get();
      expect(rows.length, 1);
      expect(rows.first.read<String>('title'), 'Was blocked task');
    });
  });
}
