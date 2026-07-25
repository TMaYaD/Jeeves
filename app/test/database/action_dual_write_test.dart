/// Dual-write equivalence at the three legacy `next_action_text` choke points
/// (ADR-0001 story 2, issue #472).
///
/// The cursor column stays authoritative for reads, but every legacy surface
/// that writes it now also drives [ActionDao]. These tests pin the invariant
/// that after every such write the cursor and the Outcome's `current` Action
/// agree — text present on both, or actionless on both — and that the routing
/// arms which never touch the cursor (`maybe` / `done` / `trash`) write no
/// Action rows.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show RoutingKind;
import '../test_helpers.dart';

const _userId = 'test-user';
final _t0 = DateTime.parse('2026-07-01T09:00:00.000Z');
final _t1 = DateTime.parse('2026-07-01T10:00:00.000Z');
final _t2 = DateTime.parse('2026-07-01T11:00:00.000Z');

Future<void> _seedOutcome(GtdDatabase db, {String id = 'o1'}) async {
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        userId: const Value(_userId),
        createdAt: Value(_t0),
      ));
}

Future<String?> _cursor(GtdDatabase db, String id) async {
  return (await _todo(db, id)).nextActionText;
}

Future<Todo> _todo(GtdDatabase db, String id) =>
    (db.select(db.todos)..where((t) => t.id.equals(id))).getSingle();

Future<List<Map<String, Object?>>> _currents(GtdDatabase db, String id) async {
  final rows = await db
      .customSelect(
        "SELECT * FROM actions WHERE outcome_id = ? AND role = 'current'",
        variables: [Variable<String>(id)],
      )
      .get();
  return rows.map((r) => r.data).toList();
}

