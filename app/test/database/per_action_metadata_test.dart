/// Per-Action metadata: energy level and time estimate live on the Action
/// (ADR-0001 story 7, issue #477).
///
/// Drives the real DAOs against an in-memory SQLite database (`actions` a real
/// table). Covers the write path (the [TodoDao.updateFields] metadata
/// mirror, D3 Actionless-draft seeding of a birth Action, and the D4
/// supersession mirror that keeps the sweep from resurrecting stale metadata)
/// and the read path (the D2 COALESCE hydration: current Action's value, else
/// the Outcome column — so Actionless and legacy stores fall through
/// unchanged).
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/search_query.dart';
import '../test_helpers.dart';

const _userId = 'test-user';
final _t0 = DateTime.parse('2026-07-01T09:00:00.000Z');
final _t1 = DateTime.parse('2026-07-01T10:00:00.000Z');
final _t2 = DateTime.parse('2026-07-01T11:00:00.000Z');

Future<void> _seedOutcome(
  GtdDatabase db, {
  String id = 'o1',
  String title = 'Outcome',
  String? energyLevel,
  int? timeEstimate,
  bool clarified = true,
  String intent = 'next',
}) async {
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        userId: const Value(_userId),
        createdAt: Value(_t0),
        clarified: Value(clarified),
        intent: Value(intent),
        energyLevel: Value(energyLevel),
        timeEstimate: Value(timeEstimate),
      ));
}

/// Raw `todos` columns (bypasses the effective projection), to assert the
/// write-mirror invariant on the physical columns.
Future<({Object? energy, Object? time})> _todoColumns(
  GtdDatabase db,
  String id,
) async {
  final row = await db
      .customSelect(
        'SELECT energy_level, time_estimate FROM todos WHERE id = ?',
        variables: [Variable<String>(id)],
      )
      .getSingle();
  return (
    energy: row.data['energy_level'],
    time: row.data['time_estimate'],
  );
}

