/// ActionDao lifecycle primitives (ADR-0001 story 2, issue #472).
///
/// Drives the real DAO against an in-memory SQLite database where `actions` is
/// a real table (the production view topology is exercised separately in
/// `action_view_notify_test.dart`). Covers create / in-place-edit / no-op
/// semantics of `setCurrentAction`, the explicit `supersedeCurrentAction` /
/// `clearCurrentAction` affordances, the 0..1-current invariant and its
/// multi-current convergence, user_id derivation, and — the crux — the stamping
/// rule: every mutating primitive stamps `last_clarified_at`, while no-ops and
/// convergence-only repair do not.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

const _userId = 'test-user';
final _t0 = DateTime.parse('2026-07-01T09:00:00.000Z');
final _t1 = DateTime.parse('2026-07-01T10:00:00.000Z');
final _t2 = DateTime.parse('2026-07-01T11:00:00.000Z');
final _t3 = DateTime.parse('2026-07-01T12:00:00.000Z');

Future<void> _seedOutcome(
  GtdDatabase db, {
  String id = 'o1',
  DateTime? lastClarifiedAt,
}) async {
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        userId: const Value(_userId),
        createdAt: Value(_t0),
        lastClarifiedAt: Value(lastClarifiedAt),
      ));
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

Future<String?> _nextText(GtdDatabase db, String outcomeId) async {
  final row = await (db.select(db.todos)..where((t) => t.id.equals(outcomeId)))
      .getSingle();
  return row.nextActionText;
}

/// Planned rows for an Outcome, in the DAO's queue order (position, created_at,
/// id), as (id, text, position) records.
Future<List<(String, String, int?)>> _planned(
  GtdDatabase db,
  String outcomeId,
) async {
  final rows = await db.actionDao.getPlannedActions(outcomeId);
  return [for (final r in rows) (r.id, r.actionText, r.position)];
}

