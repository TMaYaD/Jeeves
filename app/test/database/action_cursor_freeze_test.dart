/// The cursor is frozen: **no code path writes `todos.next_action_text`**
/// (ADR-0001 story 9, issue #479; ADR-0022).
///
/// This suite replaces the dual-write equivalence suite it grew out of. That
/// one pinned "cursor and current Action agree after every write"; this one
/// pins the opposite half of the same boundary — the Action side is the only
/// side that moves, and the legacy column is inert.
///
/// **Method.** Every fixture seeds `next_action_text` to a sentinel string that
/// no production path would ever produce. Asserting the sentinel is *still
/// there* after the primitive catches both failure modes in one assertion:
/// an accidental **write** (the sentinel is replaced by the Action text) and an
/// accidental **clear** (the sentinel becomes NULL). A test that merely asserted
/// `isNull` would silently pass on a re-introduced clear.
///
/// Each test also asserts the `actions`-side outcome, so a primitive that
/// stopped writing the cursor *by doing nothing at all* still fails.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show RoutingKind;
import 'package:jeeves/services/migration_service.dart';
import '../test_helpers.dart';

const _userId = 'test-user';

/// A value no production path can produce, so its survival proves nothing wrote
/// the column and its disappearance proves something cleared it.
const _sentinel = 'LEGACY-SENTINEL';

final _t0 = DateTime.parse('2026-07-01T09:00:00.000Z');
final _t1 = DateTime.parse('2026-07-01T10:00:00.000Z');
final _t2 = DateTime.parse('2026-07-01T11:00:00.000Z');
final _t3 = DateTime.parse('2026-07-01T12:00:00.000Z');

/// Seeds an Outcome whose legacy cursor already holds the sentinel — the shape
/// of a real store that a pre-retirement client (or the #471 backfill) wrote.
Future<void> _seedOutcome(GtdDatabase db, {String id = 'o1'}) async {
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        userId: const Value(_userId),
        createdAt: Value(_t0),
        nextActionText: const Value(_sentinel),
      ));
}

Future<Todo> _todo(GtdDatabase db, String id) =>
    (db.select(db.todos)..where((t) => t.id.equals(id))).getSingle();

/// The whole point of the suite: the legacy column is exactly as it was seeded.
Future<void> _expectCursorFrozen(GtdDatabase db, [String id = 'o1']) async {
  expect(
    (await _todo(db, id)).nextActionText,
    _sentinel,
    reason: 'nothing may write or clear the legacy next_action_text cursor',
  );
}

Future<List<Map<String, Object?>>> _actions(
  GtdDatabase db,
  String outcomeId, {
  String? role,
}) async {
  final rows = await db
      .customSelect(
        'SELECT * FROM actions WHERE outcome_id = ?'
        '${role == null ? '' : ' AND role = ?'} ORDER BY id',
        variables: [
          Variable<String>(outcomeId),
          if (role != null) Variable<String>(role),
        ],
      )
      .get();
  return [for (final r in rows) r.data];
}

Future<List<Map<String, Object?>>> _currents(GtdDatabase db, String id) =>
    _actions(db, id, role: 'current');

