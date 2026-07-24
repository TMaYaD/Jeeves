/// Reads move to Action rows (ADR-0001 story 3, issue #473).
///
/// The Next List rule and the re-clarification predicates now answer "does this
/// Outcome have a current Action?" from the `actions` table, not from the
/// `todos.next_action_text` cursor. These tests pin three things:
///
/// * **Parity** — on a store seeded through the public (dual-writing) write
///   paths, the new Action-grain predicates return exactly what the frozen
///   cursor-grain clauses return.
/// * **Entity grain** — only `role='current'` counts (a `planned` row is not
///   engageable, ADR-0004; a `superseded`-only Outcome is Actionless), and a
///   multi-current race resolves to the deterministic winner *in the read*
///   without repairing anything.
/// * **Reads never write** — no new read moves `last_clarified_at` or touches
///   an `actions` row. Repair belongs to the writers and the startup sweep.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

const _userId = 'test-user';
final _t0 = DateTime.parse('2026-07-01T09:00:00.000Z');
final _t1 = DateTime.parse('2026-07-01T10:00:00.000Z');
final _t2 = DateTime.parse('2026-07-01T11:00:00.000Z');

/// The **frozen** pre-#473 cursor-grain clauses, kept verbatim so the parity
/// test compares against what shipped rather than against a re-derivation.
const _frozenNextWhere = '''
clarified = 1 AND done_at IS NULL AND intent = 'next'
AND (
  (todos.next_action_text IS NOT NULL AND TRIM(todos.next_action_text) != '')
  OR NOT EXISTS (
    SELECT 1 FROM todo_tags tt
    JOIN tags tg ON tg.id = tt.tag_id
    WHERE tt.todo_id = todos.id AND tg.type = 'person'
  )
)''';

const _frozenNeedsReviewWhere = '''
clarified = 1
AND done_at IS NULL
AND intent = 'next'
AND (
  (last_next_action_completion_at IS NOT NULL
   AND (last_clarified_at IS NULL
        OR last_clarified_at < last_next_action_completion_at))
  OR (
    (next_action_text IS NULL OR TRIM(next_action_text) = '')
    AND NOT EXISTS (
      SELECT 1 FROM todo_tags tt
      JOIN tags tg ON tg.id = tt.tag_id
      WHERE tt.todo_id = todos.id AND tg.type = 'person'
    )
  )
)''';

Future<List<String>> _idsMatching(GtdDatabase db, String where) async {
  final rows = await db
      .customSelect('SELECT id FROM todos WHERE $where ORDER BY created_at')
      .get();
  return rows.map((r) => r.read<String>('id')).toList();
}

Future<String> _seedOutcome(
  GtdDatabase db,
  String id, {
  bool clarified = true,
  String intent = 'next',
  String? doneAt,
  DateTime? lastNextActionCompletionAt,
  DateTime? lastClarifiedAt,
  DateTime? createdAt,
}) async {
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        userId: const Value(_userId),
        clarified: Value(clarified),
        intent: Value(intent),
        doneAt: Value(doneAt),
        createdAt: Value(createdAt ?? _t0),
        lastNextActionCompletionAt: Value(lastNextActionCompletionAt),
        lastClarifiedAt: Value(lastClarifiedAt),
      ));
  return id;
}

Future<void> _attachPersonTag(GtdDatabase db, String outcomeId) async {
  final tagId = 'ptag-$outcomeId';
  await db.into(db.tags).insert(TagsCompanion(
        id: Value(tagId),
        name: Value('Trixy-$outcomeId'),
        type: const Value('person'),
        userId: const Value(_userId),
      ));
  await db.into(db.todoTags).insert(TodoTagsCompanion(
        id: Value('tt-$tagId'),
        todoId: Value(outcomeId),
        tagId: Value(tagId),
        userId: const Value(_userId),
      ));
}

/// Inserts an `actions` row directly — the only way to reach shapes the write
/// paths refuse to mint (planned rows, multi-current races, cursor skew).
Future<void> _rawAction(
  GtdDatabase db, {
  required String id,
  required String outcomeId,
  required String text,
  String role = 'current',
  DateTime? createdAt,
  DateTime? updatedAt,
}) async {
  await db.into(db.actions).insert(ActionsCompanion(
        id: Value(id),
        outcomeId: Value(outcomeId),
        userId: const Value(_userId),
        actionText: Value(text),
        role: Value(role),
        createdAt: Value(createdAt ?? _t0),
        updatedAt: Value(updatedAt),
      ));
}