final _t4 = DateTime.parse('2026-07-01T13:00:00.000Z');

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    await _seedOutcome(db);
  });
  tearDown(() => db.close());

  group('setCurrentAction', () {
    test('creates a current Action, deriving user_id from the Outcome, and '
        'stamps last_clarified_at', () async {
      await db.actionDao.setCurrentAction('o1', 'call the plumber', now: _t1);

      final cur = await _current(db, 'o1');
      expect(cur, isNotNull);
      expect(cur!['text'], 'call the plumber');
      expect(cur['role'], 'current');
      expect(cur['user_id'], _userId);
      expect(cur['done_at'], isNull);
      expect(await _lastClarified(db, 'o1'), _t1);
    });

    test('edits the current Action in place — same row id, no superseded row '
        'ever produced', () async {
      await db.actionDao.setCurrentAction('o1', 'first', now: _t1);
      final firstId = (await _current(db, 'o1'))!['id'] as String;

      await db.actionDao.setCurrentAction('o1', 'second', now: _t2);

      final rows = await _actions(db, 'o1');
      expect(rows, hasLength(1), reason: 'edit must not mint a new row');
      expect(rows.single['id'], firstId, reason: 'same Action identity');
      expect(rows.single['text'], 'second');
      expect(rows.single['role'], 'current');
      expect(rows.single['updated_at'], _t2.toIso8601String());
      expect(await _lastClarified(db, 'o1'), _t2);
    });

    test('trims text; identical normalised text is a no-op that does not stamp',
        () async {
      await db.actionDao.setCurrentAction('o1', 'do it', now: _t1);
      expect(await _lastClarified(db, 'o1'), _t1);

      await db.actionDao.setCurrentAction('o1', '  do it  ', now: _t3);

      final cur = await _current(db, 'o1');
      expect(cur!['text'], 'do it');
      expect(cur['updated_at'], _t1.toIso8601String(),
          reason: 'no-op must not touch the row');
      expect(await _lastClarified(db, 'o1'), _t1,
          reason: 'no-op must not stamp');
    });

    test('blank text is a caller error', () async {
      expect(
        () => db.actionDao.setCurrentAction('o1', '   ', now: _t1),
        throwsArgumentError,
      );
    });
  });

  group('supersedeCurrentAction', () {
    test('flips the current row to superseded with no linkage columns, and can '
        'mint a replacement', () async {
      await db.actionDao.setCurrentAction('o1', 'old', now: _t1);
      final oldId = (await _current(db, 'o1'))!['id'] as String;

      await db.actionDao
          .supersedeCurrentAction('o1', newActionText: 'new', now: _t2);

      final rows = await _actions(db, 'o1');
      expect(rows, hasLength(2));
      final old = rows.firstWhere((r) => r['id'] == oldId);
      expect(old['role'], 'superseded');
      // ADR-0018: the terminal time is updated_at; there is no linkage column.
      expect(old['updated_at'], _t2.toIso8601String());
      expect(rows.map((r) => r.keys).expand((k) => k),
          isNot(contains('superseded_by_id')));

      final cur = await _current(db, 'o1');
      expect(cur!['text'], 'new');
      expect(cur['id'], isNot(oldId));
      expect(await _lastClarified(db, 'o1'), _t2);
    });

    test('with no replacement leaves the Outcome actionless', () async {
      await db.actionDao.setCurrentAction('o1', 'old', now: _t1);

      await db.actionDao.supersedeCurrentAction('o1', now: _t2);

      expect(await _current(db, 'o1'), isNull);
      expect((await _actions(db, 'o1')).single['role'], 'superseded');
      expect(await _lastClarified(db, 'o1'), _t2);
    });

    test('with a replacement points the cursor at the new text', () async {
      await db.todoDao.setNextActionText('o1', 'old', now: _t1);

      await db.actionDao
          .supersedeCurrentAction('o1', newActionText: 'new', now: _t2);

      expect(await _nextText(db, 'o1'), 'new');
      expect((await _current(db, 'o1'))!['text'], 'new',
          reason: 'cursor and Action agree on the replacement');
    });
  });

  group('clearCurrentAction', () {
    test('ends the current Action as superseded and stamps', () async {
      await db.actionDao.setCurrentAction('o1', 'old', now: _t1);

      await db.actionDao.clearCurrentAction('o1', now: _t2);

      expect(await _current(db, 'o1'), isNull);
      expect(await _lastClarified(db, 'o1'), _t2);
    });

    test('is a no-op that does not stamp when already actionless', () async {
      await _seedOutcome(db, id: 'o2', lastClarifiedAt: _t0);

      await db.actionDao.clearCurrentAction('o2', now: _t2);

      expect(await _actions(db, 'o2'), isEmpty);
      expect(await _lastClarified(db, 'o2'), _t0,
          reason: 'no current row → no stamp');
      expect(await _nextText(db, 'o2'), isNull);
    });

    test('clears the cursor — blank next_action_text ⟺ no current row',
        () async {
      await db.todoDao.setNextActionText('o1', 'old', now: _t1);
      expect(await _nextText(db, 'o1'), 'old', reason: 'precondition');

      await db.actionDao.clearCurrentAction('o1', now: _t2);

      expect(await _current(db, 'o1'), isNull);
      expect(await _nextText(db, 'o1'), isNull,
          reason: 'a surviving cursor would let the startup sweep resurrect '
              'the abandoned Action at the next launch');
    });

    test('abandon stamps where completion does not — both clear the cursor',
        () async {
      await db.todoDao.setNextActionText('o1', 'old', now: _t1);
      await db.actionDao.clearCurrentAction('o1', now: _t2);

      expect(await _lastClarified(db, 'o1'), _t2,
          reason: 'abandoning is a clarifying act');
      expect(await _nextText(db, 'o1'), isNull);

      await db.todoDao.setNextActionText('o1', 'another', now: _t3);
      await db.actionDao.completeCurrentAction('o1', now: _t4);

      expect(await _lastClarified(db, 'o1'), _t3,
          reason: 'completion is engagement, not clarification');
      expect(await _nextText(db, 'o1'), isNull);
    });
  });

  group('0..1-current invariant (multi-current convergence)', () {
    test('a primitive converges an accidental multi-current set: keeps the '
        'winner (greatest updated_at, tie-break smallest id), retires the rest, '
        'without stamping for the convergence itself', () async {
      await _seedOutcome(db, id: 'oc', lastClarifiedAt: _t0);
      await db.customStatement(
        "INSERT INTO actions (id, outcome_id, user_id, text, role, created_at, "
        "updated_at) VALUES "
        "('a', 'oc', ?, 'losing', 'current', ?, ?), "
        "('b', 'oc', ?, 'winning', 'current', ?, ?)",
        [
          _userId,
          _t0.toIso8601String(),
          _t1.toIso8601String(),
          _userId,
          _t0.toIso8601String(),
          _t2.toIso8601String(),
        ],
      );

      // setCurrentAction with the winner's text: convergence retires 'a', and
      // the winner 'b' already matches the text so the primary write is a no-op
      // → no stamp is owed, only the convergence repair happened.
      await db.actionDao.setCurrentAction('oc', 'winning', now: _t3);

      final currents = await db
          .customSelect(
            "SELECT id FROM actions WHERE outcome_id = 'oc' AND role = 'current'",
          )
          .get();
      expect(currents.map((r) => r.data['id']), ['b']);
      final a = await db
          .customSelect("SELECT role FROM actions WHERE id = 'a'")
          .getSingle();
      expect(a.data['role'], 'superseded');
      expect(await _lastClarified(db, 'oc'), _t0,
          reason: 'convergence is repair, not clarification — no stamp');
    });
  });

  group('editAction', () {
    test('renames a planned row in place and stamps', () async {
      await db.actionDao.addPlannedAction('o1', 'draft', now: _t1);
      final id = (await _planned(db, 'o1')).single.$1;

      await db.actionDao.editAction(id, text: 'draft the outline', now: _t2);

      expect((await _planned(db, 'o1')).single.$2, 'draft the outline');
      expect(await _lastClarified(db, 'o1'), _t2);
    });
  });

  group('addPlannedAction', () {
    test('appends dense positions 0,1,2 and stamps each time', () async {
      await db.actionDao.addPlannedAction('o1', 'a', now: _t1);
      await db.actionDao.addPlannedAction('o1', 'b', now: _t2);
      await db.actionDao.addPlannedAction('o1', 'c', now: _t3);

      final planned = await _planned(db, 'o1');
      expect(planned.map((p) => p.$2), ['a', 'b', 'c']);
      expect(planned.map((p) => p.$3), [0, 1, 2]);
      expect(await _lastClarified(db, 'o1'), _t3);
    });

    test('blank text throws and does not stamp', () async {
      await _seedOutcome(db, id: 'o2', lastClarifiedAt: _t0);
      expect(
        () => db.actionDao.addPlannedAction('o2', '   ', now: _t1),
        throwsArgumentError,
      );
      expect(await _lastClarified(db, 'o2'), _t0);
    });

    test('explicit position inserts and shifts the rest down', () async {
      await db.actionDao.addPlannedAction('o1', 'a', now: _t1);
      await db.actionDao.addPlannedAction('o1', 'b', now: _t2);
      await db.actionDao.addPlannedAction('o1', 'inserted', position: 1, now: _t3);

      final planned = await _planned(db, 'o1');
      expect(planned.map((p) => p.$2), ['a', 'inserted', 'b']);
      expect(planned.map((p) => p.$3), [0, 1, 2]);
    });

    test('explicit position lands correctly when stored positions have a gap',
        () async {
      // Seed a, b, c at dense 0,1,2 then remove the head — removePlannedAction
      // leaves the gap in `position` intact, so stored positions become [1, 2]
      // (no row at 0). A fresh insert at queue index 1 must land between the
      // survivors, comparing ordered index rather than the raw stored position.
      await db.actionDao.addPlannedAction('o1', 'a', now: _t1);
      await db.actionDao.addPlannedAction('o1', 'b', now: _t2);
      await db.actionDao.addPlannedAction('o1', 'c', now: _t3);
      final head = (await _planned(db, 'o1')).first;
      await db.actionDao.removePlannedAction(head.$1, now: _t3);
      expect((await _planned(db, 'o1')).map((p) => p.$3), [1, 2],
          reason: 'remove leaves a gap at position 0');

      await db.actionDao
          .addPlannedAction('o1', 'inserted', position: 1, now: _t4);

      final planned = await _planned(db, 'o1');
      expect(planned.map((p) => p.$2), ['b', 'inserted', 'c']);
      expect(planned.map((p) => p.$3), [0, 1, 2],
          reason: 'the insert re-densifies around the opened slot');
    });

    test('a planned row never surfaces as the current Action', () async {
      await db.actionDao.addPlannedAction('o1', 'planned only', now: _t1);
      expect(await _current(db, 'o1'), isNull,
          reason: 'planned rows are not engageable');
      expect(await db.actionDao.getCurrentActionTexts({'o1'}), isEmpty);
    });
  });

  group('reorderPlannedActions', () {
    Future<List<String>> ids(String outcomeId) async =>
        [for (final p in await _planned(db, outcomeId)) p.$1];

    test('rewrites dense positions in the given order and stamps once',
        () async {
      await db.actionDao.addPlannedAction('o1', 'a', now: _t1);
      await db.actionDao.addPlannedAction('o1', 'b', now: _t1);
      await db.actionDao.addPlannedAction('o1', 'c', now: _t1);
      final order = await ids('o1');

      await db.actionDao.reorderPlannedActions(
        'o1',
        [order[2], order[0], order[1]],
        now: _t4,
      );

      final planned = await _planned(db, 'o1');
      expect(planned.map((p) => p.$2), ['c', 'a', 'b']);
      expect(planned.map((p) => p.$3), [0, 1, 2]);
      expect(await _lastClarified(db, 'o1'), _t4);
    });

    test('an unchanged order is a no-op: no write, no stamp', () async {
      await db.actionDao.addPlannedAction('o1', 'a', now: _t1);
      await db.actionDao.addPlannedAction('o1', 'b', now: _t2);
      final order = await ids('o1');

      await db.actionDao.reorderPlannedActions('o1', order, now: _t4);

      expect(await _lastClarified(db, 'o1'), _t2,
          reason: 'no-op reorder must not stamp');
    });

    test('drift tolerance: unknown ids are ignored and a missing planned row is '
        'appended in prior relative order', () async {
      await db.actionDao.addPlannedAction('o1', 'a', now: _t1);
      await db.actionDao.addPlannedAction('o1', 'b', now: _t1);
      await db.actionDao.addPlannedAction('o1', 'c', now: _t1);
      final order = await ids('o1');

      // Reorder names only b and a (c omitted) plus a stranger id.
      await db.actionDao.reorderPlannedActions(
        'o1',
        [order[1], 'ghost', order[0]],
        now: _t4,
      );

      final planned = await _planned(db, 'o1');
      // b, a as named; c appended keeping its prior relative order.
      expect(planned.map((p) => p.$2), ['b', 'a', 'c']);
      expect(planned.map((p) => p.$3), [0, 1, 2]);
    });
  });

  group('promotePlannedAction', () {
    test('flips role to current, clears position, sets the cursor text and '
        'mirrors metadata, and stamps', () async {
      await db.actionDao.addPlannedAction('o1', 'do the thing',
          energyLevel: 'high', timeEstimate: 30, now: _t1);
      final id = (await _planned(db, 'o1')).single.$1;

      await db.actionDao.promotePlannedAction(id, now: _t2);

      final cur = await _current(db, 'o1');
      expect(cur!['id'], id, reason: 'same row, flipped role');
      expect(cur['role'], 'current');
      expect(cur['position'], isNull);
      expect(await _planned(db, 'o1'), isEmpty);
      // Cursor dual-write (mandatory for sweep stability).
      expect(await _nextText(db, 'o1'), 'do the thing');
      final todo = await db.todoDao.getTodo('o1');
      expect(todo!.energyLevel, 'high');
      expect(todo.timeEstimate, 30);
      expect(await _lastClarified(db, 'o1'), _t2);
    });

    test('refuses with StateError when a current Action already exists',
        () async {
      await db.actionDao.setCurrentAction('o1', 'current one', now: _t1);
      await db.actionDao.addPlannedAction('o1', 'planned one', now: _t2);
      final plannedId = (await _planned(db, 'o1')).single.$1;

      expect(
        () => db.actionDao.promotePlannedAction(plannedId, now: _t3),
        throwsStateError,
      );
      // Nothing changed: still one current + one planned.
      expect((await _current(db, 'o1'))!['text'], 'current one');
      expect((await _planned(db, 'o1')).single.$2, 'planned one');
    });

    test('is a no-op on a missing row and on an already-current row', () async {
      await db.actionDao.setCurrentAction('o1', 'live', now: _t1);
      final curId = (await _current(db, 'o1'))!['id'] as String;

      await db.actionDao.promotePlannedAction('nope', now: _t2);
      await db.actionDao.promotePlannedAction(curId, now: _t2);

      expect((await _current(db, 'o1'))!['text'], 'live');
      expect(await _lastClarified(db, 'o1'), _t1, reason: 'no-op → no stamp');
    });
  });

  group('supersedeAndPromote', () {
    test('retires the current (ADR-0018 terminal time = updated_at) and flips '
        'the planned row up, cursor rewritten, one stamp', () async {
      await db.actionDao.setCurrentAction('o1', 'old current', now: _t1);
      final oldId = (await _current(db, 'o1'))!['id'] as String;
      await db.actionDao.addPlannedAction('o1', 'new current',
          energyLevel: 'low', now: _t2);
      final plannedId = (await _planned(db, 'o1')).single.$1;

      await db.actionDao.supersedeAndPromote(plannedId, now: _t3);

      final old = (await _actions(db, 'o1')).firstWhere((r) => r['id'] == oldId);
      expect(old['role'], 'superseded');
      expect(old['updated_at'], _t3.toIso8601String());
      final cur = await _current(db, 'o1');
      expect(cur!['id'], plannedId);
      expect(cur['text'], 'new current');
      expect(await _nextText(db, 'o1'), 'new current');
      expect((await db.todoDao.getTodo('o1'))!.energyLevel, 'low');
      expect(await _planned(db, 'o1'), isEmpty);
      expect(await _lastClarified(db, 'o1'), _t3);
    });

    test('idempotent replay: a second call on the now-current row is a no-op',
        () async {
      await db.actionDao.setCurrentAction('o1', 'old', now: _t1);
      await db.actionDao.addPlannedAction('o1', 'new', now: _t2);
      final plannedId = (await _planned(db, 'o1')).single.$1;

      await db.actionDao.supersedeAndPromote(plannedId, now: _t3);
      await db.actionDao.supersedeAndPromote(plannedId, now: _t4);

      expect((await _current(db, 'o1'))!['id'], plannedId);
      expect(await _lastClarified(db, 'o1'), _t3,
          reason: 'the replay finds a current row → no-op, no fresh stamp');
    });
  });

  group('demoteCurrentAction', () {
    test('flips the current back to planned at position 0 (shifting), clears '
        'the cursor text, and stamps', () async {
      await db.actionDao.addPlannedAction('o1', 'kept', now: _t1);
      await db.actionDao.setCurrentAction('o1', 'demote me', now: _t2);
      final curId = (await _current(db, 'o1'))!['id'] as String;

      await db.actionDao.demoteCurrentAction(curId, now: _t3);

      expect(await _current(db, 'o1'), isNull);
      final planned = await _planned(db, 'o1');
      expect(planned.map((p) => p.$2), ['demote me', 'kept']);
      expect(planned.map((p) => p.$3), [0, 1]);
      expect(await _nextText(db, 'o1'), isNull,
          reason: 'demote must clear the cursor (Mode 3 resurrect guard)');
      expect(await _lastClarified(db, 'o1'), _t3);
    });

    test('honours an explicit position', () async {
      await db.actionDao.addPlannedAction('o1', 'first', now: _t1);
      await db.actionDao.addPlannedAction('o1', 'second', now: _t1);
      await db.actionDao.setCurrentAction('o1', 'demoted', now: _t2);
      final curId = (await _current(db, 'o1'))!['id'] as String;

      await db.actionDao.demoteCurrentAction(curId, position: 1, now: _t3);

      expect((await _planned(db, 'o1')).map((p) => p.$2),
          ['first', 'demoted', 'second']);
    });

    test('no-op on a missing or non-current row', () async {
      await db.actionDao.addPlannedAction('o1', 'planned', now: _t1);
      final plannedId = (await _planned(db, 'o1')).single.$1;

      await db.actionDao.demoteCurrentAction(plannedId, now: _t2);

      expect((await _planned(db, 'o1')).single.$2, 'planned',
          reason: 'a planned row is never demoted');
      expect(await _lastClarified(db, 'o1'), _t1);
    });
  });

  group('removePlannedAction', () {
    test('hard-deletes the planned row, leaves the others, and stamps',
        () async {
      await db.actionDao.addPlannedAction('o1', 'a', now: _t1);
      await db.actionDao.addPlannedAction('o1', 'b', now: _t1);
      await db.actionDao.addPlannedAction('o1', 'c', now: _t1);
      final planned = await _planned(db, 'o1');
      final bId = planned[1].$1;

      await db.actionDao.removePlannedAction(bId, now: _t4);

      final rows = await _actions(db, 'o1');
      expect(rows, hasLength(2), reason: 'b is gone, no tombstone');
      expect(rows.map((r) => r['text']), containsAll(['a', 'c']));
      expect(rows.map((r) => r['text']), isNot(contains('b')));
      // Positions untouched (0 and 2) — the read tie-break covers the gap.
      expect((await _planned(db, 'o1')).map((p) => p.$2), ['a', 'c']);
      expect(await _lastClarified(db, 'o1'), _t4);
    });

    test('never deletes a current row', () async {
      await db.actionDao.setCurrentAction('o1', 'live', now: _t1);
      final curId = (await _current(db, 'o1'))!['id'] as String;

      await db.actionDao.removePlannedAction(curId, now: _t2);

      expect((await _current(db, 'o1'))!['text'], 'live');
      expect(await _lastClarified(db, 'o1'), _t1, reason: 'no-op → no stamp');
    });
  });

  group('watchPlannedActions ordering', () {
    test('duplicate positions tie-break on created_at then id', () async {
      // Two rows sharing position 0 (a cross-device collision) must still order
      // deterministically.
      await db.customStatement(
        "INSERT INTO actions (id, outcome_id, user_id, text, role, position, "
        "created_at) VALUES "
        "('zzz', 'o1', ?, 'later', 'planned', 0, ?), "
        "('aaa', 'o1', ?, 'earlier', 'planned', 0, ?)",
        [
          _userId,
          _t2.toIso8601String(),
          _userId,
          _t1.toIso8601String(),
        ],
      );

      final planned = await _planned(db, 'o1');
      // Same position → earlier created_at wins.
      expect(planned.map((p) => p.$2), ['earlier', 'later']);
    });
  });
}
