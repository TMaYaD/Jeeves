/// The domain store's schema baseline: what `onCreate` builds, on version 1.
///
/// This file replaces the 28-step migration-ladder suite. That ladder existed to
/// carry a PowerSync-managed store forward while its application-visible names
/// were *views* — `ALTER TABLE` on a view throws, so every step was guarded on
/// `sqlite_master`, and the guards were most of what was under test. The store is
/// now a fresh Drift-owned file (ADR-0035) and the ladder has no store to run
/// against, so what is worth pinning is the *shape it produces*: the columns
/// retired over 28 versions must not come back, and the invariants those versions
/// established must be present from the first open.
///
/// A future schema change is an ordinary Drift migration — bump [schemaVersion]
/// to 2, add an `onUpgrade` step, and pin its effect here.
library;

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

/// The names `sqlite_master` holds for objects of [type], after `onCreate`.
Future<Set<String>> _objects(GtdDatabase db, String type) async {
  final rows = await db
      .customSelect(
        'SELECT name FROM sqlite_master WHERE type = ?',
        variables: [Variable<String>(type)],
      )
      .get();
  return rows.map((r) => r.read<String>('name')).toSet();
}

Future<List<Map<String, Object?>>> _columns(
  GtdDatabase db,
  String table,
) async {
  final rows = await db.customSelect('PRAGMA table_info($table)').get();
  return rows.map((r) => r.data).toList();
}

Future<Set<String>> _columnNames(GtdDatabase db, String table) async =>
    (await _columns(db, table)).map((c) => c['name'] as String).toSet();