/// The startup sweep, driven over the same query/exec seam production uses.
/// `reconcileActionsAtStartup` supplies nothing but the write transaction.
Future<int> _sweep(GtdDatabase db) => db.transaction(
      () => convergeMultiCurrentActions(
        query: (sql, args) async {
          final rows = await db
              .customSelect(sql, variables: [for (final a in args) Variable(a)])
              .get();
          return [for (final r in rows) r.data];
        },
        exec: (sql, args) => db.customStatement(sql, args),
        now: _t3,
      ),
    );

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    await _seedOutcome(db);
  });
  tearDown(() => db.close());

  group('TodoDao.setNextActionText', () {
    test('a fresh set mints the current Action and leaves the cursor frozen',
        () async {
      await db.todoDao.setNextActionText('o1', 'call plumber', now: _t1);

      expect((await _currents(db, 'o1')).single['text'], 'call plumber');
      await _expectCursorFrozen(db);
    });

    test('an overwrite edits the Action in place, cursor frozen', () async {
      await db.todoDao.setNextActionText('o1', 'first', now: _t1);
      final firstId = (await _currents(db, 'o1')).single['id'];

      await db.todoDao.setNextActionText('o1', 'second', now: _t2);

      final currents = await _currents(db, 'o1');
      expect(currents.single['id'], firstId, reason: 'same Action identity');
      expect(currents.single['text'], 'second');
      await _expectCursorFrozen(db);
    });

    test('a blank retires the Action without clearing the cursor', () async {
      await db.todoDao.setNextActionText('o1', 'something', now: _t1);
      await db.todoDao.setNextActionText('o1', '', now: _t2);

      expect(await _currents(db, 'o1'), isEmpty);
      expect((await _actions(db, 'o1')).single['role'], 'superseded',
          reason: 'the cleared Action is retired, not deleted (ADR-0018)');
      await _expectCursorFrozen(db);
    });

    test('still stamps last_clarified_at (stamping parity)', () async {
      await db.todoDao.setNextActionText('o1', 'x', now: _t1);
      expect((await _todo(db, 'o1')).lastClarifiedAt, _t1);
    });
  });

  group('TodoDao.setNextActionTextIfActionless', () {
    test('the write path mints the Action and leaves the cursor frozen',
        () async {
      final wrote =
          await db.todoDao.setNextActionTextIfActionless('o1', 'Book venue', now: _t1);

      expect(wrote, isTrue);
      expect((await _currents(db, 'o1')).single['text'], 'Book venue');
      expect((await _todo(db, 'o1')).lastClarifiedAt, _t1,
          reason: 'the write path still stamps');
      await _expectCursorFrozen(db);
    });

    test('the skip path (#501 TOCTOU guard) writes nothing at all', () async {
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

      expect(wrote, isFalse);
      expect((await _currents(db, 'o1')).single['text'], 'deliberate phrase');
      final after = await _todo(db, 'o1');
      expect(after.lastClarifiedAt, before.lastClarifiedAt,
          reason: 'the skip path stamps nothing');
      expect(after.updatedAt, before.updatedAt);
      await _expectCursorFrozen(db);
    });

    test('blank text is a caller error', () async {
      expect(
        () => db.todoDao.setNextActionTextIfActionless('o1', '   ', now: _t1),
        throwsArgumentError,
      );
    });
  });

  group('TodoDao.applyRouting', () {
    test('nextAction with a phrase mints the Action, cursor frozen', () async {
      await db.todoDao.applyRouting('o1',
          to: RoutingKind.nextAction, nextActionText: 'do the thing', now: _t1);

      expect((await _currents(db, 'o1')).single['text'], 'do the thing');
      expect((await _todo(db, 'o1')).intent, 'next');
      await _expectCursorFrozen(db);
    });

    test('waitingFor with a phrase mints the Action, cursor frozen', () async {
      await db.todoDao.applyRouting('o1',
          to: RoutingKind.waitingFor,
          nextActionText: 'follow up with Trixy',
          now: _t1);

      expect((await _currents(db, 'o1')).single['text'], 'follow up with Trixy');
      await _expectCursorFrozen(db);
    });

    test('nextAction with a blank phrase retires the Action, cursor frozen',
        () async {
      await db.todoDao.applyRouting('o1',
          to: RoutingKind.nextAction, nextActionText: 'x', now: _t1);
      await db.todoDao.applyRouting('o1',
          to: RoutingKind.nextAction, nextActionText: '   ', now: _t2);

      expect(await _currents(db, 'o1'), isEmpty);
      await _expectCursorFrozen(db);
    });

    test('an absent phrase touches no Action row, cursor frozen', () async {
      await db.todoDao.applyRouting('o1',
          to: RoutingKind.nextAction, nextActionText: 'keep me', now: _t1);
      await db.todoDao.applyRouting('o1', to: RoutingKind.nextAction, now: _t2);

      expect((await _currents(db, 'o1')).single['text'], 'keep me');
      await _expectCursorFrozen(db);
    });

    test('maybe / trash write no Action rows and leave the cursor frozen',
        () async {
      for (final (id, kind) in [
        ('om', RoutingKind.maybe),
        ('otr', RoutingKind.trash),
      ]) {
        await _seedOutcome(db, id: id);
        await db.todoDao.applyRouting(id, to: kind, now: _t1);

        expect(await _actions(db, id), isEmpty,
            reason: '$kind must not write an Action');
        await _expectCursorFrozen(db, id);
      }
    });

    test('done completes a real current Action and leaves the cursor frozen',
        () async {
      // With a real Action present, `done` runs the completion cascade. Before
      // #479 that cascade also cleared the cursor; it must not any more.
      await seedCurrentAction(
        db,
        outcomeId: 'o1',
        text: 'finish it',
        userId: _userId,
        createdAt: _t0,
      );

      await db.todoDao.applyRouting('o1', to: RoutingKind.done, now: _t1);

      expect(await _currents(db, 'o1'), isEmpty);
      expect((await _actions(db, 'o1')).single['role'], 'done');
      expect((await _todo(db, 'o1')).doneAt, isNotNull);
      await _expectCursorFrozen(db);
    });

    test('done on an Actionless Outcome writes no Action, cursor frozen',
        () async {
      await db.todoDao.applyRouting('o1', to: RoutingKind.done, now: _t1);

      expect(await _actions(db, 'o1'), isEmpty);
      await _expectCursorFrozen(db);
    });
  });

  group('TodoDao.markDone', () {
    test('completes the current Action and leaves the cursor frozen', () async {
      await seedCurrentAction(
        db,
        outcomeId: 'o1',
        text: 'finish it',
        userId: _userId,
        createdAt: _t0,
      );

      await db.todoDao.markDone('o1', now: _t1);

      expect((await _actions(db, 'o1')).single['role'], 'done');
      await _expectCursorFrozen(db);
    });
  });

  group('ActionDao current-Action primitives', () {
    setUp(() async {
      await seedCurrentAction(
        db,
        outcomeId: 'o1',
        text: 'the current thing',
        userId: _userId,
        createdAt: _t0,
      );
    });

    test('completeCurrentAction: cursor frozen, and it still does not stamp',
        () async {
      final before = await _todo(db, 'o1');

      await db.actionDao.completeCurrentAction('o1', now: _t1);

      expect((await _actions(db, 'o1')).single['role'], 'done');
      expect((await _todo(db, 'o1')).lastClarifiedAt, before.lastClarifiedAt,
          reason: 'completion is engagement, not clarification (ADR-0012)');
      await _expectCursorFrozen(db);
    });

    test('supersedeCurrentAction with a replacement: cursor frozen', () async {
      await db.actionDao
          .supersedeCurrentAction('o1', newActionText: 'the new thing', now: _t1);

      expect((await _currents(db, 'o1')).single['text'], 'the new thing');
      expect(await _actions(db, 'o1', role: 'superseded'), hasLength(1));
      expect((await _todo(db, 'o1')).lastClarifiedAt, _t1,
          reason: 'supersession stamps');
      await _expectCursorFrozen(db);
    });

    test('supersedeCurrentAction mirrors energy/time metadata onto the Outcome',
        () async {
      // The D4 metadata mirror is #477's, deliberately NOT retired by #479 —
      // the D2 read fallback still depends on it. Only the *text* cursor froze.
      await db.actionDao.supersedeCurrentAction(
        'o1',
        newActionText: 'the new thing',
        newEnergyLevel: 'high',
        newTimeEstimate: 45,
        now: _t1,
      );

      final todo = await _todo(db, 'o1');
      expect(todo.energyLevel, 'high');
      expect(todo.timeEstimate, 45);
      await _expectCursorFrozen(db);
    });

    test('the abandon arm retires without clearing the cursor', () async {
      await db.actionDao.supersedeCurrentAction('o1', now: _t1);

      expect(await _currents(db, 'o1'), isEmpty);
      expect((await _actions(db, 'o1')).single['role'], 'superseded');
      await _expectCursorFrozen(db);
    });

    test('clearCurrentAction leaves the cursor frozen', () async {
      await db.actionDao.clearCurrentAction('o1', now: _t1);

      expect(await _currents(db, 'o1'), isEmpty);
      await _expectCursorFrozen(db);
    });

    test('editAction on the current row leaves the cursor frozen', () async {
      final id = (await _currents(db, 'o1')).single['id']! as String;

      await db.actionDao.editAction(id, text: 'refined phrasing', now: _t1);

      expect((await _currents(db, 'o1')).single['text'], 'refined phrasing');
      await _expectCursorFrozen(db);
    });

    test('demoteCurrentAction leaves the cursor frozen', () async {
      final id = (await _currents(db, 'o1')).single['id']! as String;

      await db.actionDao.demoteCurrentAction(id, now: _t1);

      expect(await _currents(db, 'o1'), isEmpty);
      expect((await _actions(db, 'o1', role: 'planned')).single['id'], id);
      expect((await _todo(db, 'o1')).lastClarifiedAt, _t1,
          reason: 'demote stamps');
      await _expectCursorFrozen(db);
    });

    test('supersedeAndPromote leaves the cursor frozen', () async {
      await db.actionDao.addPlannedAction('o1', 'the planned thing', now: _t1);
      final plannedId =
          (await _actions(db, 'o1', role: 'planned')).single['id']! as String;

      await db.actionDao.supersedeAndPromote(plannedId, now: _t2);

      final currents = await _currents(db, 'o1');
      expect(currents.single['id'], plannedId);
      expect(currents.single['text'], 'the planned thing');
      expect(await _actions(db, 'o1', role: 'superseded'), hasLength(1));
      await _expectCursorFrozen(db);
    });
  });

  group('ActionDao planned-queue primitives', () {
    test('addPlannedAction leaves the cursor frozen', () async {
      await db.actionDao.addPlannedAction('o1', 'later thing', now: _t1);

      expect((await _actions(db, 'o1', role: 'planned')).single['text'],
          'later thing');
      expect((await _todo(db, 'o1')).lastClarifiedAt, _t1);
      await _expectCursorFrozen(db);
    });

    test('promotePlannedAction leaves the cursor frozen', () async {
      await db.actionDao.addPlannedAction('o1', 'later thing', now: _t1);
      final plannedId =
          (await _actions(db, 'o1', role: 'planned')).single['id']! as String;

      await db.actionDao.promotePlannedAction(plannedId, now: _t2);

      expect((await _currents(db, 'o1')).single['text'], 'later thing');
      await _expectCursorFrozen(db);
    });

    test('★ removePlannedAction leaves the cursor frozen — and the sweep does '
        'not mint the deleted Action back', () async {
      // `applyRemovePlannedAction` is a hard DELETE (the Remove-vs-Abandon
      // distinction #478 shipped) and it is the ONLY mutation that drives an
      // Outcome to zero `actions` rows while the `todos` row — and its frozen
      // cursor — survives. The deleted cursor-adoption pass minted a `current`
      // Action for exactly that shape, so the launch after this sequence used to
      // resurrect the row the user had just removed, and sync it everywhere.
      // Nothing reads the cursor at runtime any more, so relaunching is inert.
      await db.actionDao.addPlannedAction('o1', 'later thing', now: _t1);
      final plannedId =
          (await _actions(db, 'o1', role: 'planned')).single['id']! as String;

      await db.actionDao.removePlannedAction(plannedId, now: _t2);

      expect(await _actions(db, 'o1'), isEmpty);
      await _expectCursorFrozen(db);

      // Relaunch. Restoring the adoption pass makes this mint a `current` row.
      expect(await _sweep(db), 0);
      expect(await _actions(db, 'o1'), isEmpty,
          reason: 'a live cursor over zero Action rows must mint nothing');
      await _expectCursorFrozen(db);
    });

    test('★ the two-tap resurrection: demote then remove, then relaunch, mints '
        'nothing', () async {
      // The same hole reached through the affordances a user actually taps: the
      // current Action is demoted (which no longer clears the cursor) and the
      // planned row it became is then removed outright.
      await db.todoDao.setNextActionText('o1', 'the thing', now: _t1);
      final currentId = (await _currents(db, 'o1')).single['id']! as String;

      await db.actionDao.demoteCurrentAction(currentId, now: _t2);
      await db.actionDao.removePlannedAction(currentId, now: _t2);

      expect(await _actions(db, 'o1'), isEmpty, reason: 'precondition');
      await _expectCursorFrozen(db);

      expect(await _sweep(db), 0);
      expect(await _currents(db, 'o1'), isEmpty,
          reason: 'the removed Action must not come back as current');
      expect(await _actions(db, 'o1'), isEmpty);
    });

    test('editAction on a planned row leaves the cursor frozen', () async {
      await db.actionDao.addPlannedAction('o1', 'later thing', now: _t1);
      final plannedId =
          (await _actions(db, 'o1', role: 'planned')).single['id']! as String;

      await db.actionDao.editAction(plannedId, text: 'later, better', now: _t2);

      expect((await _actions(db, 'o1', role: 'planned')).single['text'],
          'later, better');
      await _expectCursorFrozen(db);
    });
  });

  group('TodoDao Outcome lifecycle', () {
    test('updateFields leaves the cursor frozen', () async {
      await seedCurrentAction(
        db,
        outcomeId: 'o1',
        text: 'the current thing',
        userId: _userId,
        createdAt: _t0,
      );

      await db.todoDao.updateFields(
        'o1',
        title: 'Renamed outcome',
        energyLevel: 'low',
        timeEstimate: 15,
      );

      final todo = await _todo(db, 'o1');
      expect(todo.title, 'Renamed outcome');
      // The energy/time mirror (D1) is out of #479's scope and must survive.
      expect(todo.energyLevel, 'low');
      expect(todo.timeEstimate, 15);
      expect((await _currents(db, 'o1')).single['energy_level'], 'low',
          reason: 'metadata still reaches the Action row');
      await _expectCursorFrozen(db);
    });

    test('insertOutcome never writes the cursor at all', () async {
      await db.todoDao.insertOutcome(
        id: 'fresh',
        title: 'Fresh outcome',
        userId: _userId,
        energyLevel: 'high',
        timeEstimate: 30,
        now: _t1,
      );

      final todo = await _todo(db, 'fresh');
      expect(todo.nextActionText, isNull,
          reason: 'a newly created Outcome has no legacy cursor value');
      // The Actionless draft store (D3) is out of #479's scope.
      expect(todo.energyLevel, 'high');
      expect(todo.timeEstimate, 30);
    });

    test('deleteOutcome cascades Action rows and spares its siblings', () async {
      await db.todoDao.setNextActionText('o1', 'x', now: _t1);
      await db.actionDao
          .supersedeCurrentAction('o1', newActionText: 'y', now: _t2);
      await _seedOutcome(db, id: 'sibling');
      await db.todoDao.setNextActionText('sibling', 'keep me', now: _t3);

      await db.todoDao.deleteOutcome('o1');

      expect(await _actions(db, 'o1'), isEmpty);
      expect((await _currents(db, 'sibling')).single['text'], 'keep me');
      await _expectCursorFrozen(db, 'sibling');
    });
  });

  // ---------------------------------------------------------------------------
  // The keystone. Freezing the cursor is only safe because the startup sweep
  // can no longer act on the divergence that freezing creates — it does not
  // read `todos.next_action_text` at all. This test is what would have caught
  // the deleted Pass B: it drives a realistic lifecycle — leaving a stale
  // sentinel cursor beside every terminal Action state — and then relaunches.
  // The zero-`actions` shape that defeated the deleted adoption pass is pinned
  // by the two removePlannedAction tests above.
  // ---------------------------------------------------------------------------
  group('restart idempotency', () {
    test('a full plan lifecycle survives the startup sweep byte-identically',
        () async {
      // add planned → promote → demote → promote → complete → abandon,
      // all on an Outcome whose legacy cursor still holds the sentinel.
      await db.actionDao.addPlannedAction('o1', 'draft the brief', now: _t1);
      final plannedId =
          (await _actions(db, 'o1', role: 'planned')).single['id']! as String;

      await db.actionDao.promotePlannedAction(plannedId, now: _t1);
      await db.actionDao.demoteCurrentAction(plannedId, now: _t2);
      await db.actionDao.promotePlannedAction(plannedId, now: _t2);
      await db.actionDao.completeCurrentAction('o1', now: _t3);

      // A second Outcome ends the lifecycle abandoned rather than completed,
      // so both terminal shapes are on the store when the sweep runs.
      await _seedOutcome(db, id: 'o2');
      await db.todoDao.setNextActionText('o2', 'the abandoned thing', now: _t1);
      await db.actionDao.clearCurrentAction('o2', now: _t2);

      final before = await _actions(db, 'o1');
      final beforeO2 = await _actions(db, 'o2');
      expect(before.single['role'], 'done');
      expect(beforeO2.single['role'], 'superseded');
      // Precondition: both Outcomes now hold a stale non-blank cursor with no
      // `current` Action — precisely the shape the deleted Pass B destroyed and
      // that old mode 3 would have resurrected.
      await _expectCursorFrozen(db);
      await _expectCursorFrozen(db, 'o2');

      final repaired = await _sweep(db);

      expect(repaired, 0, reason: 'a frozen-cursor store needs no repair');
      expect(await _actions(db, 'o1'), before,
          reason: 'the completed Action must survive the relaunch untouched');
      expect(await _actions(db, 'o2'), beforeO2,
          reason: 'the abandoned Action must not be resurrected');
      await _expectCursorFrozen(db);
      await _expectCursorFrozen(db, 'o2');

      // And the sweep stays clarification-neutral (ADR-0012).
      expect((await _todo(db, 'o1')).lastClarifiedAt, _t2);
    });

    test('a second sweep is still a no-op', () async {
      await db.todoDao.setNextActionText('o1', 'a live action', now: _t1);
      final before = await _actions(db, 'o1');

      expect(await _sweep(db), 0);
      expect(await _sweep(db), 0);

      expect(await _actions(db, 'o1'), before);
      await _expectCursorFrozen(db);
    });
  });
}
