/// The `reconcileActionsAtStartup` sweep, narrowed to its one safe, cursor-free
/// pass (ADR-0001 story 9, issue #479; ADR-0022, ADR-0024).
///
/// Drives the production SQL against a real SQLite database over the same
/// query/exec seam production uses (PowerSync only supplies the transaction),
/// mirroring `migrate_local_inbox_test.dart`.
///
/// The sweep does exactly one thing — [convergeMultiCurrentActions]: it retires
/// the losers of an accidental multi-`current` set by the writers' deterministic
/// winner rule, visiting any Outcome with more than one `current` row.
///
/// Three cursor-driven arms were deleted over the course of #479, and the
/// `todos.next_action_text` column they read no longer exists at all (#525). The
/// family of tests that seeded a cursor to prove each arm was gone went with the
/// column — a cursor an Outcome cannot carry needs no test proving it is
/// ignored. What survives is stronger and does not depend on the column's
/// absence for its meaning:
///
/// * **the sweep never mints an Action, from any input** — the invariant that
///   made cursor adoption impossible, pinned by the two-tap repro below and by
///   the monotonicity guarantee;
/// * **the sweep only ever retires** — `COUNT(*)` is unchanged and no existing
///   row's `text` is rewritten, which is what made Pass A mode 1 impossible;
/// * **a `current` Action is never retired except as a convergence loser** —
///   what made Pass B impossible;
/// * and the structural anchor: **the sweep completes on a store with no
///   `todos` table at all**, so any re-introduced Outcome-column read raises
///   `no such table` here rather than quietly destroying Action rows.
///
/// Plus idempotency and clarification-neutrality (never stamps
/// `last_clarified_at` — ADR-0012).
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:jeeves/database/daos/action_ids.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/services/migration_service.dart';
import '../test_helpers.dart';

const _userId = 'test-user';
final _t0 = DateTime.parse('2026-06-01T09:00:00.000Z');
final _clarified = DateTime.parse('2026-06-10T09:00:00.000Z');
final _sweepAt = DateTime.parse('2026-07-01T12:00:00.000Z');

Future<List<Map<String, Object?>>> _rawQuery(
  GtdDatabase db,
  String sql,
  List<Object?> args,
) async {
  final rows = await db
      .customSelect(sql, variables: [for (final a in args) Variable(a)])
      .get();
  return [for (final r in rows) r.data];
}

/// The whole sweep, driven over the same query/exec seam production uses.
/// `reconcileActionsAtStartup` supplies nothing but the write transaction.
Future<int> _sweep(GtdDatabase db, {DateTime? now}) => db.transaction(
      () => convergeMultiCurrentActions(
        query: (sql, args) => _rawQuery(db, sql, args),
        exec: (sql, args) => db.customStatement(sql, args),
        now: now ?? _sweepAt,
      ),
    );

Future<void> _seedOutcome(
  GtdDatabase db, {
  required String id,
  String? energyLevel,
  int? timeEstimate,
  DateTime? lastClarifiedAt,
  String? doneAt,
  String intent = 'next',
  bool clarified = true,
}) async {
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        userId: const Value(_userId),
        createdAt: Value(_t0),
        energyLevel: Value(energyLevel),
        timeEstimate: Value(timeEstimate),
        lastClarifiedAt: Value(lastClarifiedAt),
        doneAt: Value(doneAt),
        intent: Value(intent),
        clarified: Value(clarified),
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
  int? position,
  DateTime? createdAt,
  DateTime? updatedAt,
  DateTime? doneAt,
}) async {
  await db.customStatement(
    "INSERT INTO actions (id, outcome_id, user_id, text, role, energy_level, "
    "time_estimate, position, created_at, updated_at, done_at) "
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    [
      id,
      outcomeId,
      _userId,
      text,
      role,
      energyLevel,
      timeEstimate,
      position,
      (createdAt ?? _t0).toIso8601String(),
      updatedAt?.toIso8601String(),
      doneAt?.toIso8601String(),
    ],
  );
}

