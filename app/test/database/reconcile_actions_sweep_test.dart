/// The `reconcileActionsWithCursor` startup sweep (ADR-0001 story 2, issue
/// #472) — discharges the #471 backfill drift obligation and repairs the
/// ongoing old-client replay window.
///
/// Drives the production SQL against a real SQLite database over the same
/// query/exec seam production uses (PowerSync only supplies the transaction),
/// mirroring `migrate_local_inbox_test.dart`. Covers each drift mode, the
/// deterministic-id resurrect (and its `superseded`-only guard), multi-current
/// convergence, the transient both-superseded self-heal, idempotency, and the
/// hard non-stamping guarantee (cursor→actions repair must never move
/// `last_clarified_at`).
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/action_ids.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/services/migration_service.dart';
import '../test_helpers.dart';

const _userId = 'test-user';
final _t0 = DateTime.parse('2026-06-01T09:00:00.000Z');
final _clarified = DateTime.parse('2026-06-10T09:00:00.000Z');
final _sweepAt = DateTime.parse('2026-07-01T12:00:00.000Z');

Future<int> _sweep(GtdDatabase db, {DateTime? now}) => db.transaction(
      () => reconcileActionsWithCursorSteps(
        query: (sql, args) async {
          final rows = await db
              .customSelect(
                sql,
                variables: [for (final a in args) Variable(a)],
              )
              .get();
          return [for (final r in rows) r.data];
        },
        exec: (sql, args) => db.customStatement(sql, args),
        now: now ?? _sweepAt,
      ),
    );

Future<void> _seedOutcome(
  GtdDatabase db, {
  required String id,
  String? nextActionText,
  String? energyLevel,
  int? timeEstimate,
  DateTime? lastClarifiedAt,
}) async {
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        userId: const Value(_userId),
        createdAt: Value(_t0),
        nextActionText: Value(nextActionText),
        energyLevel: Value(energyLevel),
        timeEstimate: Value(timeEstimate),
        lastClarifiedAt: Value(lastClarifiedAt),
      ));
}

Future<void> _insertAction(
  GtdDatabase db, {
  required String id,
  required String outcomeId,
  required String text,
  required String role,
  String? energyLevel,
  int? timeEstimate,
  DateTime? createdAt,
  DateTime? updatedAt,
  DateTime? doneAt,
}) async {
  await db.customStatement(
    "INSERT INTO actions (id, outcome_id, user_id, text, role, energy_level, "
    "time_estimate, created_at, updated_at, done_at) "
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    [
      id,
      outcomeId,
      _userId,
      text,
      role,
      energyLevel,
      timeEstimate,
      (createdAt ?? _t0).toIso8601String(),
      updatedAt?.toIso8601String(),
      doneAt?.toIso8601String(),
    ],
  );
}

Future<List<Map<String, Object?>>> _actions(GtdDatabase db, String outcomeId) async {
  final rows = await db
      .customSelect(
        "SELECT * FROM actions WHERE outcome_id = ? ORDER BY created_at, id",
        variables: [Variable<String>(outcomeId)],
      )
      .get();
  return rows.map((r) => r.data).toList();
}

Future<Map<String, Object?>?> _current(GtdDatabase db, String outcomeId) async {
  final rows = await db
      .customSelect(
        "SELECT * FROM actions WHERE outcome_id = ? AND role = 'current'",
        variables: [Variable<String>(outcomeId)],
      )
      .get();
  return rows.isEmpty ? null : rows.single.data;
}

