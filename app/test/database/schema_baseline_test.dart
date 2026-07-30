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
    test('is 1 — a fresh file, with no ladder behind it', () async {
      final db = _openInMemory();
      addTearDown(db.close);
      expect(db.schemaVersion, 1);
      // Proves onCreate ran rather than onUpgrade.
      expect(
        await db.customSelect('PRAGMA user_version').getSingle().then(
              (r) => r.read<int>('user_version'),
            ),
        1,
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
      Future<void> insert() => db.customStatement(
            'INSERT INTO user_preferences (id, user_id, "key", value, updated_at) '
            "VALUES (?, 'u1', 'planning_time', '08:00', ?)",
            [DateTime.now().microsecondsSinceEpoch.toString(), now.toIso8601String()],
          );

      await insert();
      // One row per preference per user is what makes the LWW reconciliation in
      // `services/user_preferences_conflict.dart` well defined.
      await expectLater(insert(), throwsA(isA<Exception>()));
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
      expect(row.timeSpentMinutes, 0);
      expect(row.doneAt, isNull);
    });
  });
}