Future<List<Map<String, Object?>>> _actions(GtdDatabase db, String outcomeId) =>
    _rawQuery(
      db,
      "SELECT * FROM actions WHERE outcome_id = ? ORDER BY created_at, id",
      [outcomeId],
    );

/// Every `actions` row in the store, in a stable order — the byte-identity
/// snapshot the monotonicity and restart-idempotency checks compare.
Future<List<Map<String, Object?>>> _allActions(GtdDatabase db) =>
    _rawQuery(db, "SELECT * FROM actions ORDER BY id", []);

Future<Map<String, Object?>?> _current(GtdDatabase db, String outcomeId) async {
  final rows = await _rawQuery(
    db,
    "SELECT * FROM actions WHERE outcome_id = ? AND role = 'current'",
    [outcomeId],
  );
  return rows.isEmpty ? null : rows.single;
}

Future<List<String>> _currentIds(GtdDatabase db, String outcomeId) async {
  final rows = await _rawQuery(
    db,
    "SELECT id FROM actions WHERE outcome_id = ? AND role = 'current' "
    "ORDER BY id",
    [outcomeId],
  );
  return [for (final r in rows) r['id'] as String];
}

Future<DateTime?> _lastClarified(GtdDatabase db, String outcomeId) async {
  final row = await (db.select(db.todos)..where((t) => t.id.equals(outcomeId)))
      .getSingle();
  return row.lastClarifiedAt;
}