Future<List<Map<String, Object?>>> _allActions(GtdDatabase db) async {
  final rows =
      await db.customSelect('SELECT * FROM actions ORDER BY id').get();
  return rows.map((r) => r.data).toList();
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() => db = GtdDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  // ---------------------------------------------------------------------------
  // ActionDao read primitives
  // ---------------------------------------------------------------------------

  group('ActionDao read primitives', () {
    test('getCurrentAction returns null for an Outcome with no Action rows',
        () async {
      await _seedOutcome(db, 'o1');
      expect(await db.actionDao.getCurrentAction('o1'), isNull);
    });

    test('getCurrentAction returns the current row, ignoring other roles',
        () async {
      await _seedOutcome(db, 'o1');
      await _rawAction(db, id: 'a-old', outcomeId: 'o1', text: 'Old', role: 'superseded');
      await _rawAction(db, id: 'a-new', outcomeId: 'o1', text: 'Now');

      final action = await db.actionDao.getCurrentAction('o1');
      expect(action!.id, 'a-new');
      expect(action.actionText, 'Now');
    });

    test('getCurrentAction on a multi-current race picks the winner and repairs nothing',
        () async {
      await _seedOutcome(db, 'o1');
      // Winner rule: greatest COALESCE(updated_at, created_at), tie-break
      // smallest id — the same rule ActionDao._winnerFirst applies on writes.
      await _rawAction(db, id: 'a-1', outcomeId: 'o1', text: 'Older', createdAt: _t0);
      await _rawAction(db,
          id: 'a-2', outcomeId: 'o1', text: 'Newer', createdAt: _t0, updatedAt: _t2);

      final before = await _allActions(db);
      final action = await db.actionDao.getCurrentAction('o1');
      expect(action!.id, 'a-2');
      expect(await _allActions(db), before, reason: 'a read must not converge');
    });

    test('getCurrentAction tie-breaks equal timestamps on the smallest id',
        () async {
      await _seedOutcome(db, 'o1');
      await _rawAction(db, id: 'a-b', outcomeId: 'o1', text: 'B', createdAt: _t1);
      await _rawAction(db, id: 'a-a', outcomeId: 'o1', text: 'A', createdAt: _t1);

      expect((await db.actionDao.getCurrentAction('o1'))!.id, 'a-a');
    });

    test('watchCurrentAction re-emits when the current Action changes', () async {
      await _seedOutcome(db, 'o1');
      final emissions = <String?>[];
      final sub = db.actionDao
          .watchCurrentAction('o1')
          .listen((a) => emissions.add(a?.actionText));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await db.actionDao.setCurrentAction('o1', 'Call the plumber');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await db.actionDao.clearCurrentAction('o1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();

      expect(emissions.first, isNull);
      expect(emissions, contains('Call the plumber'));
      expect(emissions.last, isNull);
    });

    test('getCurrentActionTexts keys by Outcome id and omits Actionless ones',
        () async {
      await _seedOutcome(db, 'o1');
      await _seedOutcome(db, 'o2');
      await _seedOutcome(db, 'o3');
      await db.actionDao.setCurrentAction('o1', 'Draft the letter');
      await _rawAction(db, id: 'a-2', outcomeId: 'o2', text: 'Retired', role: 'superseded');

      final texts =
          await db.actionDao.getCurrentActionTexts({'o1', 'o2', 'o3'});
      expect(texts, {'o1': 'Draft the letter'});
    });

    test('getCurrentActionTexts is empty for an empty id set', () async {
      expect(await db.actionDao.getCurrentActionTexts(const {}), isEmpty);
    });

    test('getCurrentActionTexts chunks past the SQLite variable limit',
        () async {
      final ids = <String>{};
      for (var i = 0; i < 1200; i++) {
        final id = 'o${i.toString().padLeft(4, '0')}';
        ids.add(id);
        await _seedOutcome(db, id);
        await _rawAction(db, id: 'a-$id', outcomeId: id, text: 'Do $id');
      }

      final texts = await db.actionDao.getCurrentActionTexts(ids);
      expect(texts.length, 1200);
      expect(texts['o0000'], 'Do o0000');
      expect(texts['o1199'], 'Do o1199');
    });

    test('getCurrentActionTexts resolves a multi-current race deterministically',
        () async {
      await _seedOutcome(db, 'o1');
      await _rawAction(db, id: 'a-1', outcomeId: 'o1', text: 'Older', createdAt: _t0);
      await _rawAction(db,
          id: 'a-2', outcomeId: 'o1', text: 'Newer', createdAt: _t0, updatedAt: _t2);

      expect(await db.actionDao.getCurrentActionTexts({'o1'}), {'o1': 'Newer'});
    });
  });

  // ---------------------------------------------------------------------------
  // Parity with the frozen cursor-grain clauses
  // ---------------------------------------------------------------------------

  group('predicate parity on a dual-written store', () {
    /// Seeds one Outcome per interesting quadrant **through the public write
    /// paths**, so the cursor column and the Action rows agree by construction.
    Future<void> seedRepresentativeStore() async {
      // Actioned.
      await _seedOutcome(db, 'actioned', createdAt: _t0);
      await db.todoDao.setNextActionText('actioned', 'Book the venue');

      // Actionless.
      await _seedOutcome(db, 'actionless', createdAt: _t0);

      // Actionless + PersonBlocked — the single excluded Next quadrant.
      await _seedOutcome(db, 'actionless-blocked', createdAt: _t0);
      await _attachPersonTag(db, 'actionless-blocked');

      // Actioned + PersonBlocked — on Next *and* Waiting For, by design.
      await _seedOutcome(db, 'actioned-blocked', createdAt: _t0);
      await _attachPersonTag(db, 'actioned-blocked');
      await db.todoDao.setNextActionText('actioned-blocked', 'Chase Trixy');

      // Whitespace-cleared — the blank→NULL normalisation on both sides.
      await _seedOutcome(db, 'cleared', createdAt: _t0);
      await db.todoDao.setNextActionText('cleared', 'Temporary');
      await db.todoDao.setNextActionText('cleared', '   ');

      // Stale (worked on in a session after the last clarification).
      await _seedOutcome(db, 'stale',
          createdAt: _t0,
          lastClarifiedAt: _t0,
          lastNextActionCompletionAt: _t2);
      await db.todoDao.setNextActionText('stale', 'Keep going');
      await (db.update(db.todos)..where((t) => t.id.equals('stale'))).write(
        TodosCompanion(lastClarifiedAt: Value(_t0)),
      );

      // Done / someday / trashed / unclarified — out of every list.
      await _seedOutcome(db, 'done',
          createdAt: _t0, doneAt: _t2.toIso8601String());
      await _seedOutcome(db, 'someday', createdAt: _t0, intent: 'maybe');
      await _seedOutcome(db, 'trashed', createdAt: _t0, intent: 'trash');
      await _seedOutcome(db, 'unclarified', createdAt: _t0, clarified: false);
    }

    setUp(seedRepresentativeStore);

    test('watchNext matches the frozen cursor clause', () async {
      final expected = await _idsMatching(db, _frozenNextWhere);
      final actual =
          (await db.todoDao.watchNext().first).map((t) => t.id).toList();
      expect(actual, expected);
      expect(actual, isNotEmpty);
    });

    test('watchNext under a tag filter matches the frozen cursor clause',
        () async {
      final tagId = 'ptag-actioned-blocked';
      final expected = await _idsMatching(
        db,
        "$_frozenNextWhere AND EXISTS (SELECT 1 FROM todo_tags tt2 "
        "WHERE tt2.todo_id = todos.id AND tt2.tag_id = '$tagId')",
      );
      final actual = (await db.todoDao.watchNext(tagIds: {tagId}).first)
          .map((t) => t.id)
          .toList();
      expect(actual, expected);
      expect(actual, ['actioned-blocked']);
    });

    test('the re-clarify queue matches the frozen cursor clause', () async {
      final expected = await _idsMatching(db, _frozenNeedsReviewWhere);

      expect((await db.todoDao.watchNeedsReview().first).map((t) => t.id),
          expected);
      expect((await db.todoDao.getNeedsReview()).map((t) => t.id), expected);
      expect(await db.todoDao.getNeedsReviewCount(), expected.length);
      for (final id in ['actionless', 'stale', 'cleared', 'actioned', 'done']) {
        expect(await db.todoDao.isNeedsReview(id), expected.contains(id),
            reason: 'isNeedsReview disagrees for $id');
      }
      expect(expected, isNotEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Entity grain: only role='current' counts
  // ---------------------------------------------------------------------------

  group('entity grain', () {
    test('a planned Action satisfies no "has current Action" predicate',
        () async {
      await _seedOutcome(db, 'planned-only');
      await _attachPersonTag(db, 'planned-only');
      await _rawAction(db,
          id: 'a-planned',
          outcomeId: 'planned-only',
          text: 'Later',
          role: 'planned');

      // PersonBlocked + no *current* Action ⇒ off Next.
      expect((await db.todoDao.watchNext().first).map((t) => t.id),
          isNot(contains('planned-only')));
      expect(await db.actionDao.getCurrentAction('planned-only'), isNull);

      // Un-blocked, a planned-only Outcome is still Actionless for re-clarify.
      await _seedOutcome(db, 'planned-unblocked');
      await _rawAction(db,
          id: 'a-planned-2',
          outcomeId: 'planned-unblocked',
          text: 'Later',
          role: 'planned');
      expect(await db.todoDao.isNeedsReview('planned-unblocked'), isTrue);
    });

    test('a superseded-only Outcome is Actionless', () async {
      await _seedOutcome(db, 'retired');
      await _rawAction(db,
          id: 'a-retired',
          outcomeId: 'retired',
          text: 'Done with this',
          role: 'superseded');
      expect(await db.todoDao.isNeedsReview('retired'), isTrue);
      expect(await db.actionDao.getCurrentAction('retired'), isNull);
    });

    test('the Action row wins over a skewed cursor', () async {
      // A pre-#472 client PATCHed the cursor without minting an Action row.
      await _seedOutcome(db, 'skewed');
      await (db.update(db.todos)..where((t) => t.id.equals('skewed'))).write(
        const TodosCompanion(nextActionText: Value('Cursor says actioned')),
      );
      await _attachPersonTag(db, 'skewed');

      expect((await db.todoDao.watchNext().first).map((t) => t.id),
          isNot(contains('skewed')));
      expect(await db.todoDao.isNeedsReview('skewed'), isFalse,
          reason: 'PersonBlocked Outcomes never enter the Actionless branch');

      // …and the converse: an Action row with a NULL cursor is engageable.
      await _seedOutcome(db, 'action-only');
      await _attachPersonTag(db, 'action-only');
      await _rawAction(db,
          id: 'a-only', outcomeId: 'action-only', text: 'Real action');
      expect((await db.todoDao.watchNext().first).map((t) => t.id),
          contains('action-only'));
    });
  });

  // ---------------------------------------------------------------------------
  // Watcher wiring
  // ---------------------------------------------------------------------------

  group('watcher wiring', () {
    test('an ActionDao write re-emits watchNext and watchNeedsReview',
        () async {
      await _seedOutcome(db, 'o1');
      await _attachPersonTag(db, 'o1');

      final nextEmissions = <List<String>>[];
      final reviewEmissions = <List<String>>[];
      final s1 = db.todoDao
          .watchNext()
          .listen((rows) => nextEmissions.add(rows.map((t) => t.id).toList()));
      final s2 = db.todoDao.watchNeedsReview().listen(
          (rows) => reviewEmissions.add(rows.map((t) => t.id).toList()));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await db.actionDao.setCurrentAction('o1', 'Ring them back');
      await Future<void>.delayed(const Duration(milliseconds: 40));

      await s1.cancel();
      await s2.cancel();

      expect(nextEmissions.first, isEmpty);
      expect(nextEmissions.last, ['o1']);
      // PersonBlocked, so it was never in the queue — but the stream must have
      // re-run against `actions` rather than staying stale.
      expect(reviewEmissions.length, greaterThan(1));
    });

    test('a raw actions-view write plus notifyActionsViewWrite re-emits',
        () async {
      await _seedOutcome(db, 'o1');
      await _attachPersonTag(db, 'o1');

      final emissions = <List<String>>[];
      final sub = db.todoDao
          .watchNext()
          .listen((rows) => emissions.add(rows.map((t) => t.id).toList()));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Simulates the sync bridge landing an Action row from another device.
      await _rawAction(db, id: 'a-sync', outcomeId: 'o1', text: 'From afar');
      db.notifyActionsViewWrite();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await sub.cancel();

      expect(emissions.first, isEmpty);
      expect(emissions.last, ['o1']);
    });
  });

  // ---------------------------------------------------------------------------
  // Reads never write
  // ---------------------------------------------------------------------------

  test('no new read stamps last_clarified_at or touches an Action row',
      () async {
    await _seedOutcome(db, 'o1', lastClarifiedAt: _t1);
    await _rawAction(db, id: 'a-1', outcomeId: 'o1', text: 'One', createdAt: _t0);
    await _rawAction(db,
        id: 'a-2', outcomeId: 'o1', text: 'Two', createdAt: _t0, updatedAt: _t2);
    final actionsBefore = await _allActions(db);

    await db.actionDao.getCurrentAction('o1');
    await db.actionDao.getCurrentActionTexts({'o1'});
    await db.actionDao.watchCurrentAction('o1').first;
    await db.todoDao.watchNext().first;
    await db.todoDao.watchNeedsReview().first;
    await db.todoDao.getNeedsReview();
    await db.todoDao.getNeedsReviewCount();
    await db.todoDao.isNeedsReview('o1');
    await db.captureDao.watchCarvedOutcomes('no-such-capture').first;

    final outcome =
        await (db.select(db.todos)..where((t) => t.id.equals('o1'))).getSingle();
    expect(outcome.lastClarifiedAt, _t1);
    expect(await _allActions(db), actionsBefore);
  });
}