void main() {
  setUpAll(configureSqliteForTests);

  group('schema version', () {
    test('is 2 — one onUpgrade step behind the fresh baseline', () async {
      final db = _openInMemory();
      addTearDown(db.close);
      expect(db.schemaVersion, 2);
      // A fresh file runs onCreate at the current version, not the ladder.
      expect(
        await db.customSelect('PRAGMA user_version').getSingle().then(
              (r) => r.read<int>('user_version'),
            ),
        2,
      );
    });
  });

  group('onCreate builds real tables', () {
    test('every declared table exists, and none of them is a view', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      final declared = db.allTables.map((t) => t.actualTableName).toSet();
      expect(declared, contains('todos'));
      expect(await _objects(db, 'table'), containsAll(declared));
      // The distinction the whole store swap turns on: `ALTER TABLE`, `changes()`
      // and `CREATE INDEX` all behave differently on a view, and the previous
      // store served these names as views.
      expect(await _objects(db, 'view'), isEmpty);
    });

    test('the dead-letter table is not among them', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // `sync_dead_letters` recorded non-retryable PowerSync upload failures.
      // The uploader is gone; the table went with it.
      expect(await _objects(db, 'table'), isNot(contains('sync_dead_letters')));
    });

    test('the actions(outcome_id, role) index is present', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // Installed by the storage engine before; declared on the table now. Its
      // absence would be a silent full scan per candidate Outcome behind the
      // Next List, which no other assertion here would notice.
      expect(await _objects(db, 'index'), contains('idx_actions_outcome_role'));
    });
  });

  group('columns retired across the old ladder stay retired', () {
    test('todos carries none of them', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      expect(
        await _columnNames(db, 'todos'),
        isNot(anyElement(isIn(const [
          // v15: collapsed to a constant, then dropped.
          'state',
          // v19 (migration 0022).
          'waiting_for',
          // v14.
          'in_progress_since',
          'selected_for_today',
          'daily_selection_date',
          // v8.
          'blocked_by_todo_id',
          // v28 (issue #525, ADR-0024) — `actions` is the only next-action grain.
          'next_action_text',
          // Dropped by the v2 onUpgrade (issue #604) — time spent is a
          // `SUM(time_logs)` derivation, never a stored cache (ADR-0030).
          'time_spent_minutes',
          // Never dropped by the ladder (SQLite DROP COLUMN was unreliable
          // across OS versions) and invisible to Drift; a fresh file simply
          // never has it. `done_at` is the completion record.
          'completed',
        ]))),
      );
    });

    test('the columns later versions added are all present', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      expect(
        await _columnNames(db, 'todos'),
        containsAll(const [
          'clarified', // v11
          'intent', // v10
          'done_at', // v12
          'last_clarified_at', // v19
          'last_next_action_completion_at', // v21
        ]),
      );
      expect(
        await _columnNames(db, 'time_logs'),
        containsAll(const [
          'focus_session_id', // v14
          'action_id', // v27 (issue #476, ADR-0001 story 6)
        ]),
      );
      expect(
        await _columnNames(db, 'focus_session_tasks'),
        containsAll(const [
          'id', // v17
          'disposition', // v16
          'user_id', // v22 (issue #381)
        ]),
      );
    });
  });

  group('declared invariants hold from the first open', () {
    test('user_preferences is unique per (user_id, key)', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      final now = DateTime.parse('2026-07-30T09:00:00.000Z');
      // Explicit, distinct ids: derive them from a clock and two calls landing
      // in the same microsecond would fail on the `id` primary key instead of
      // the constraint this test exists to pin.
      Future<void> insert(String id) => db.customStatement(
            'INSERT INTO user_preferences (id, user_id, "key", value, updated_at) '
            "VALUES (?, 'u1', 'planning_time', '08:00', ?)",
            [id, now.toIso8601String()],
          );

      await insert('p1');
      // One row per preference per user is what makes the LWW reconciliation in
      // `services/user_preferences_conflict.dart` well defined.
      await expectLater(insert('p2'), throwsA(isA<Exception>()));
    });

    test('todos defaults land without being supplied', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      await db.into(db.todos).insert(TodosCompanion(
            id: const Value('t1'),
            title: const Value('Ship it'),
            userId: const Value('u1'),
            createdAt: Value(DateTime.parse('2026-07-30T09:00:00.000Z')),
          ));

      final row = await db.select(db.todos).getSingle();
      expect(row.clarified, isTrue, reason: 'a created Outcome is clarified');
      expect(row.intent, 'next');
      expect(row.doneAt, isNull);
    });
  });

  group('v2 onUpgrade drops todos.time_spent_minutes', () {
    test('the upgrade drops the column and preserves every row', () async {
      // One raw sqlite3 database kept alive across two Drift opens: an
      // in-memory NativeDatabase is destroyed when its connection closes, so
      // the seed and the upgrade have to share the SAME underlying handle.
      // `closeUnderlyingOnClose: false` is what lets the first Drift
      // wrapper close without taking the data with it.
      final raw = sqlite3.openInMemory();
      addTearDown(raw.close);

      // Open 1: onCreate builds the v2 schema. Add the dropped column back and
      // rewind user_version to 1 so the second open sees a v1 store to upgrade.
      final seed = GtdDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      await seed.customStatement(
        'ALTER TABLE todos ADD COLUMN time_spent_minutes '
        'INTEGER NOT NULL DEFAULT 0',
      );

      final createdMs = DateTime.parse('2026-07-30T09:00:00.000Z')
          .millisecondsSinceEpoch;
      // Seed through raw SQL naming the column explicitly — the generated
      // companion no longer knows it — with a non-default value that must be
      // seen to have survived (well, its row must).
      await seed.customStatement(
        'INSERT INTO todos (id, title, user_id, created_at, intent, clarified, '
        '  time_spent_minutes) '
        "VALUES ('t1', 'Ship it', 'u1', ?, 'next', 1, 42)",
        [createdMs],
      );
      await seed.customStatement(
        'INSERT INTO todos (id, title, user_id, created_at, intent, clarified, '
        '  time_spent_minutes) '
        "VALUES ('t2', 'And another', 'u1', ?, 'maybe', 0, 0)",
        [createdMs],
      );
      // A time_logs child of t1: the drop recreates `todos`, so this proves the
      // FK survives the swap rather than being severed with the old table.
      await seed.customStatement(
        'INSERT INTO time_logs (id, user_id, task_id, started_at) '
        "VALUES ('tl1', 'u1', 't1', '2026-07-30T09:30:00.000Z')",
      );
      await seed.customStatement('PRAGMA user_version = 1');
      await seed.close();

      // Open 2: Drift sees user_version=1, schemaVersion=2, runs the onUpgrade.
      final upgraded = GtdDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      addTearDown(upgraded.close);

      expect(
        await upgraded.customSelect('PRAGMA user_version').getSingle().then(
              (r) => r.read<int>('user_version'),
            ),
        2,
      );
      expect(await _columnNames(upgraded, 'todos'),
          isNot(contains('time_spent_minutes')),
          reason: 'v2 drops the dead cache column');

      final rows = await upgraded
          .customSelect('SELECT id, title, intent, clarified, user_id '
              'FROM todos ORDER BY id')
          .get();
      expect(rows.map((r) => r.read<String>('id')), ['t1', 't2'],
          reason: 'no row lost in the table recreate');
      expect(rows.first.read<String>('title'), 'Ship it');
      expect(rows.first.read<String>('intent'), 'next');
      expect(rows.last.read<String>('intent'), 'maybe');

      // The FK child survived, still attributed to its parent.
      final logs = await upgraded
          .customSelect("SELECT task_id FROM time_logs WHERE id = 'tl1'")
          .get();
      expect(logs.single.read<String>('task_id'), 't1');
    });
  });
}