/// The equivalence invariant: cursor text ⇔ exactly one matching current
/// Action; blank/NULL cursor ⇔ no current Action.
Future<void> _expectEquiv(GtdDatabase db, String id) async {
  final cursor = await _cursor(db, id);
  final currents = await _currents(db, id);
  if (cursor == null || cursor.trim().isEmpty) {
    expect(currents, isEmpty,
        reason: 'blank cursor must leave no current Action');
  } else {
    expect(currents, hasLength(1),
        reason: 'a cursor value must have exactly one current Action');
    expect(currents.single['text'], cursor,
        reason: 'cursor and current Action text must agree');
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    await _seedOutcome(db);
  });
  tearDown(() => db.close());

  group('setNextActionText', () {
    test('fresh set yields a matching current Action', () async {
      await db.todoDao.setNextActionText('o1', 'call plumber', now: _t1);
      await _expectEquiv(db, 'o1');
    });

    test('overwrite edits the same Action row in place', () async {
      await db.todoDao.setNextActionText('o1', 'first', now: _t1);
      final firstId = (await _currents(db, 'o1')).single['id'];

      await db.todoDao.setNextActionText('o1', 'second', now: _t2);

      final currents = await _currents(db, 'o1');
      expect(currents.single['id'], firstId, reason: 'same identity');
      expect(currents.single['text'], 'second');
      await _expectEquiv(db, 'o1');
    });

    test('blank clears both the cursor and the current Action', () async {
      await db.todoDao.setNextActionText('o1', 'something', now: _t1);
      await db.todoDao.setNextActionText('o1', '', now: _t2);

      expect(await _cursor(db, 'o1'), isNull);
      await _expectEquiv(db, 'o1');
      // The cleared Action is retired, not deleted (ADR-0018 history chain).
      final all = await db
          .customSelect("SELECT role FROM actions WHERE outcome_id = 'o1'")
          .get();
      expect(all.single.data['role'], 'superseded');
    });
  });

  group('setNextActionTextIfActionless', () {
    test('skips when a current Action is present: no clobber, no stamp',
        () async {
      // A synced `current` Action already carries a deliberate phrase.
      await seedCurrentAction(
        db,
        outcomeId: 'o1',
        text: 'deliberate phrase',
        userId: _userId,
        createdAt: _t0,
      );
      final before = await _todo(db, 'o1');

      final wrote = await db.todoDao
          .setNextActionTextIfActionless('o1', 'Mirrored title', now: _t1);

      expect(wrote, isFalse, reason: 'an actioned Outcome is left untouched');
      final currents = await _currents(db, 'o1');
      expect(currents.single['text'], 'deliberate phrase',
          reason: 'the mirror must not overwrite the deliberate Action');
      final after = await _todo(db, 'o1');
      expect(after.lastClarifiedAt, before.lastClarifiedAt,
          reason: 'the skip path stamps nothing');
      expect(after.updatedAt, before.updatedAt);
      expect(after.nextActionText, before.nextActionText);
    });

    test('on an actionless Outcome, equals setNextActionText for the same now',
        () async {
      await _seedOutcome(db, id: 'viaPrimitive');
      await _seedOutcome(db, id: 'viaDirect');

      final wrote = await db.todoDao
          .setNextActionTextIfActionless('viaPrimitive', 'Book venue', now: _t1);
      await db.todoDao.setNextActionText('viaDirect', 'Book venue', now: _t1);

      expect(wrote, isTrue);
      // Cursor.
      expect(await _cursor(db, 'viaPrimitive'), 'Book venue');
      expect(await _cursor(db, 'viaPrimitive'), await _cursor(db, 'viaDirect'));
      // Action row (identity differs — a fresh uuid each — but text agrees).
      final pc = await _currents(db, 'viaPrimitive');
      final dc = await _currents(db, 'viaDirect');
      expect(pc.single['text'], dc.single['text']);
      // Stamp (last_clarified_at + updated_at), byte-identical for the same now.
      final pt = await _todo(db, 'viaPrimitive');
      final dt = await _todo(db, 'viaDirect');
      expect(pt.lastClarifiedAt, dt.lastClarifiedAt);
      expect(pt.updatedAt, dt.updatedAt);
      await _expectEquiv(db, 'viaPrimitive');
    });

    test('blank text is a caller error', () async {
      expect(
        () => db.todoDao.setNextActionTextIfActionless('o1', '   ', now: _t1),
        throwsArgumentError,
      );
    });
  });

  group('applyRouting', () {
    test('nextAction with text yields a matching current Action', () async {
      await db.todoDao.applyRouting('o1',
          to: RoutingKind.nextAction, nextActionText: 'do the thing', now: _t1);
      await _expectEquiv(db, 'o1');
    });

    test('waitingFor with text yields a matching current Action', () async {
      await db.todoDao.applyRouting('o1',
          to: RoutingKind.waitingFor,
          nextActionText: 'follow up with Trixy',
          now: _t1);
      await _expectEquiv(db, 'o1');
    });

    test('nextAction with a blank phrase clears the current Action', () async {
      await db.todoDao
          .applyRouting('o1', to: RoutingKind.nextAction, nextActionText: 'x', now: _t1);
      await db.todoDao.applyRouting('o1',
          to: RoutingKind.nextAction, nextActionText: '   ', now: _t2);

      expect(await _cursor(db, 'o1'), isNull);
      await _expectEquiv(db, 'o1');
    });

    test('absent nextActionText touches neither the cursor nor the Action',
        () async {
      await db.todoDao
          .applyRouting('o1', to: RoutingKind.nextAction, nextActionText: 'keep me', now: _t1);
      // Re-route with no phrase: the cursor is preserved and so is the Action.
      await db.todoDao.applyRouting('o1', to: RoutingKind.nextAction, now: _t2);

      expect(await _cursor(db, 'o1'), 'keep me');
      await _expectEquiv(db, 'o1');
    });

    test('maybe / done / trash arms write no Action rows', () async {
      for (final (id, kind) in [
        ('om', RoutingKind.maybe),
        ('od', RoutingKind.done),
        ('otr', RoutingKind.trash),
      ]) {
        await _seedOutcome(db, id: id);
        await db.todoDao.applyRouting(id, to: kind, now: _t1);
        final any = await db
            .customSelect(
              "SELECT COUNT(*) AS c FROM actions WHERE outcome_id = ?",
              variables: [Variable<String>(id)],
            )
            .getSingle();
        expect(any.data['c'], 0, reason: '$kind must not write an Action');
      }
    });

    test('carve path: insertOutcome then applyRouting mints the Action '
        'atomically with the Outcome', () async {
      await db.todoDao.insertOutcome(
        id: 'carved',
        title: 'Carved outcome',
        userId: _userId,
        now: _t1,
      );
      await db.todoDao.applyRouting('carved',
          to: RoutingKind.nextAction, nextActionText: 'first action', now: _t1);
      await _expectEquiv(db, 'carved');
    });
  });

  group('deleteOutcome', () {
    test('cascades the Outcome Action rows, leaving no orphans', () async {
      await db.todoDao.setNextActionText('o1', 'x', now: _t1);
      // Also leave a terminated row to prove the cascade removes every role.
      await db.actionDao.supersedeCurrentAction('o1', newActionText: 'y', now: _t2);

      await db.todoDao.deleteOutcome('o1');

      final remaining = await db
          .customSelect("SELECT COUNT(*) AS c FROM actions WHERE outcome_id = 'o1'")
          .getSingle();
      expect(remaining.data['c'], 0);
    });
  });
}