/// Seeds one Outcome in each shape the sweep can encounter, so a single run
/// exercises every arm at once (used by the idempotency, non-stamping and
/// monotonicity guarantees, which must hold across all of them together).
Future<void> _seedEveryArm(GtdDatabase db) async {
  // Adoption's old victim: an Outcome with no `actions` rows at all. It must
  // stay Actionless — this is the shape *demote then remove* leaves behind, and
  // the one the deleted adoption pass minted a `current` row for.
  await _seedOutcome(db, id: 'actionless', lastClarifiedAt: _clarified);

  // Pass B's old victim: a lone live `current` Action, which the pass retired.
  await _seedOutcome(db, id: 'lone-current', lastClarifiedAt: _clarified);
  await _insertAction(db,
      id: backfillActionIdFor('lone-current'),
      outcomeId: 'lone-current',
      text: 'survives',
      role: 'current');

  // Mode 1's old victim: a `current` Action whose text and metadata were edited
  // away from what the Outcome's own columns say. The Action-local values must
  // survive; mode 1 copied the Outcome's over them.
  await _seedOutcome(db,
      id: 'drifted',
      energyLevel: 'high',
      timeEstimate: 90,
      lastClarifiedAt: _clarified);
  await _insertAction(db,
      id: backfillActionIdFor('drifted'),
      outcomeId: 'drifted',
      text: 'the Action says this',
      role: 'current',
      energyLevel: 'low',
      timeEstimate: 5);

  // Convergence: two current rows — the one arm that still writes.
  await _seedOutcome(db, id: 'multi', lastClarifiedAt: _clarified);
  await _insertAction(db,
      id: 'aaa',
      outcomeId: 'multi',
      text: 'loser',
      role: 'current',
      updatedAt: DateTime.parse('2026-06-20T09:00:00.000Z'));
  await _insertAction(db,
      id: 'bbb',
      outcomeId: 'multi',
      text: 'winner',
      role: 'current',
      updatedAt: DateTime.parse('2026-06-25T09:00:00.000Z'));

  // Terminal rows: nothing may be resurrected.
  await _seedOutcome(db, id: 'retired', lastClarifiedAt: _clarified);
  await _insertAction(db,
      id: backfillActionIdFor('retired'),
      outcomeId: 'retired',
      text: 'was retired',
      role: 'superseded',
      updatedAt: _t0);

  await _seedOutcome(db, id: 'finished', lastClarifiedAt: _clarified);
  await _insertAction(db,
      id: backfillActionIdFor('finished'),
      outcomeId: 'finished',
      text: 'was done',
      role: 'done',
      doneAt: DateTime.parse('2026-06-15T09:00:00.000Z'));
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() => db = GtdDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  // ---------------------------------------------------------------------------
  // Deleted arm: cursor adoption. The sweep mints nothing, from any input.
  // ---------------------------------------------------------------------------

  group('the sweep never mints an Action', () {
    test('★ the two-tap resurrection is impossible: demote then remove leaves '
        'an Outcome with zero Action rows, and the sweep still mints nothing',
        () async {
      // THE regression. `applyRemovePlannedAction` is a hard DELETE — the only
      // mutation that drives an Outcome to zero `actions` rows while the `todos`
      // row survives — so the deleted adoption pass's "a transition always
      // leaves a row behind" guard had a hole, and the next launch minted the
      // just-removed Action back as `current`. Driven through the real DAO
      // primitives.
      await _seedOutcome(db, id: 'o1', lastClarifiedAt: _clarified);
      await db.actionDao.setCurrentAction('o1', 'the thing', now: _t0);
      final actionId = (await _current(db, 'o1'))!['id'] as String;

      // Tap 1: demote to planned. Tap 2: remove it — hard delete, zero rows.
      await db.actionDao.demoteCurrentAction(actionId, now: _clarified);
      await db.actionDao.removePlannedAction(actionId, now: _clarified);

      expect(await _actions(db, 'o1'), isEmpty, reason: 'precondition');

      final repaired = await _sweep(db);

      expect(repaired, 0);
      expect(await _actions(db, 'o1'), isEmpty,
          reason: 'the deleted Action must not come back as current');
    });

    test('no lifecycle state grows an Action — done, trashed, maybe, '
        'unclarified and plain next Outcomes all stay Actionless', () async {
      await _seedOutcome(db, id: 'live', lastClarifiedAt: _clarified);
      await _seedOutcome(db, id: 'done', doneAt: '2026-06-15T09:00:00.000Z');
      await _seedOutcome(db, id: 'binned', intent: 'trash');
      await _seedOutcome(db, id: 'someday', intent: 'maybe');
      await _seedOutcome(db, id: 'unprocessed', clarified: false);

      expect(await _sweep(db), 0);
      for (final id in const [
        'live',
        'done',
        'binned',
        'someday',
        'unprocessed',
      ]) {
        expect(await _actions(db, id), isEmpty,
            reason: '$id must not grow an Action');
      }
      expect(await _lastClarified(db, 'live'), _clarified, reason: 'no stamp');
    });
  });

  // ---------------------------------------------------------------------------
  // Deleted arm: Pass B (retire every `current` Action whose Outcome had a
  // blank cursor). With the cursor gone the pass could only ever have fired on
  // *every* current Action, so the invariant that outlives it is simply: a lone
  // `current` Action is never retired. This is the one whose absence destroys
  // user data — and, via the sync-up, everyone else's copy of it.
  // ---------------------------------------------------------------------------

  group('a current Action is never retired outside convergence', () {
    test('★ a whole store of single-current Outcomes is left completely alone',
        () async {
      for (var i = 0; i < 5; i++) {
        await _seedOutcome(db, id: 'o$i', lastClarifiedAt: _clarified);
        await _insertAction(db,
            id: backfillActionIdFor('o$i'),
            outcomeId: 'o$i',
            text: 'action $i',
            role: 'current');
      }
      final before = await _allActions(db);

      final repaired = await _sweep(db);

      expect(repaired, 0);
      expect(await _allActions(db), before);
    });
  });

  // ---------------------------------------------------------------------------
  // Convergence pass — cursor-free, and now the whole sweep.
  // ---------------------------------------------------------------------------

  group('convergeMultiCurrentActions', () {
    test('★ two current rows converge to the deterministic winner — convergence '
        'no longer rides a cursor join', () async {
      await _seedOutcome(db, id: 'o1', lastClarifiedAt: _clarified);
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

      final repaired = await _sweep(db);

      expect(repaired, 1);
      expect(await _currentIds(db, 'o1'), ['bbb']);
      final loser =
          (await _actions(db, 'o1')).firstWhere((r) => r['id'] == 'aaa');
      expect(loser['role'], 'superseded');
      expect(loser['updated_at'], _sweepAt.toIso8601String());
      expect(loser['text'], 'losing', reason: 'a retired row keeps its text');
      expect(await _lastClarified(db, 'o1'), _clarified, reason: 'no stamp');
    });

    test('the winner is not even touched', () async {
      await _seedOutcome(db, id: 'o1', lastClarifiedAt: _clarified);
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

      expect(await _sweep(db), 1);
      expect(await _currentIds(db, 'o1'), ['bbb']);
      expect(
        (await _actions(db, 'o1')).firstWhere((r) => r['id'] == 'bbb')
            ['updated_at'],
        DateTime.parse('2026-06-25T09:00:00.000Z').toIso8601String(),
        reason: 'the winner keeps its own updated_at — no write reaches it',
      );
    });

    test('winner rule: greatest COALESCE(updated_at, created_at), tie-break '
        'smallest id — matching ActionDao', () async {
      await _seedOutcome(db, id: 'o1');
      // Same effective timestamp on all three (updated_at NULL falls back to
      // created_at), so the smallest id wins.
      await _insertAction(db,
          id: 'ccc', outcomeId: 'o1', text: 'c', role: 'current');
      await _insertAction(db,
          id: 'aaa', outcomeId: 'o1', text: 'a', role: 'current');
      await _insertAction(db,
          id: 'bbb', outcomeId: 'o1', text: 'b', role: 'current');

      expect(await _sweep(db), 2);
      expect(await _currentIds(db, 'o1'), ['aaa']);
    });

    test('converges several Outcomes in one run, and leaves single-current '
        'Outcomes alone', () async {
      await _seedOutcome(db, id: 'multi');
      await _insertAction(db,
          id: 'm-a',
          outcomeId: 'multi',
          text: 'a',
          role: 'current',
          updatedAt: DateTime.parse('2026-06-20T09:00:00.000Z'));
      await _insertAction(db,
          id: 'm-b',
          outcomeId: 'multi',
          text: 'b',
          role: 'current',
          updatedAt: DateTime.parse('2026-06-25T09:00:00.000Z'));
      await _seedOutcome(db, id: 'solo');
      await _insertAction(db,
          id: 's-a', outcomeId: 'solo', text: 'solo', role: 'current');

      expect(await _sweep(db), 1);
      expect(await _currentIds(db, 'multi'), ['m-b']);
      expect(await _currentIds(db, 'solo'), ['s-a']);
    });

    test('planned and terminal rows are never counted as multi-current',
        () async {
      await _seedOutcome(db, id: 'o1');
      await _insertAction(db,
          id: 'cur', outcomeId: 'o1', text: 'the current', role: 'current');
      await _insertAction(db,
          id: 'pl', outcomeId: 'o1', text: 'planned', role: 'planned',
          position: 0);
      await _insertAction(db,
          id: 'sup', outcomeId: 'o1', text: 'retired', role: 'superseded');
      await _insertAction(db,
          id: 'dn', outcomeId: 'o1', text: 'finished', role: 'done');
      final before = await _allActions(db);

      expect(await _sweep(db), 0);
      expect(await _allActions(db), before);
    });
  });

  // ---------------------------------------------------------------------------
  // Whole-sweep guarantees, held across every arm at once.
  // ---------------------------------------------------------------------------

  group('sweep guarantees', () {
    test('idempotency: a second run writes nothing, in every arm', () async {
      await _seedEveryArm(db);

      final first = await _sweep(db);
      final afterFirst = await _allActions(db);

      final second =
          await _sweep(db, now: DateTime.parse('2026-08-01T00:00:00.000Z'));

      expect(first, 1, reason: 'one convergence retire, and nothing else');
      expect(second, 0, reason: 'nothing left to repair');
      expect(await _allActions(db), afterFirst);
    });

    test('non-stamping: last_clarified_at is unchanged in every arm (ADR-0012)',
        () async {
      await _seedEveryArm(db);

      await _sweep(db);

      for (final id in const [
        'actionless',
        'lone-current',
        'drifted',
        'multi',
        'retired',
        'finished',
      ]) {
        expect(await _lastClarified(db, id), _clarified,
            reason: 'the sweep must never stamp $id');
      }
    });

    test('★ the sweep only ever retires: COUNT(*) is unchanged and no existing '
        'row\'s text is rewritten', () async {
      await _seedEveryArm(db);
      final before = await _allActions(db);
      final textsBefore = {
        for (final r in before) r['id'] as String: r['text'],
      };

      await _sweep(db);

      final after = await _allActions(db);
      expect(after.length, before.length,
          reason: 'the sweep neither mints nor deletes a row');
      for (final row in after) {
        final id = row['id'] as String;
        expect(textsBefore.containsKey(id), isTrue,
            reason: 'the sweep must never mint a row');
        expect(row['text'], textsBefore[id],
            reason: 'the sweep must never rewrite an existing row\'s text');
      }
      expect(
        {for (final r in before) r['id']}
            .difference({for (final r in after) r['id']}),
        isEmpty,
        reason: 'the sweep never deletes a row',
      );
    });

    test('the steady state is one read and no writes at all', () async {
      await _seedEveryArm(db);
      await _sweep(db);

      expect(await _sweep(db), 0);
    });
  });

  // ---------------------------------------------------------------------------
  // Planned queue (ADR-0004 story 5, issue #475) and the live write paths: the
  // sweep must be a no-op on anything the app itself produced.
  // ---------------------------------------------------------------------------

  group('live write paths are sweep-stable', () {
    test('planned rows survive the sweep untouched', () async {
      await _seedOutcome(db,
          id: 'o1', lastClarifiedAt: _clarified);
      await _insertAction(db,
          id: backfillActionIdFor('o1'),
          outcomeId: 'o1',
          text: 'live',
          role: 'current');
      await _insertAction(db,
          id: 'p1',
          outcomeId: 'o1',
          text: 'planned later',
          role: 'planned',
          position: 0);

      final repaired = await _sweep(db);

      expect(repaired, 0);
      final planned =
          (await _actions(db, 'o1')).firstWhere((r) => r['id'] == 'p1');
      expect(planned['role'], 'planned');
      expect(planned['position'], 0);
      expect(planned['text'], 'planned later');
    });

    test('a promoted Action is sweep-stable', () async {
      await _seedOutcome(db, id: 'o1', lastClarifiedAt: _clarified);
      await db.actionDao.addPlannedAction('o1', 'ship it',
          energyLevel: 'high', timeEstimate: 30, now: _t0);
      final id = (await db.actionDao.getPlannedActions('o1')).single.id;
      await db.actionDao.promotePlannedAction(id, now: _clarified);

      final repaired = await _sweep(db);

      expect(repaired, 0);
      final cur = await _current(db, 'o1');
      expect(cur!['id'], id, reason: 'the promoted row is still the current');
      expect(cur['text'], 'ship it');
    });

    test('a demoted Action stays demoted — and nothing is minted beside it',
        () async {
      await _seedOutcome(db, id: 'o1', lastClarifiedAt: _clarified);
      await db.actionDao.setCurrentAction('o1', 'ship it', now: _t0);
      final id = (await _current(db, 'o1'))!['id'] as String;
      await db.actionDao.demoteCurrentAction(id, now: _clarified);

      final repaired = await _sweep(db);

      expect(repaired, 0);
      expect(await _current(db, 'o1'), isNull);
      final planned = (await _actions(db, 'o1')).single;
      expect(planned['role'], 'planned');
      expect(planned['text'], 'ship it');
    });

    test('an abandoned Action stays abandoned', () async {
      await _seedOutcome(db, id: 'o1', lastClarifiedAt: _clarified);
      await db.todoDao.setCurrentActionText('o1', 'ship it', now: _t0);
      await db.actionDao.clearCurrentAction('o1', now: _clarified);

      final repaired = await _sweep(db);

      expect(repaired, 0);
      expect(await _current(db, 'o1'), isNull);
      expect((await _actions(db, 'o1')).single['role'], 'superseded');
    });

    test('a completed Action is never resurrected — the done row keeps the '
        'deterministic backfill id, and nothing is minted beside it', () async {
      // The backfill id is the slot the deleted adoption pass minted into, so
      // an Outcome whose only row already occupies it is the shape most likely
      // to be flipped back to `current` by a revived pass.
      await _seedOutcome(db, id: 'o1', lastClarifiedAt: _clarified);
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

    test('a supersede-with-replacement keeps its own metadata — mode 1 cannot '
        "copy the retired row's values back", () async {
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

      expect(repaired, 0);
      final cur = await _current(db, 'o1');
      expect(cur!['text'], 'small pivot');
      expect(cur['energy_level'], 'low');
      expect(cur['time_estimate'], 15);
      expect(await _lastClarified(db, 'o1'), _clarified,
          reason: 'the sweep never stamps');
    });

    test('★ restart idempotency: a full plan lifecycle then a sweep reports 0 '
        'and leaves `actions` byte-identical', () async {
      // The keystone: run the lifecycle a user actually drives, then simulate
      // the next app launch. Anything the sweep "repairs" here is a bug.
      await _seedOutcome(db, id: 'o1', lastClarifiedAt: _clarified);

      await db.actionDao.addPlannedAction('o1', 'draft the outline',
          energyLevel: 'high', timeEstimate: 45, now: _t0);
      await db.actionDao.addPlannedAction('o1', 'book the room', now: _t0);
      final planned = await db.actionDao.getPlannedActions('o1');
      final first = planned.first.id;

      await db.actionDao.promotePlannedAction(first,
          now: DateTime.parse('2026-06-11T09:00:00.000Z'));
      await db.actionDao.demoteCurrentAction(first,
          now: DateTime.parse('2026-06-12T09:00:00.000Z'));
      await db.actionDao.promotePlannedAction(first,
          now: DateTime.parse('2026-06-13T09:00:00.000Z'));
      await db.actionDao.completeCurrentAction('o1',
          now: DateTime.parse('2026-06-14T09:00:00.000Z'));

      final beforeRestart = await _allActions(db);

      final repaired = await _sweep(db);

      expect(repaired, 0, reason: 'a launch after normal use repairs nothing');
      expect(await _allActions(db), beforeRestart,
          reason: '`actions` must be byte-identical across a restart');

      // And a second launch, for good measure.
      expect(await _sweep(db, now: DateTime.parse('2026-08-01T00:00:00.000Z')),
          0);
      expect(await _allActions(db), beforeRestart);
    });
  });

  // ---------------------------------------------------------------------------
  // NULL columns. Every group above drives the sweep against the Drift schema,
  // whose `actions.outcome_id` is NOT NULL — a constraint production does NOT
  // have. On-device `actions` is a PowerSync view over `ps_data__*(id, data)`
  // with `json_extract`, so every column is unconstrained and a legacy row can
  // carry a NULL anywhere. The sweep runs inside the startup write transaction,
  // so a failed cast there is not a dropped row — it is a launch that never
  // completes.
  //
  // These tests therefore build the *view-shaped* store: the same table names
  // and columns, no constraints at all.
  // ---------------------------------------------------------------------------

  group('NULL columns in a view-shaped store', () {
    late sqlite.Database raw;

    setUp(() {
      raw = sqlite.sqlite3.openInMemory();
      raw.execute('''
        CREATE TABLE actions (
          id TEXT PRIMARY KEY, outcome_id TEXT, user_id TEXT, text TEXT,
          role TEXT, position INTEGER, energy_level TEXT, time_estimate INTEGER,
          created_at TEXT, updated_at TEXT, done_at TEXT
        )
      ''');
    });

    tearDown(() => raw.close());

    Future<int> sweepRaw() => convergeMultiCurrentActions(
          query: (sql, args) async =>
              [for (final r in raw.select(sql, args)) {...r}],
          exec: (sql, args) async => raw.execute(sql, args),
          now: _sweepAt,
        );

    List<Map<String, Object?>> rawActions() =>
        [for (final r in raw.select('SELECT * FROM actions ORDER BY id')) {...r}];

    test('★ the sweep touches no `todos` table at all — it completes on a store '
        'that does not even have one', () async {
      // The structural guard behind "nothing reads the cursor at runtime". The
      // setUp above deliberately creates only `actions`; any re-introduced
      // cursor read would raise `SqliteException: no such table: todos` here
      // rather than quietly minting rows again.
      raw.execute(
        "INSERT INTO actions (id, outcome_id, user_id, text, role, created_at, "
        "updated_at) VALUES "
        "('b1', 'o1', 'test-user', 'loser', 'current', "
        "'2026-06-01T09:00:00.000Z', '2026-06-20T09:00:00.000Z'), "
        "('b2', 'o1', 'test-user', 'winner', 'current', "
        "'2026-06-01T09:00:00.000Z', '2026-06-25T09:00:00.000Z')",
      );

      expect(await sweepRaw(), 1);
      expect(
        {for (final r in rawActions()) r['id']: r['role']},
        {'b1': 'superseded', 'b2': 'current'},
      );
    });

    test('actions rows with a NULL outcome_id are left alone by the '
        'convergence pass', () async {
      // Characterization, not a regression guard: `GROUP BY` buckets NULLs
      // together, so two such rows *look* like a contested multi-current set,
      // but `NULL IN (...)` is NULL rather than true so the outer query never
      // returns them and the `as String` read is never reached. The explicit
      // `outcome_id IS NOT NULL` clause in the pass makes that independent of
      // the subquery shape; this test pins the outcome either way.
      raw.execute(
        "INSERT INTO actions (id, outcome_id, user_id, text, role, created_at) "
        "VALUES ('a1', NULL, 'test-user', 'orphan one', 'current', "
        "'2026-06-01T09:00:00.000Z'), "
        "('a2', NULL, 'test-user', 'orphan two', 'current', "
        "'2026-06-02T09:00:00.000Z')",
      );

      expect(await sweepRaw(), 0);
      expect([for (final r in rawActions()) r['role']], ['current', 'current'],
          reason: 'unattributable rows are left alone, not retired');
    });

    test('a NULL outcome_id row does not stop a real multi-current set '
        'converging', () async {
      raw.execute(
        "INSERT INTO actions (id, outcome_id, user_id, text, role, created_at, "
        "updated_at) VALUES "
        "('a0', NULL, 'test-user', 'orphan', 'current', "
        "'2026-06-01T09:00:00.000Z', NULL), "
        "('b1', 'o1', 'test-user', 'loser', 'current', "
        "'2026-06-01T09:00:00.000Z', '2026-06-20T09:00:00.000Z'), "
        "('b2', 'o1', 'test-user', 'winner', 'current', "
        "'2026-06-01T09:00:00.000Z', '2026-06-25T09:00:00.000Z')",
      );

      expect(await sweepRaw(), 1);
      expect(
        {for (final r in rawActions()) r['id']: r['role']},
        {'a0': 'current', 'b1': 'superseded', 'b2': 'current'},
      );
    });
  });
}
