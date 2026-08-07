/// The domain store's schema baseline: what `onCreate` builds, on version 1.
///
/// This file replaces the 28-step migration-ladder suite. That ladder existed to
/// carry a PowerSync-managed store forward while its application-visible names
/// were *views* — `ALTER TABLE` on a view throws, so every step was guarded on
/// `sqlite_master`, and the guards were most of what was under test. The store is
/// now a fresh Drift-owned file and the ladder has no store to run
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

/// The indexes SQLite created for [table]'s `UNIQUE (...)` **table constraints**.
///
/// `PRAGMA index_list` reports `origin` as `pk` for a primary key, `u` for a
/// `UNIQUE` clause inside the `CREATE TABLE`, and `c` for an explicit
/// `CREATE UNIQUE INDEX`. Filtering on `u` is the only way to say "the table
/// declares this pair unique" — and the only shape that can assert the *absence*
/// of one. An insert-throws assertion cannot: once a constraint is gone, the
/// insert succeeding is the expected state, so that shape passes whether or not
/// the migration ever ran.
Future<List<String>> _uniqueConstraintIndexes(
  GtdDatabase db,
  String table,
) async {
  final rows = await db.customSelect("PRAGMA index_list('$table')").get();
  return [
    for (final row in rows)
      if (row.read<String>('origin') == 'u') row.read<String>('name'),
  ];
}

/// Every row of [table] as full maps, ordered by [orderBy] — contents, not just
/// a count, because a recreate that dropped a column or reordered the copy would
/// keep the count intact.
Future<List<Map<String, Object?>>> _rows(
  GtdDatabase db,
  String table, {
  String orderBy = 'id',
}) async {
  final rows =
      await db.customSelect('SELECT * FROM $table ORDER BY $orderBy').get();
  return [for (final row in rows) row.data];
}

