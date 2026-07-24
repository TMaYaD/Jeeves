/// v25→v26 migration: the `actions` table is created and one `current` Action
/// is backfilled from every Outcome with a non-blank `next_action_text`
/// (issue #471, ADR-0001 story 1). The convergence guarantee (ADR-0019) rests
/// on this mirroring the server backfill (Alembic 0028) exactly: same id, same
/// derived fields, whitespace/NULL cursors minting nothing.
library;

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/action_ids.dart';
import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

const _userId = 'test-user';

/// Seed an Outcome directly through the Drift API so DateTimes round-trip via
/// storeDateTimeAsText exactly as production stores them.
Future<void> _seedTodo(
  GtdDatabase db, {
  required String id,
  String? nextActionText,
  String? energyLevel,
  int? timeEstimate,
  DateTime? lastClarifiedAt,
  required DateTime createdAt,
}) async {
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        userId: const Value(_userId),
        createdAt: Value(createdAt),
        nextActionText: Value(nextActionText),
        energyLevel: Value(energyLevel),
        timeEstimate: Value(timeEstimate),
        lastClarifiedAt: Value(lastClarifiedAt),
      ));
}

Future<List<Map<String, Object?>>> _actions(GtdDatabase db) async {
  final rows = await db.customSelect('SELECT * FROM actions').get();
  return rows.map((r) => r.data).toList();
}

void main() {
  setUpAll(configureSqliteForTests);

  group('v25→v26 migration: actions table + current-Action backfill', () {
    test(
        'mints one current Action per non-blank cursor with correct fields; '
        'skips blank / whitespace / NULL', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // Simulate a v25 database: drop the actions table onCreate built.
      await db.customStatement('DROP TABLE IF EXISTS actions');

      final created = DateTime.parse('2026-06-01T09:00:00.000Z');
      final clarified = DateTime.parse('2026-07-01T10:00:00.000Z');

      await _seedTodo(db,
          id: 'real',
          nextActionText: 'call the plumber',
          energyLevel: 'low',
          timeEstimate: 15,
          lastClarifiedAt: clarified,
          createdAt: created);
      await _seedTodo(db,
          id: 'no-clarify',
          nextActionText: 'x',
          lastClarifiedAt: null,
          createdAt: created);
      await _seedTodo(db, id: 'null', nextActionText: null, createdAt: created);
      await _seedTodo(db, id: 'empty', nextActionText: '', createdAt: created);
      await _seedTodo(db, id: 'ws', nextActionText: '     ', createdAt: created);

      // Drive the real v26 migration path.
      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 25, 26);

      final rows = await _actions(db);
      final byOutcome = {for (final r in rows) r['outcome_id'] as String: r};

      // Exactly the two non-blank Outcomes minted a row.
      expect(byOutcome.keys.toSet(), {'real', 'no-clarify'});

      final real = byOutcome['real']!;
      expect(real['id'], backfillActionIdFor('real'));
      expect(real['user_id'], _userId);
      expect(real['text'], 'call the plumber');
      expect(real['role'], 'current');
      expect(real['energy_level'], 'low');
      expect(real['time_estimate'], 15);
      expect(real['position'], isNull);
      expect(real['updated_at'], isNull);
      expect(real['done_at'], isNull);
      // created_at derives from last_clarified_at (the cursor-set proxy).
      final clarifiedText = await db.customSelect(
        "SELECT last_clarified_at FROM todos WHERE id = 'real'",
      ).getSingle();
      expect(real['created_at'], clarifiedText.read<String>('last_clarified_at'));

      // With no last_clarified_at, created_at falls back to the Outcome's.
      final noClarify = byOutcome['no-clarify']!;
      final createdText = await db.customSelect(
        "SELECT created_at FROM todos WHERE id = 'no-clarify'",
      ).getSingle();
      expect(noClarify['created_at'], createdText.read<String>('created_at'));
    });

    test('text is copied verbatim (no trim) for a qualifying cursor', () async {
      final db = _openInMemory();
      addTearDown(db.close);
      await db.customStatement('DROP TABLE IF EXISTS actions');

      await _seedTodo(db,
          id: 'pad',
          nextActionText: '  keep spaces  ',
          createdAt: DateTime.parse('2026-06-01T09:00:00.000Z'));

      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 25, 26);

      final rows = await _actions(db);
      expect(rows.single['text'], '  keep spaces  ');
    });

    test('re-running the v26 step mints no duplicate (NOT EXISTS guard)',
        () async {
      final db = _openInMemory();
      addTearDown(db.close);
      await db.customStatement('DROP TABLE IF EXISTS actions');

      await _seedTodo(db,
          id: 't1',
          nextActionText: 'do it',
          createdAt: DateTime.parse('2026-06-01T09:00:00.000Z'));

      final m = db.createMigrator();
      await db.migration.onUpgrade(m, 25, 26);
      // A second pass (drift-recovery re-run): the table already exists and the
      // deterministic id already present → nothing new is inserted.
      await db.migration.onUpgrade(m, 25, 26);

      final rows = await _actions(db);
      expect(rows.length, 1);
      expect(rows.single['id'], backfillActionIdFor('t1'));
    });

    test('an Outcome that already has its backfill row is left untouched',
        () async {
      // Convergence: a device that downloaded the server backfill row before
      // migrating must not overwrite it. Pre-insert the row, then migrate.
      final db = _openInMemory();
      addTearDown(db.close);

      final createdAt = DateTime.parse('2026-06-01T09:00:00.000Z');
      await _seedTodo(db,
          id: 't1', nextActionText: 'local text', createdAt: createdAt);

      // Simulate the already-synced server row (different text/energy).
      await db.customStatement('DROP TABLE IF EXISTS actions');
      final m = db.createMigrator();
      await m.createTable(db.actions);
      await db.customStatement(
        "INSERT INTO actions (id, outcome_id, user_id, text, role, created_at) "
        "VALUES (?, 't1', ?, 'server text', 'current', ?)",
        [backfillActionIdFor('t1'), _userId, '2026-05-01T00:00:00.000Z'],
      );

      await db.migration.onUpgrade(m, 25, 26);

      final rows = await _actions(db);
      expect(rows.length, 1);
      // The pre-existing (server) row wins — the local backfill skipped it.
      expect(rows.single['text'], 'server text');
    });
  });
}