/// A `current` Action's raw metadata, or null when Actionless.
Future<({String id, Object? energy, Object? time})?> _current(
  GtdDatabase db,
  String outcomeId,
) async {
  final rows = await db
      .customSelect(
        "SELECT id, energy_level, time_estimate FROM actions "
        "WHERE outcome_id = ? AND role = 'current'",
        variables: [Variable<String>(outcomeId)],
      )
      .get();
  if (rows.isEmpty) return null;
  final r = rows.single.data;
  return (
    id: r['id'] as String,
    energy: r['energy_level'],
    time: r['time_estimate'],
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  group('updateFields metadata mirror (D1)', () {
    test('writes the current Action AND mirrors the Outcome columns; the '
        'hydrated read reflects the Action grain', () async {
      await _seedOutcome(db);
      await db.actionDao.setCurrentAction('o1', 'draft an email', now: _t1);

      await db.todoDao
          .updateFields('o1', energyLevel: 'high', timeEstimate: 45);

      final cur = await _current(db, 'o1');
      expect(cur!.energy, 'high', reason: 'Action carries the new metadata');
      expect(cur.time, 45);

      final cols = await _todoColumns(db, 'o1');
      expect(cols.energy, 'high', reason: 'Outcome columns stay mirrored (D1)');
      expect(cols.time, 45);

      final todo = await db.todoDao.getTodo('o1');
      expect(todo!.energyLevel, 'high');
      expect(todo.timeEstimate, 45);
    });

    test('clearEnergyLevel nulls both the Action and the Outcome column',
        () async {
      await _seedOutcome(db, energyLevel: 'low', timeEstimate: 30);
      await db.actionDao.setCurrentAction('o1', 'do it', now: _t1);
      // Seed the current Action's metadata from the draft columns (D3).
      var todo = await db.todoDao.getTodo('o1');
      expect(todo!.energyLevel, 'low', reason: 'birth Action seeded from draft');

      await db.todoDao.updateFields('o1', clearEnergyLevel: true);

      final cur = await _current(db, 'o1');
      expect(cur!.energy, isNull);
      final cols = await _todoColumns(db, 'o1');
      expect(cols.energy, isNull);
      todo = await db.todoDao.getTodo('o1');
      expect(todo!.energyLevel, isNull);
      expect(todo.timeEstimate, 30, reason: 'time-estimate untouched');
    });

    test('an edit with no metadata leaves the current Action metadata intact '
        '(attribute-edits-persist)', () async {
      await _seedOutcome(db);
      await db.actionDao.setCurrentAction(
        'o1',
        'call the vet',
        energyLevel: 'medium',
        timeEstimate: 20,
        now: _t1,
      );

      await db.todoDao.updateFields('o1', title: 'Renamed');

      final cur = await _current(db, 'o1');
      expect(cur!.energy, 'medium');
      expect(cur.time, 20);
    });
  });

  group('D3 — metadata while Actionless seeds the birth Action', () {
    test('draft set on an Actionless Outcome lands on the next current Action',
        () async {
      await _seedOutcome(db);
      // No current Action yet: the values are draft on the Outcome columns.
      await db.todoDao
          .updateFields('o1', energyLevel: 'high', timeEstimate: 90);
      expect(await _current(db, 'o1'), isNull);
      final draftCols = await _todoColumns(db, 'o1');
      expect(draftCols.energy, 'high');

      // Creating the birth Action (no metadata passed) seeds from the draft.
      await db.todoDao.setNextActionText('o1', 'sketch the plan', now: _t2);

      final cur = await _current(db, 'o1');
      expect(cur!.energy, 'high', reason: 'birth Action seeded from draft');
      expect(cur.time, 90);

      final todo = await db.todoDao.getTodo('o1');
      expect(todo!.energyLevel, 'high');
      expect(todo.timeEstimate, 90);
    });
  });

  group('D2 — read hydration with fallback', () {
    test('effective read is the current Action value when it differs from the '
        'Outcome column', () async {
      await _seedOutcome(db, energyLevel: 'low', timeEstimate: 10);
      // Insert a current Action whose metadata differs, bypassing the
      // mirror, to prove the read consults the Action first.
      await db.into(db.actions).insert(ActionsCompanion(
            id: const Value('a1'),
            outcomeId: const Value('o1'),
            userId: const Value(_userId),
            actionText: const Value('do the thing'),
            role: const Value('current'),
            energyLevel: const Value('high'),
            timeEstimate: const Value(55),
            createdAt: Value(_t1),
            updatedAt: Value(_t1),
          ));

      final todo = await db.todoDao.getTodo('o1');
      expect(todo!.energyLevel, 'high');
      expect(todo.timeEstimate, 55);
    });

    test('falls back to the Outcome column once the Action is gone', () async {
      await _seedOutcome(db, energyLevel: 'low', timeEstimate: 10);
      await db.into(db.actions).insert(ActionsCompanion(
            id: const Value('a1'),
            outcomeId: const Value('o1'),
            userId: const Value(_userId),
            actionText: const Value('do the thing'),
            role: const Value('current'),
            energyLevel: const Value('high'),
            timeEstimate: const Value(55),
            createdAt: Value(_t1),
            updatedAt: Value(_t1),
          ));
      // Retire the Action — no more current row.
      await db.actionDao.clearCurrentAction('o1', now: _t2);

      final todo = await db.todoDao.getTodo('o1');
      expect(todo!.energyLevel, 'low', reason: 'Outcome-column fallback');
      expect(todo.timeEstimate, 10);
    });

    test('legacy store (no actions rows) reads the Outcome columns unchanged',
        () async {
      await _seedOutcome(db, energyLevel: 'medium', timeEstimate: 25);

      final todo = await db.todoDao.getTodo('o1');
      expect(todo!.energyLevel, 'medium');
      expect(todo.timeEstimate, 25);
    });

    test('search filters and hydrates on the effective (Action) value',
        () async {
      await _seedOutcome(db, title: 'Write report', energyLevel: 'low');
      // Current Action bumps effective energy to high, bypassing the mirror.
      await db.into(db.actions).insert(ActionsCompanion(
            id: const Value('a1'),
            outcomeId: const Value('o1'),
            userId: const Value(_userId),
            actionText: const Value('outline it'),
            role: const Value('current'),
            energyLevel: const Value('high'),
            createdAt: Value(_t1),
            updatedAt: Value(_t1),
          ));

      final high = await db.searchDao
          .search(const SearchQuery(text: 'report', energyLevels: {'high'}))
          .first;
      expect(high.map((r) => r.todo!.id), ['o1'],
          reason: 'filter matches the current-Action value');
      expect(high.single.todo!.energyLevel, 'high',
          reason: 'result hydrates the effective value');

      final low = await db.searchDao
          .search(const SearchQuery(text: 'report', energyLevels: {'low'}))
          .first;
      expect(low, isEmpty,
          reason: 'stale Outcome-column value no longer matches');
    });
  });

  group('D4 — supersession freezes the old row and mirrors the replacement',
      () {
    test('superseded row keeps its metadata; the replacement carries its own; '
        'the Outcome columns mirror the replacement', () async {
      await _seedOutcome(db);
      await db.actionDao.setCurrentAction(
        'o1',
        'first approach',
        energyLevel: 'high',
        timeEstimate: 60,
        now: _t1,
      );
      final firstId = (await _current(db, 'o1'))!.id;

      await db.actionDao.supersedeCurrentAction(
        'o1',
        newActionText: 'small pivot',
        newEnergyLevel: 'low',
        newTimeEstimate: 15,
        now: _t2,
      );

      // Old row frozen (history is truthful).
      final oldRow = await db
          .customSelect(
            'SELECT role, energy_level, time_estimate FROM actions WHERE id = ?',
            variables: [Variable<String>(firstId)],
          )
          .getSingle();
      expect(oldRow.data['role'], 'superseded');
      expect(oldRow.data['energy_level'], 'high');
      expect(oldRow.data['time_estimate'], 60);

      // Replacement carries only its own values.
      final cur = await _current(db, 'o1');
      expect(cur!.id, isNot(firstId));
      expect(cur.energy, 'low');
      expect(cur.time, 15);

      // Outcome columns mirror the replacement — so the sweep is a no-op.
      final cols = await _todoColumns(db, 'o1');
      expect(cols.energy, 'low');
      expect(cols.time, 15);
    });

    test('a replacement with NULL metadata mirrors NULL onto the columns '
        '(no stale inheritance)', () async {
      await _seedOutcome(db);
      await db.actionDao.setCurrentAction(
        'o1',
        'first approach',
        energyLevel: 'high',
        timeEstimate: 60,
        now: _t1,
      );

      await db.actionDao.supersedeCurrentAction(
        'o1',
        newActionText: 'fresh start, no estimate yet',
        now: _t2,
      );

      final cur = await _current(db, 'o1');
      expect(cur!.energy, isNull);
      expect(cur.time, isNull);
      final cols = await _todoColumns(db, 'o1');
      expect(cols.energy, isNull,
          reason: 'columns mirror the replacement NULL, not the old value');
      expect(cols.time, isNull);

      final todo = await db.todoDao.getTodo('o1');
      expect(todo!.energyLevel, isNull);
      expect(todo.timeEstimate, isNull);
    });
  });
}
