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
}
