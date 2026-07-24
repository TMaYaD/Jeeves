import 'package:drift/drift.dart' hide isNull;
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

      final items = await db.inboxDao.watchInbox().first;
      expect(items.length, 1);
      expect(items.first.timeSpentMinutes, 0);
    });

    test('v2 schema: old data (no new columns) survives intact', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      final now = DateTime.now();
      // Insert a row omitting the v2+ columns (they use DB defaults).
      // Uses clarified=0 to simulate a post-migration inbox item (pre-v2
      // 'inbox' rows had state='inbox'; v15 removed the state column entirely).
      await db.customInsert(
        'INSERT INTO todos (id, title, clarified, user_id, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('legacy'),
          Variable.withString('Legacy task'),
          Variable.withInt(0),
          Variable.withString(_userId),
          Variable.withDateTime(now),
          Variable.withDateTime(now),
        ],
      );

      final items = await db.inboxDao.watchInbox().first;
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
      final items = await db.inboxDao.watchInbox().first;
      expect(items.length, 1);
      expect(items.first.title, 'Legacy v1 task');
      expect(items.first.timeSpentMinutes, 0);
    });

    test('v12→v13 migration: todos survive the migration intact', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      final now = DateTime.now();
      await db.customInsert(
        'INSERT INTO todos (id, title, clarified, user_id, created_at) '
        'VALUES (?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('wf1'),
          Variable.withString('Waiting task'),
          Variable.withInt(1),
          Variable.withString(_userId),
          Variable.withDateTime(now),
        ],
      );

      // Drive the v13 migration path directly (simulating upgrade from v12).
      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 12, 13);

      // Row data must have survived.
      final rows = await db.customSelect(
        'SELECT title FROM todos WHERE id = ?',
        variables: [Variable.withString('wf1')],
      ).get();
      expect(rows.length, 1);
      expect(rows.first.read<String>('title'), 'Waiting task');
    });

    test('v20→v21 migration: next_action_text and last_next_action_completion_at added', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // Simulate a pre-v21 database by recreating todos without the v21 columns.
      await db.customStatement('DROP TABLE IF EXISTS todos');
      await db.customStatement('''
        CREATE TABLE "todos" (
          "id" TEXT NOT NULL,
          "title" TEXT NOT NULL,
          "clarified" INTEGER NOT NULL DEFAULT 1,
          "user_id" TEXT NOT NULL,
          "created_at" TEXT NOT NULL,
          PRIMARY KEY ("id")
        )
      ''');

      // Seed a row at the pre-v21 state.
      final now = DateTime.now();
      await db.customInsert(
        'INSERT INTO todos (id, title, clarified, user_id, created_at) '
        'VALUES (?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('v20t1'),
          Variable.withString('Legacy task'),
          Variable.withInt(1),
          Variable.withString(_userId),
          Variable.withDateTime(now),
        ],
      );

      // Drive the v21 migration.
      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 20, 21);

      // Both new columns must exist.
      final cols = await db.customSelect('PRAGMA table_info(todos)').get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      expect(colNames, contains('next_action_text'));
      expect(colNames, contains('last_next_action_completion_at'));

      // Row must have survived with both columns NULL.
      final rows = await db.customSelect(
        'SELECT title, next_action_text, last_next_action_completion_at '
        'FROM todos WHERE id = ?',
        variables: [Variable.withString('v20t1')],
      ).get();
      expect(rows.length, 1);
      expect(rows.first.read<String>('title'), 'Legacy task');
      expect(rows.first.read<String?>('next_action_text'), isNull);
      expect(rows.first.read<String?>('last_next_action_completion_at'), isNull);
    });

    test('v18→v19 migration: waiting_for dropped, last_clarified_at added', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // Simulate a v18 database by re-adding the waiting_for column.
      await db.customStatement(
        'ALTER TABLE todos ADD COLUMN waiting_for TEXT',
      );

      // Seed a row with a waiting_for value.
      final now = DateTime.now();
      await db.customInsert(
        'INSERT INTO todos (id, title, waiting_for, clarified, user_id, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('v19t1'),
          Variable.withString('Delegated task'),
          Variable.withString('Alice'),
          Variable.withInt(1),
          Variable.withString(_userId),
          Variable.withDateTime(now),
        ],
      );

      // Drive the v19 migration.
      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 18, 19);

      // waiting_for must be gone.
      final cols = await db.customSelect('PRAGMA table_info(todos)').get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      expect(colNames, isNot(contains('waiting_for')));

      // last_clarified_at must exist.
      expect(colNames, contains('last_clarified_at'));

      // Row must have survived.
      final rows = await db.customSelect(
        'SELECT title, last_clarified_at FROM todos WHERE id = ?',
        variables: [Variable.withString('v19t1')],
      ).get();
      expect(rows.length, 1);
      expect(rows.first.read<String>('title'), 'Delegated task');
      // last_clarified_at should default to NULL for migrated rows (no backfill).
      expect(rows.first.read<String?>('last_clarified_at'), isNull);
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

      // Use a constraint-free CTAS copy to add the legacy state column (removed
      // in v15) so we can seed in_progress rows and exercise the v14 collapse.
      await db.customStatement('ALTER TABLE todos RENAME TO _todos_v13');
      await db.customStatement(
        'CREATE TABLE todos AS SELECT * FROM _todos_v13 LIMIT 0',
      );
      // Add state column back (it existed pre-v15) to seed legacy rows.
      await db.customStatement('ALTER TABLE todos ADD COLUMN state TEXT');
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

      // Simulate pre-v14 time_logs: no focus_session_id column yet.
      await db.customStatement(
          'ALTER TABLE time_logs RENAME TO _time_logs_v13');
      await db.customStatement(
        'CREATE TABLE time_logs ('
        '  id TEXT NOT NULL PRIMARY KEY,'
        '  user_id TEXT NOT NULL,'
        '  task_id TEXT NOT NULL,'
        '  started_at TEXT NOT NULL,'
        '  ended_at TEXT'
        ')',
      );

      // Drive the real v14 migration path.
      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 13, 14);

      // Both rows must have survived (state column is dropped by v15 in the same run).
      final rows = await db.customSelect('SELECT id FROM todos ORDER BY id').get();
      expect(rows.length, 2);

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
        'INSERT INTO todos (id, title, blocked_by_todo_id, user_id, created_at) '
        'VALUES (?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('was-blocked'),
          Variable.withString('Was blocked task'),
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

    test(
        'v15→v16 migration: disposition column added to focus_session_tasks; '
        'existing rows have NULL disposition; accepts valid values', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // Simulate a v15 database: focus_session_tasks without a disposition col.
      // Drop and recreate the table without the disposition column.
      await db.customStatement('DROP TABLE IF EXISTS focus_session_tasks');
      await db.customStatement(
        'CREATE TABLE focus_session_tasks ('
        '  focus_session_id TEXT NOT NULL,'
        '  task_id TEXT NOT NULL,'
        '  position INTEGER NOT NULL,'
        '  PRIMARY KEY (focus_session_id, task_id)'
        ')',
      );

      // Seed a pre-migration row.
      await db.customStatement(
        "INSERT INTO focus_session_tasks (focus_session_id, task_id, position) "
        "VALUES ('session1', 'task1', 0)",
      );

      // Drive the v16 migration path.
      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 15, 16);

      // The disposition column must now exist.
      final cols = await db
          .customSelect('PRAGMA table_info(focus_session_tasks)')
          .get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      expect(colNames, contains('disposition'));

      // Existing rows have NULL disposition.
      final rows = await db.customSelect(
        'SELECT disposition FROM focus_session_tasks WHERE task_id = ?',
        variables: [Variable.withString('task1')],
      ).get();
      expect(rows.length, 1);
      expect(rows.first.read<String?>('disposition'), isNull);

      // Valid values must be accepted.
      for (final value in ['rollover', 'leave', 'maybe']) {
        await db.customStatement(
          'UPDATE focus_session_tasks SET disposition = ? '
          "WHERE focus_session_id = 'session1' AND task_id = 'task1'",
          [value],
        );
      }
    });

    test(
        'v21→v22 migration: user_id added to focus_session_tasks and '
        'backfilled from the parent focus_sessions row', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // Simulate a v21 database: focus_session_tasks without a user_id column.
      await db.customStatement('DROP TABLE IF EXISTS focus_session_tasks');
      await db.customStatement(
        'CREATE TABLE focus_session_tasks ('
        '  id TEXT,'
        '  focus_session_id TEXT NOT NULL,'
        '  task_id TEXT NOT NULL,'
        '  position INTEGER NOT NULL,'
        '  disposition TEXT,'
        '  PRIMARY KEY (focus_session_id, task_id)'
        ')',
      );

      // Seed a parent session and a pre-migration junction row.
      await db.customStatement(
        "INSERT INTO focus_sessions (id, user_id, started_at) "
        "VALUES ('session1', '$_userId', '2026-07-12T00:00:00.000Z')",
      );
      await db.customStatement(
        "INSERT INTO focus_session_tasks (id, focus_session_id, task_id, position) "
        "VALUES ('fst1', 'session1', 'task1', 0)",
      );

      // Drive the v22 migration path.
      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 21, 22);

      // The user_id column must now exist.
      final cols = await db
          .customSelect('PRAGMA table_info(focus_session_tasks)')
          .get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      expect(colNames, contains('user_id'));

      // Existing rows must be backfilled from the parent session.
      final rows = await db.customSelect(
        'SELECT user_id FROM focus_session_tasks WHERE id = ?',
        variables: [Variable.withString('fst1')],
      ).get();
      expect(rows.length, 1);
      expect(rows.first.read<String?>('user_id'), _userId);
    });

    test('v19→v20 migration: user_preferences table created with UNIQUE(user_id, key)',
        () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // Simulate a v19 database by dropping the table that onCreate creates.
      await db.customStatement('DROP TABLE IF EXISTS user_preferences');

      final tablesBefore = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'user_preferences'",
      ).get();
      expect(tablesBefore.length, 0);

      // Drive the real v20 migration path.
      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 19, 20);

      final tables = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'user_preferences'",
      ).get();
      expect(tables.length, 1);

      final cols = await db.customSelect('PRAGMA table_info(user_preferences)').get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      expect(colNames, containsAll(['id', 'user_id', 'key', 'value', 'updated_at']));

      // Upsert via the DAO should not throw (UNIQUE constraint handled by ON CONFLICT).
      await db.userPreferencesDao.set(_userId, 'k', '"v1"');
      await db.userPreferencesDao.set(_userId, 'k', '"v2"');
      expect(await db.userPreferencesDao.get(_userId, 'k'), '"v2"');
    });

    test(
        'v23→v24 migration: captures, capture_outcomes and capture_tags tables '
        'created (issue #184)', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // Simulate a v23 database by dropping the tables onCreate builds.
      for (final t in ['capture_tags', 'capture_outcomes', 'captures']) {
        await db.customStatement('DROP TABLE IF EXISTS $t');
      }

      // Drive the real v24 migration path.
      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 23, 24);

      final tables = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name IN ('captures', 'capture_outcomes', 'capture_tags')",
      ).get();
      expect(tables.map((r) => r.read<String>('name')).toSet(),
          {'captures', 'capture_outcomes', 'capture_tags'});

      // The DAO round-trips against the freshly-created tables.
      await db.captureDao.insertCapture(CapturesCompanion(
        id: const Value('c1'),
        title: const Value('after migration'),
        userId: Value(_userId),
        createdAt: Value(DateTime.now()),
      ));
      final inbox = await db.captureDao.watchInbox().first;
      expect(inbox.map((c) => c.id), ['c1']);

      // Both junction tables round-trip too, so a missing column or
      // constraint in capture_outcomes / capture_tags fails here rather
      // than passing unnoticed behind the captures-only check above.
      await db.into(db.todos).insert(TodosCompanion(
            id: const Value('o1'),
            title: const Value('carved outcome'),
            userId: Value(_userId),
            createdAt: Value(DateTime.now()),
          ));
      final tagId = await db.tagDao.findOrCreateTag('work', 'context', _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      await db.captureDao.assignTagHint('c1', tagId, _userId);
      expect(await db.captureDao.outcomeIdsForCapture('c1'), ['o1']);
      expect(await db.captureDao.tagHintIdsForCapture('c1'), {tagId});
    });

    test(
        'v24→v25 migration: focus_session_dispositions table created '
        '(issue #418), existing data preserved', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // Seed a pre-existing todo so we can assert the migration is
      // non-destructive to unrelated data.
      await db.into(db.todos).insert(TodosCompanion(
            id: const Value('pre'),
            title: const Value('before migration'),
            userId: Value(_userId),
            createdAt: Value(DateTime.now()),
          ));

      // Simulate a v24 database by dropping the table onCreate builds.
      await db.customStatement('DROP TABLE IF EXISTS focus_session_dispositions');

      // Drive the real v25 migration path.
      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 24, 25);

      final tables = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name = 'focus_session_dispositions'",
      ).get();
      expect(tables.length, 1);

      final cols = await db
          .customSelect('PRAGMA table_info(focus_session_dispositions)')
          .get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      expect(colNames,
          containsAll(['id', 'focus_session_id', 'task_id', 'disposition', 'user_id']));

      // Unrelated data survived the migration.
      final pre =
          await (db.select(db.todos)..where((t) => t.id.equals('pre'))).getSingle();
      expect(pre.title, 'before migration');

      // The freshly-created table round-trips a write.
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: [],
      );
      await db.into(db.focusSessionDispositions).insert(
            FocusSessionDispositionsCompanion(
              id: const Value('d1'),
              focusSessionId: Value(sessionId),
              taskId: const Value('pre'),
              disposition: const Value('rollover'),
              userId: Value(_userId),
            ),
          );
      final rows = await db.customSelect(
        'SELECT task_id, disposition FROM focus_session_dispositions',
      ).get();
      expect(rows.length, 1);
      expect(rows.first.read<String>('disposition'), 'rollover');
    });
  });

  group('MigrationService — user_preferences LWW reassignment', () {
    // Mirrors the 3-step UPDATE logic in LocalDataMigrationService.migrate()
    // (migration_service.dart). Any changes to that method must be reflected here.
    Future<void> runMigration(GtdDatabase db, String fromUserId, String toUserId) async {
      // Step 1: reassign non-conflicting rows.
      await db.customStatement(
        '''
        UPDATE user_preferences
        SET user_id = ?
        WHERE user_id = ?
          AND "key" NOT IN (
            SELECT "key" FROM user_preferences WHERE user_id = ?
          )
        ''',
        [toUserId, fromUserId, toUserId],
      );
      // Step 2: LWW — update toUserId row when fromUserId row is newer.
      await db.customStatement(
        '''
        UPDATE user_preferences
        SET value = (
          SELECT src.value FROM user_preferences src
          WHERE src.user_id = ? AND src."key" = user_preferences."key"
        ),
        updated_at = (
          SELECT src.updated_at FROM user_preferences src
          WHERE src.user_id = ? AND src."key" = user_preferences."key"
        )
        WHERE user_id = ?
          AND EXISTS (
            SELECT 1 FROM user_preferences src
            WHERE src.user_id = ?
              AND src."key" = user_preferences."key"
              AND src.updated_at > user_preferences.updated_at
          )
        ''',
        [fromUserId, fromUserId, toUserId, fromUserId],
      );
      // Step 3: remove all remaining fromUserId rows.
      await db.customStatement(
        'DELETE FROM user_preferences WHERE user_id = ?',
        [fromUserId],
      );
    }

    test('migrate local→userId reassigns all user_preference rows', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      await db.userPreferencesDao.set('local', 'sprint', '"20"');
      await db.userPreferencesDao.set('local', 'break', '"3"');

      await runMigration(db, 'local', _userId);

      final result = await db.userPreferencesDao.getAll(_userId);
      expect(result.keys, containsAll(['sprint', 'break']));
      expect(result['sprint'], '"20"');

      final localRows = await db.userPreferencesDao.getAll('local');
      expect(localRows.isEmpty, isTrue);
    });

    test('LWW: local row newer → server row updated', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      await db.customStatement(
        '''INSERT INTO user_preferences (id, user_id, "key", value, updated_at)
           VALUES ('sid', ?, 'k', '"server"', '2026-01-01T00:00:00.000Z')''',
        [_userId],
      );
      await db.customStatement(
        '''INSERT INTO user_preferences (id, user_id, "key", value, updated_at)
           VALUES ('lid', 'local', 'k', '"local"', '2026-06-01T00:00:00.000Z')''',
      );

      await runMigration(db, 'local', _userId);

      // Local was newer → server row value updated to "local".
      expect(await db.userPreferencesDao.get(_userId, 'k'), '"local"');
      expect(await db.userPreferencesDao.get('local', 'k'), isNull);
    });

    test('LWW: server row newer → server row unchanged', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      await db.customStatement(
        '''INSERT INTO user_preferences (id, user_id, "key", value, updated_at)
           VALUES ('sid', ?, 'k', '"server"', '2026-06-01T00:00:00.000Z')''',
        [_userId],
      );
      await db.customStatement(
        '''INSERT INTO user_preferences (id, user_id, "key", value, updated_at)
           VALUES ('lid', 'local', 'k', '"local"', '2026-01-01T00:00:00.000Z')''',
      );

      await runMigration(db, 'local', _userId);

      // Server was newer → value unchanged; local row deleted.
      expect(await db.userPreferencesDao.get(_userId, 'k'), '"server"');
      expect(await db.userPreferencesDao.get('local', 'k'), isNull);
    });
  });
}