Future<DateTime?> _lastClarified(GtdDatabase db, String outcomeId) async {
  final row = await (db.select(db.todos)..where((t) => t.id.equals(outcomeId)))
      .getSingle();
  return row.lastClarifiedAt;
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() => db = GtdDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('mode 1 — stale row: brings text and metadata in line with the cursor, '
      'without stamping', () async {
    await _seedOutcome(db,
        id: 'o1',
        nextActionText: 'new text',
        energyLevel: 'high',
        timeEstimate: 30,
        lastClarifiedAt: _clarified);
    await _insertAction(db,
        id: backfillActionIdFor('o1'),
        outcomeId: 'o1',
        text: 'old text',
        role: 'current',
        energyLevel: 'low',
        timeEstimate: 5);

    await _sweep(db);

    final cur = await _current(db, 'o1');
    expect(cur!['text'], 'new text');
    expect(cur['energy_level'], 'high');
    expect(cur['time_estimate'], 30);
    expect(cur['updated_at'], _sweepAt.toIso8601String());
    expect(await _lastClarified(db, 'o1'), _clarified, reason: 'no stamp');
  });

  test('mode 2 — phantom row: cursor cleared but a current Action survives → '
      'retire (not delete), without stamping', () async {
    await _seedOutcome(db,
        id: 'o1', nextActionText: null, lastClarifiedAt: _clarified);
    await _insertAction(db,
        id: backfillActionIdFor('o1'),
        outcomeId: 'o1',
        text: 'stranded',
        role: 'current');

    await _sweep(db);

    expect(await _current(db, 'o1'), isNull);
    final rows = await _actions(db, 'o1');
    expect(rows.single['role'], 'superseded');
    expect(rows.single['updated_at'], _sweepAt.toIso8601String());
    expect(await _lastClarified(db, 'o1'), _clarified, reason: 'no stamp');
  });

  test('mode 2 — whitespace-only cursor is treated as blank', () async {
    await _seedOutcome(db,
        id: 'o1', nextActionText: '   ', lastClarifiedAt: _clarified);
    await _insertAction(db,
        id: backfillActionIdFor('o1'),
        outcomeId: 'o1',
        text: 'stranded',
        role: 'current');

    await _sweep(db);

    expect(await _current(db, 'o1'), isNull);
    expect(await _lastClarified(db, 'o1'), _clarified, reason: 'no stamp');
  });

  test('mode 3 — missing row: mint via the deterministic backfill id, without '
      'stamping', () async {
    await _seedOutcome(db,
        id: 'o1',
        nextActionText: 'freshly set',
        energyLevel: 'medium',
        timeEstimate: 12,
        lastClarifiedAt: _clarified);

    await _sweep(db);

    final cur = await _current(db, 'o1');
    expect(cur!['id'], backfillActionIdFor('o1'));
    expect(cur['text'], 'freshly set');
    expect(cur['energy_level'], 'medium');
    expect(cur['time_estimate'], 12);
    expect(cur['user_id'], _userId);
    expect(await _lastClarified(db, 'o1'), _clarified, reason: 'no stamp');
  });

  test('mode 3 — resurrect: a superseded row at the deterministic id is flipped '
      'back to current with the cursor text', () async {
    await _seedOutcome(db,
        id: 'o1', nextActionText: 're-set by old client', lastClarifiedAt: _clarified);
    await _insertAction(db,
        id: backfillActionIdFor('o1'),
        outcomeId: 'o1',
        text: 'was retired',
        role: 'superseded',
        updatedAt: _t0);

    await _sweep(db);

    final rows = await _actions(db, 'o1');
    expect(rows, hasLength(1), reason: 'resurrect, not a second row');
    expect(rows.single['id'], backfillActionIdFor('o1'));
    expect(rows.single['role'], 'current');
    expect(rows.single['text'], 're-set by old client');
    expect(await _lastClarified(db, 'o1'), _clarified, reason: 'no stamp');
  });

  test('mode 3 — resurrect guard: a done row is never revived; a fresh current '
      'is minted instead and the done row is left intact', () async {
    await _seedOutcome(db,
        id: 'o1', nextActionText: 'still want this', lastClarifiedAt: _clarified);
    final doneAt = DateTime.parse('2026-06-15T09:00:00.000Z');
    await _insertAction(db,
        id: backfillActionIdFor('o1'),
        outcomeId: 'o1',
        text: 'already done',
        role: 'done',
        doneAt: doneAt);

    await _sweep(db);

    final done = (await _actions(db, 'o1'))
        .firstWhere((r) => r['id'] == backfillActionIdFor('o1'));
    expect(done['role'], 'done', reason: 'done row must never be resurrected');
    expect(done['done_at'], doneAt.toIso8601String());

    final cur = await _current(db, 'o1');
    expect(cur, isNotNull);
    expect(cur!['id'], isNot(backfillActionIdFor('o1')));
    expect(cur['text'], 'still want this');
    expect(await _lastClarified(db, 'o1'), _clarified, reason: 'no stamp');
  });

  test('multi-current convergence: keeps the winner (greatest updated_at, '
      'tie-break smallest id), retires the rest', () async {
    await _seedOutcome(db,
        id: 'o1', nextActionText: 'winning', lastClarifiedAt: _clarified);
    await _insertAction(db,
        id: 'aaa',
        outcomeId: 'o1',
        text: 'losing',
        role: 'current',
        updatedAt: DateTime.parse('2026-06-20T09:00:00.000Z'));
    await _insertAction(db,
        id: 'bbb',
        outcomeId: 'o1',
        text: 'winning',
        role: 'current',
        updatedAt: DateTime.parse('2026-06-25T09:00:00.000Z'));

    await _sweep(db);

    final currents = await db
        .customSelect(
          "SELECT id FROM actions WHERE outcome_id = 'o1' AND role = 'current'",
        )
        .get();
    expect(currents.map((r) => r.data['id']), ['bbb']);
    expect(await _lastClarified(db, 'o1'), _clarified, reason: 'no stamp');
  });

  test('both-superseded self-heal: two devices mutually retired the current '
      '(sync-lag race) leaving the outcome currentless while the cursor still '
      'holds text → mode 3 resurrects the deterministic row', () async {
    await _seedOutcome(db,
        id: 'o1', nextActionText: 'still live', lastClarifiedAt: _clarified);
    // Device A minted+retired its own random-id row; the deterministic backfill
    // row was also retired. No current row survives.
    await _insertAction(db,
        id: 'random-a',
        outcomeId: 'o1',
        text: 'a version',
        role: 'superseded',
        updatedAt: DateTime.parse('2026-06-20T09:00:00.000Z'));
    await _insertAction(db,
        id: backfillActionIdFor('o1'),
        outcomeId: 'o1',
        text: 'backfill version',
        role: 'superseded',
        updatedAt: DateTime.parse('2026-06-21T09:00:00.000Z'));

    await _sweep(db);

    final cur = await _current(db, 'o1');
    expect(cur, isNotNull, reason: 'the outcome self-heals to a current Action');
    expect(cur!['id'], backfillActionIdFor('o1'),
        reason: 'converges on the deterministic id, not a new random row');
    expect(cur['text'], 'still live');
    expect(await _lastClarified(db, 'o1'), _clarified, reason: 'no stamp');
  });

  test('completion interplay: a completed Action is never resurrected, because '
      'completion cleared the cursor in the same transaction', () async {
    // The exact failure mode the cursor clear prevents (issue #474, R3): Pass A
    // buckets "non-blank cursor + no current row" as drift and mints a fresh
    // current Action — resurrecting the Action the user just finished.
    await _seedOutcome(db,
        id: 'o1', nextActionText: 'ship it', lastClarifiedAt: _clarified);
    await _insertAction(db,
        id: backfillActionIdFor('o1'),
        outcomeId: 'o1',
        text: 'ship it',
        role: 'current');

    final completedAt = DateTime.parse('2026-06-20T09:00:00.000Z');
    await db.actionDao.completeCurrentAction('o1', now: completedAt);

    final repaired = await _sweep(db);

    expect(repaired, 0, reason: 'a completed Outcome is not drift');
    final rows = await _actions(db, 'o1');
    expect(rows, hasLength(1), reason: 'nothing minted');
    expect(rows.single['role'], 'done');
    expect(rows.single['done_at'], completedAt.toIso8601String());
    expect(await _current(db, 'o1'), isNull);
    expect(await _lastClarified(db, 'o1'), _clarified,
        reason: 'neither completion nor the sweep stamps');
  });

  test('idempotent: a second sweep changes nothing', () async {
    await _seedOutcome(db,
        id: 'mint', nextActionText: 'a', lastClarifiedAt: _clarified);
    await _seedOutcome(db,
        id: 'phantom', nextActionText: null, lastClarifiedAt: _clarified);
    await _insertAction(db,
        id: backfillActionIdFor('phantom'),
        outcomeId: 'phantom',
        text: 'x',
        role: 'current');

    await _sweep(db);
    final afterFirst = {
      'mint': await _actions(db, 'mint'),
      'phantom': await _actions(db, 'phantom'),
    };

    final repaired = await _sweep(db, now: DateTime.parse('2026-08-01T00:00:00.000Z'));

    expect(repaired, 0, reason: 'second run has nothing to repair');
    expect(await _actions(db, 'mint'), afterFirst['mint']);
    expect(await _actions(db, 'phantom'), afterFirst['phantom']);
  });

  // ---------------------------------------------------------------------------
  // Planned queue (ADR-0004 story 5, issue #475): the sweep filters both passes
  // on role='current', so planned rows are invisible to it, and the promote /
  // demote cursor dual-writes keep the swept-for invariant intact.
  // ---------------------------------------------------------------------------

  test('planned rows survive both passes untouched', () async {
    await _seedOutcome(db,
        id: 'o1', nextActionText: 'live', lastClarifiedAt: _clarified);
    await _insertAction(db,
        id: backfillActionIdFor('o1'),
        outcomeId: 'o1',
        text: 'live',
        role: 'current');
    await db.customStatement(
      "INSERT INTO actions (id, outcome_id, user_id, text, role, position, "
      "created_at) VALUES ('p1', 'o1', ?, 'planned later', 'planned', 0, ?)",
      [_userId, _t0.toIso8601String()],
    );

    final repaired = await _sweep(db);

    expect(repaired, 0, reason: 'nothing drifted');
    final planned = (await _actions(db, 'o1'))
        .firstWhere((r) => r['id'] == 'p1');
    expect(planned['role'], 'planned');
    expect(planned['position'], 0);
    expect(planned['text'], 'planned later');
  });

  test('a promoted Action is sweep-stable: the cursor dual-write keeps Pass B '
      'from retiring it as a phantom', () async {
    await _seedOutcome(db, id: 'o1', lastClarifiedAt: _clarified);
    await db.actionDao.addPlannedAction('o1', 'ship it',
        energyLevel: 'high', timeEstimate: 30, now: _t0);
    final id = (await db.actionDao.getPlannedActions('o1')).single.id;
    await db.actionDao.promotePlannedAction(id, now: _clarified);

    final repaired = await _sweep(db);

    expect(repaired, 0, reason: 'promote wrote the cursor, so no drift');
    final cur = await _current(db, 'o1');
    expect(cur!['id'], id, reason: 'the promoted row is still the current');
    expect(cur['text'], 'ship it');
  });

  test('a demoted Action stays demoted: the cleared cursor keeps Pass A mode-3 '
      'from resurrecting it', () async {
    await _seedOutcome(db, id: 'o1', lastClarifiedAt: _clarified);
    await db.actionDao.setCurrentAction('o1', 'ship it', now: _t0);
    final id = (await _current(db, 'o1'))!['id'] as String;
    await db.actionDao.demoteCurrentAction(id, now: _clarified);

    final repaired = await _sweep(db);

    expect(repaired, 0, reason: 'demote cleared the cursor, so no drift');
    expect(await _current(db, 'o1'), isNull,
        reason: 'no fresh current resurrected from a blank cursor');
    final planned = (await _actions(db, 'o1')).single;
    expect(planned['role'], 'planned');
    expect(planned['text'], 'ship it');
  });

  test('a supersede-with-replacement mirrors the replacement metadata onto the '
      'cursor, so the sweep is a no-op and never resurrects the superseded '
      "row's metadata (ADR-0001 story 7, D4)", () async {
    await _seedOutcome(db, id: 'o1', lastClarifiedAt: _clarified);
    await db.actionDao.setCurrentAction(
      'o1',
      'first approach',
      energyLevel: 'high',
      timeEstimate: 60,
      now: _t0,
    );
    await db.actionDao.supersedeCurrentAction(
      'o1',
      newActionText: 'small pivot',
      newEnergyLevel: 'low',
      newTimeEstimate: 15,
      now: _clarified,
    );

    final repaired = await _sweep(db);

    expect(repaired, 0,
        reason: 'the cursor already mirrors the replacement — no drift');
    final cur = await _current(db, 'o1');
    expect(cur!['text'], 'small pivot');
    expect(cur['energy_level'], 'low',
        reason: 'mode 1 did NOT copy the superseded high/60 back');
    expect(cur['time_estimate'], 15);
    expect(await _lastClarified(db, 'o1'), _clarified,
        reason: 'the sweep never stamps');
  });
}