void main() {
  setUpAll(configureSqliteForTests);

  group('schema version', () {
    test('is 3 — two onUpgrade steps behind the fresh baseline', () async {
      final db = _openInMemory();
      addTearDown(db.close);
      expect(db.schemaVersion, 3);
      // A fresh file runs onCreate at the current version, not the ladder.
      expect(
        await db.customSelect('PRAGMA user_version').getSingle().then(
              (r) => r.read<int>('user_version'),
            ),
        3,
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
          // v28 (issue #525) — `actions` is the only next-action grain.
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

    test('tags declares no (name, type) uniqueness, user_preferences still does',
        () async {
      // The asymmetry is the whole point (ADR-0043). A preference's entity id is
      // *derived* from `(workspace, key)`, so two devices writing the same
      // preference are two writes to one entity and its constraint is safe. A Tag
      // id is client-random by protocol policy, so two devices creating "Alice"
      // fork into two entities — reduced state can hold both, and a projection of
      // reduced state that could not represent them would raise instead of
      // converging (#605).
      final db = _openInMemory();
      addTearDown(db.close);

      expect(await _uniqueConstraintIndexes(db, 'tags'), isEmpty,
          reason: '(name, type) is an eventual invariant the DomainReconciler '
              'folds towards, not a schema constraint');
      // The control: the same detection *does* find one where one exists, so an
      // empty result above is a fact about `tags` rather than about the pragma.
      expect(await _uniqueConstraintIndexes(db, 'user_preferences'),
          hasLength(1));
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

      // Open 2: Drift sees user_version=1 and schemaVersion=3, so it runs the
      // whole ladder — the v2 drop asserted here, and the v3 `tags` recreate the
      // group below owns.
      final upgraded = GtdDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      addTearDown(upgraded.close);

      expect(
        await upgraded.customSelect('PRAGMA user_version').getSingle().then(
              (r) => r.read<int>('user_version'),
            ),
        3,
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

  group('v3 onUpgrade drops the tags (name, type) uniqueness', () {
    /// A faithful v2 `tags` table: the current declaration with the retired
    /// `UNIQUE (name, type)` clause put back.
    ///
    /// Spliced onto the CREATE statement Drift itself emitted rather than
    /// hand-written, so the fixture cannot drift from the real column definitions
    /// (lengths, defaults, nullability) and quietly stop being a v2 store.
    Future<void> reinstateV2TagsTable(GtdDatabase seed) async {
      final createSql = (await seed
              .customSelect("SELECT sql FROM sqlite_master "
                  "WHERE type = 'table' AND name = 'tags'")
              .getSingle())
          .read<String>('sql');
      expect(createSql, isNot(contains('UNIQUE')),
          reason: 'onCreate must already build the v3 shape');
      await seed.customStatement('DROP TABLE tags');
      await seed.customStatement(
        createSql.replaceFirst(RegExp(r'\)\s*$'), ', UNIQUE (name, type))'),
      );
    }

    test('the upgrade drops the constraint and preserves every row', () async {
      // One raw sqlite3 handle across two Drift opens, for the reason the v2 test
      // states: an in-memory NativeDatabase dies with its connection.
      final raw = sqlite3.openInMemory();
      addTearDown(raw.close);

      final seed = GtdDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      // Registered at construction rather than left to the explicit close below:
      // every fixture assertion between here and there would otherwise leak this
      // handle on the failing path. The explicit close stays where it is and is
      // still load-bearing — `upgraded` opens over the same `raw`, so this one
      // has to be gone first — which is why the teardown only covers the case
      // where the test never reached it.
      var seedClosed = false;
      Future<void> closeSeed() async {
        if (seedClosed) return;
        seedClosed = true;
        await seed.close();
      }

      addTearDown(closeSeed);
      await reinstateV2TagsTable(seed);

      final createdMs =
          DateTime.parse('2026-07-30T09:00:00.000Z').millisecondsSinceEpoch;
      await seed.customStatement(
        'INSERT INTO tags (id, name, color, type, user_id) '
        "VALUES ('tag-alice', 'Alice', '#ff8800', 'person', 'u1')",
      );
      await seed.customStatement(
        'INSERT INTO tags (id, name, color, type, user_id) '
        "VALUES ('tag-home', 'Home', NULL, 'context', 'u1')",
      );
      await seed.customStatement(
        'INSERT INTO todos (id, title, user_id, created_at, intent, clarified) '
        "VALUES ('t1', 'Ring Alice', 'u1', ?, 'next', 1)",
        [createdMs],
      );
      await seed.customStatement(
        'INSERT INTO todo_tags (id, todo_id, tag_id, user_id) '
        "VALUES ('tt1', 't1', 'tag-alice', 'u1')",
      );
      await seed.customStatement(
        'INSERT INTO captures (id, title, created_at, user_id) '
        "VALUES ('c1', 'ring Alice back', ?, 'u1')",
        [createdMs],
      );
      await seed.customStatement(
        'INSERT INTO capture_tags (id, capture_id, tag_id, user_id) '
        "VALUES ('ct1', 'c1', 'tag-alice', 'u1')",
      );
      // **A pre-existing orphan** — the residue `TagDao.merge` leaves behind by
      // repointing only `todo_tags` (#645). FK enforcement is off (#637), so it is
      // on real users' disks today, and the recreate has to tolerate it: `tags` is
      // dropped and rebuilt mid-migration, and `capture_tags.tag_id` declares
      // `ON DELETE CASCADE`, so a migration that ran with enforcement on would
      // silently delete every tag hint instead of upgrading.
      await seed.customStatement(
        'INSERT INTO capture_tags (id, capture_id, tag_id, user_id) '
        "VALUES ('ct-orphan', 'c1', 'tag-long-gone', 'u1')",
      );

      final tagsBefore = await _rows(seed, 'tags');
      final todoTagsBefore = await _rows(seed, 'todo_tags');
      final captureTagsBefore = await _rows(seed, 'capture_tags');
      expect(await _uniqueConstraintIndexes(seed, 'tags'), hasLength(1),
          reason: 'the fixture is only a v2 store if the constraint is there');

      await seed.customStatement('PRAGMA user_version = 2');
      await closeSeed();

      final upgraded = GtdDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      addTearDown(upgraded.close);

      expect(
        await upgraded.customSelect('PRAGMA user_version').getSingle().then(
              (r) => r.read<int>('user_version'),
            ),
        3,
      );
      expect(await _uniqueConstraintIndexes(upgraded, 'tags'), isEmpty,
          reason: 'v3 drops UNIQUE (name, type)');

      // Data integrity is absolute: same rows, same contents, in all three
      // tables the recreate could have touched.
      expect(await _rows(upgraded, 'tags'), tagsBefore);
      expect(await _rows(upgraded, 'todo_tags'), todoTagsBefore);
      expect(await _rows(upgraded, 'capture_tags'), captureTagsBefore);
      expect(
        (await _rows(upgraded, 'capture_tags'))
            .map((row) => row['tag_id'])
            .toSet(),
        {'tag-alice', 'tag-long-gone'},
        reason: 'the orphan survives as the dangling reference it was',
      );

      // And the point of the drop: a peer's duplicate pair can now land.
      await upgraded.customStatement(
        'INSERT INTO tags (id, name, color, type, user_id) '
        "VALUES ('tag-alice-peer', 'Alice', '#00ff88', 'person', 'u1')",
      );
      expect(await _rows(upgraded, 'tags'), hasLength(3));
    });
  });
}
