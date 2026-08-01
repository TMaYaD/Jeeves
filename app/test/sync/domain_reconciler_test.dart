/// The convergence *decisions* the projector must not make.
///
/// `DomainProjector` materialises reduced state and authors nothing. Folding two
/// same-`(name, type)` Tag entities onto one is a decision that has to travel to
/// peers, so it authors ops — which is why it lives in [DomainReconciler], is
/// driven from the two batch tails, and is asserted here at the grain the E2E
/// suite (`tag_convergence_test.dart`) cannot see: the exact op set, and the
/// dangling-junction condition in isolation.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/capture_dao.dart' show captureTagIdFor;
import 'package:jeeves/database/daos/tag_dao.dart' show todoTagIdFor;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/domain_op_capture.dart';
import 'package:jeeves/sync/domain_projector.dart';
import 'package:jeeves/sync/domain_reconciler.dart';
import 'package:jeeves/sync/reducer.dart';
import 'package:jeeves/sync/sync_database.dart';

import '../test_helpers.dart';
import 'harness/permutations.dart';

const String _userId = 'test-user';
final DateTime _ts = DateTime.utc(2026, 7, 31, 9);

/// Two ids in the order `MIN(id)` ranks them.
const String _small = 'aaaaaaaa-0000-4000-8000-000000000001';
const String _large = 'bbbbbbbb-0000-4000-8000-000000000002';
const String _third = 'cccccccc-0000-4000-8000-000000000003';

void main() {
  setUpAll(configureSqliteForTests);

  late RecordingDomainOpCapture capture;
  late GtdDatabase db;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    capture = RecordingDomainOpCapture();
    db = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
  });
  tearDown(() async => db.close());

  /// Insert a `tags` row the way the projector does — raw, id-addressed, with no
  /// conflict clause. This is the statement that used to raise on the second
  /// call, and it is deliberately *not* the DAO: `findOrCreateTag` cannot mint a
  /// local duplicate, so nothing else can set the fixture up.
  Future<void> projectTagRow(String id, {String name = 'Alice', String type = 'person'}) =>
      db.customInsert(
        'INSERT INTO "tags" ("id", "name", "type", "user_id") VALUES (?, ?, ?, ?)',
        variables: [
          Variable<String>(id),
          Variable<String>(name),
          Variable<String>(type),
          Variable<String>(_userId),
        ],
      );

  Future<void> seedOutcome(String id) => db.todoDao
      .insertOutcome(id: id, title: 'Outcome $id', userId: _userId, now: _ts);

  /// Put one field of one entity on record in reduced state.
  ///
  /// `reduced_fields` has no visibility column of its own — an entity is hidden
  /// when `row_tombstones` outranks its `field_clocks` — so a fixture that wants
  /// a *live* entity writes both, and one that wants only the last-asserted
  /// values (what `readEntityIncludingHidden` reads) writes the fields alone.
  Future<void> recordReducedField(
    SyncDatabase sync,
    String collection,
    String entityId,
    String field,
    String valueJson, {
    bool withClock = false,
    int wallMs = 1800000000000,
  }) async {
    await sync.customStatement(
      'INSERT OR REPLACE INTO reduced_fields '
      '(collection, entity_id, field, value_json) VALUES (?, ?, ?, ?)',
      [collection, entityId, field, valueJson],
    );
    if (withClock) {
      await sync.customStatement(
        'INSERT OR REPLACE INTO field_clocks '
        '(collection, entity_id, field, wall_ms, counter, member_id_hex) '
        'VALUES (?, ?, ?, ?, 0, ?)',
        [collection, entityId, field, wallMs, 'aa' * 16],
      );
    }
  }

  /// A Tag entity whose fields are live — what the projector turns into a row.
  Future<void> recordLiveTagEntity(
    SyncDatabase sync,
    String id, {
    String name = 'Alice',
    String type = 'person',
  }) async {
    for (final entry in {
      'name': '"$name"',
      'type': '"$type"',
      'user_id': '"$_userId"',
    }.entries) {
      await recordReducedField(
          sync, tagsCollection, id, entry.key, entry.value,
          withClock: true);
    }
  }

  Future<Set<String>> tagIds() async =>
      (await db.select(db.tags).get()).map((row) => row.id).toSet();

  group('the schema can represent a duplicate pair', () {
    test('two same-(name, type) rows coexist under different ids', () async {
      // The inverse of the retired `tripwire:` assertion. Reduced state can hold
      // two Tag entities for one pair, so the projection of reduced state must be
      // able to hold two rows — otherwise the fold's own detection query can
      // never see the group it exists to collapse.
      await projectTagRow(_small);
      await projectTagRow(_large);
      expect(await tagIds(), {_small, _large});
    });

  });

  group('TagDao.foldDuplicateTags', () {
    test('is a no-op when there are no duplicates', () async {
      await db.tagDao.findOrCreateTag('Alice', 'person', _userId);
      await db.tagDao.findOrCreateTag('Bob', 'person', _userId);
      capture.clear();

      await db.tagDao.foldDuplicateTags();

      expect(await db.tagDao.watchPersonTags().first, hasLength(2));
      expect(capture.recorded, isEmpty, reason: 'nothing to decide, nothing to author');
    });

    test('folds onto MIN(id) whatever the reference counts say', () async {
      // The ranking `dedupeTags` used — `ref_count DESC, id ASC` — is device-local:
      // two devices folding concurrently would pick different survivors and
      // tombstone each other's, killing both Tags. Reference counts must not enter
      // the decision at all.
      await projectTagRow(_large);
      await projectTagRow(_small);
      for (final outcome in ['o1', 'o2', 'o3']) {
        await seedOutcome(outcome);
        await db.tagDao.assignTag(outcome, _large, _userId);
      }
      await seedOutcome('o4');
      await db.tagDao.assignTag('o4', _small, _userId);
      capture.clear();

      await db.tagDao.foldDuplicateTags();

      expect(await tagIds(), {_small});
      final junctions = await db.select(db.todoTags).get();
      expect(junctions.map((row) => row.tagId).toSet(), {_small});
      expect(junctions.map((row) => row.todoId).toSet(), {'o1', 'o2', 'o3', 'o4'});
    });

    test('collapses a (todo_id, tag_id) collision onto one row', () async {
      // The same Outcome carries both duplicates. The junction's primary key is
      // the pair, so the repointed row and the existing one are the same row.
      await projectTagRow(_small);
      await projectTagRow(_large);
      await seedOutcome('o1');
      await db.tagDao.assignTag('o1', _small, _userId);
      await db.tagDao.assignTag('o1', _large, _userId);

      await db.tagDao.foldDuplicateTags();

      final junctions = await db.select(db.todoTags).get();
      expect(junctions, hasLength(1));
      expect(junctions.single.tagId, _small);
      expect(junctions.single.id, todoTagIdFor('o1', _small),
          reason: 'the surviving junction carries its derived id');
    });

    test('repoints capture_tags as well as todo_tags', () async {
      // `merge` and `dedupeTags` both repointed only `todo_tags`, orphaning tag
      // hints (#645). With FK enforcement off an orphaned junction is an
      // invisible tag hint, not an error, so this is a silent loss.
      await projectTagRow(_small);
      await projectTagRow(_large);
      await db.captureDao.insertCapture(CapturesCompanion(
        id: const Value('c1'),
        title: const Value('ring Alice back'),
        userId: const Value(_userId),
        createdAt: Value(_ts),
      ));
      await db.captureDao.assignTagHint('c1', _large, _userId);

      await db.tagDao.foldDuplicateTags();

      final hints = await db.select(db.captureTags).get();
      expect(hints, hasLength(1));
      expect(hints.single.tagId, _small);
      expect(hints.single.id, captureTagIdFor('c1', _small));
    });

    test('collapses a (capture_id, tag_id) collision onto one row', () async {
      // The `capture_tags` half of the same PK-collision case: one Capture hints
      // both duplicates, and the pair is the primary key, so the repointed row and
      // the existing one are the same row.
      await projectTagRow(_small);
      await projectTagRow(_large);
      await db.captureDao.insertCapture(CapturesCompanion(
        id: const Value('c1'),
        title: const Value('ring Alice back'),
        userId: const Value(_userId),
        createdAt: Value(_ts),
      ));
      await db.captureDao.assignTagHint('c1', _small, _userId);
      await db.captureDao.assignTagHint('c1', _large, _userId);

      await db.tagDao.foldDuplicateTags();

      final hints = await db.select(db.captureTags).get();
      expect(hints, hasLength(1));
      expect(hints.single.tagId, _small);
      expect(hints.single.id, captureTagIdFor('c1', _small));
    });

    test('leaves unrelated tags untouched', () async {
      await projectTagRow(_small);
      await projectTagRow(_large);
      final bob = await db.tagDao.findOrCreateTag('Bob', 'person', _userId);
      final aliceContext =
          await db.tagDao.findOrCreateTag('Alice', 'context', _userId);

      await db.tagDao.foldDuplicateTags();

      expect(await tagIds(), {_small, bob, aliceContext});
    });

    test('is idempotent on a second run', () async {
      await projectTagRow(_small);
      await projectTagRow(_large);
      await seedOutcome('o1');
      await db.tagDao.assignTag('o1', _large, _userId);
      await db.tagDao.foldDuplicateTags();
      final rowsAfterFirst = await db.select(db.todoTags).get();
      capture.clear();

      await db.tagDao.foldDuplicateTags();

      expect(await db.select(db.todoTags).get(), rowsAfterFirst);
      expect(capture.recorded, isEmpty);
    });

    test('authors exactly the ops that carry the decision to peers', () async {
      // The propagating half of the contract. A fold that only fixed the local
      // store would be undone by the next pull, which still carries the peer's
      // duplicate — so the op set *is* the fix.
      await projectTagRow(_small);
      await projectTagRow(_large);
      await seedOutcome('o1');
      await db.tagDao.assignTag('o1', _large, _userId);
      await db.captureDao.insertCapture(CapturesCompanion(
        id: const Value('c1'),
        title: const Value('ring Alice back'),
        userId: const Value(_userId),
        createdAt: Value(_ts),
      ));
      await db.captureDao.assignTagHint('c1', _large, _userId);
      capture.clear();

      await db.tagDao.foldDuplicateTags();

      final tagOps = capture.forCollection(tagsCollection);
      expect(tagOps, hasLength(1));
      expect(tagOps.single.entityId, _large);
      expect(tagOps.single.tombstone, isTrue,
          reason: 'the loser is tombstoned, never merely absent');

      final junctionOps = capture.forCollection(todoTagsCollection);
      expect(
        {for (final op in junctionOps) op.entityId: op.tombstone},
        {
          todoTagIdFor('o1', _small): false,
          todoTagIdFor('o1', _large): true,
        },
        reason: 'assert on the survivor, tombstone on the loser — the log has no '
            'cascade, so the fold enumerates its own set',
      );
      expect(
        junctionOps
            .firstWhere((op) => op.entityId == todoTagIdFor('o1', _small))
            .fields,
        {'todo_id': 'o1', 'tag_id': _small, 'user_id': _userId},
      );

      expect(
        {
          for (final op in capture.forCollection(captureTagsCollection))
            op.entityId: op.tombstone,
        },
        {
          captureTagIdFor('c1', _small): false,
          captureTagIdFor('c1', _large): true,
        },
      );
    });
  });

  group('findOrCreateTag and findPersonTagByName with duplicates on disk', () {
    test('both return MIN(id) and mint nothing new', () async {
      await projectTagRow(_large);
      await projectTagRow(_small);
      capture.clear();

      expect(await db.tagDao.findOrCreateTag('Alice', 'person', _userId), _small);
      expect((await db.tagDao.findPersonTagByName('Alice'))!.id, _small);
      expect(await tagIds(), {_small, _large},
          reason: 'a lookup must not mint a third row');
      expect(capture.recorded, isEmpty);
    });
  });

  group('DomainProjector over a duplicate pair', () {
    test('projects two rows, identically in either entity order', () async {
      // Order independence for free: with no constraint to trip, `_upsert` is a
      // pure function of reduced state, and reduced state is a join-semilattice
      // (ADR-0030). Two same-`(name, type)` entities therefore project to the
      // same two rows whichever one the projector reaches first.
      final projected = <List<Map<String, Object?>>>[];
      for (final order in permutations([_small, _large])) {
        final sync = SyncDatabase(NativeDatabase.memory());
        addTearDown(sync.close);
        final domain = GtdDatabase(NativeDatabase.memory());
        addTearDown(domain.close);
        for (final id in [_small, _large]) {
          await recordLiveTagEntity(sync, id);
        }

        await DomainProjector(
          registry: CollectionRegistry(sync),
          domain: domain,
        ).project([
          for (final id in order) (collection: tagsCollection, entityId: id),
        ]);

        final rows = await domain
            .customSelect('SELECT * FROM tags ORDER BY id')
            .get();
        projected.add([for (final row in rows) row.data]);
      }
      expect(projected.first, hasLength(2),
          reason: 'the projector must be able to represent the duplicate');
      expect(projected.last, projected.first);
    });
  });

  group('the rehome pass', () {
    late SyncDatabase sync;
    late DomainReconciler reconciler;

    setUp(() {
      sync = SyncDatabase(NativeDatabase.memory());
      reconciler = DomainReconciler(
        registry: CollectionRegistry(sync),
        domain: db,
      );
    });
    tearDown(() async => sync.close());

    /// A Tag entity whose row is gone but whose last-asserted `(name, type)` is
    /// still on record — the state a tombstoned loser leaves behind, and the only
    /// place the pair is recoverable from.
    ///
    /// No `field_clocks` rows, so the fields are invisible to `readEntity` and
    /// reachable only through `readEntityIncludingHidden`.
    Future<void> recordDeadTag(String id,
        {String name = 'Alice', String type = 'person'}) async {
      await recordReducedField(sync, tagsCollection, id, 'name', '"$name"');
      await recordReducedField(sync, tagsCollection, id, 'type', '"$type"');
    }

    test('repoints a junction whose tag_id has no row in tags', () async {
      // The durable condition. This is the state a three-device X<Y<Z fold lands
      // in: the group is COUNT = 1, so no duplicate-based trigger can see it, but
      // the junction still points at a tag that is not there.
      await projectTagRow(_small);
      await seedOutcome('o1');
      await db.customInsert(
        'INSERT INTO "todo_tags" ("id", "todo_id", "tag_id", "user_id") '
        'VALUES (?, ?, ?, ?)',
        variables: [
          Variable<String>(todoTagIdFor('o1', _large)),
          const Variable<String>('o1'),
          const Variable<String>(_large),
          const Variable<String>(_userId),
        ],
      );
      await recordDeadTag(_large);
      capture.clear();

      await reconciler.reconcile({todoTagsCollection});

      final junctions = await db.select(db.todoTags).get();
      expect(junctions, hasLength(1));
      expect(junctions.single.tagId, _small);
      expect(
        {for (final op in capture.forCollection(todoTagsCollection)) op.entityId: op.tombstone},
        {
          todoTagIdFor('o1', _small): false,
          todoTagIdFor('o1', _large): true,
        },
        reason: 'the repair has to reach peers, so it travels as ops',
      );
    });

    test('repoints a dangling capture_tags row too', () async {
      await projectTagRow(_small);
      await db.captureDao.insertCapture(CapturesCompanion(
        id: const Value('c1'),
        title: const Value('ring Alice back'),
        userId: const Value(_userId),
        createdAt: Value(_ts),
      ));
      await db.customInsert(
        'INSERT INTO "capture_tags" ("id", "capture_id", "tag_id", "user_id") '
        'VALUES (?, ?, ?, ?)',
        variables: [
          Variable<String>(captureTagIdFor('c1', _large)),
          const Variable<String>('c1'),
          const Variable<String>(_large),
          const Variable<String>(_userId),
        ],
      );
      await recordDeadTag(_large);

      await reconciler.reconcile({captureTagsCollection});

      final hints = await db.select(db.captureTags).get();
      expect(hints, hasLength(1));
      expect(hints.single.tagId, _small);
    });

    test('leaves a junction alone when the pair is unrecoverable', () async {
      // Nothing in reduced state carries the dead entity's `(name, type)` — the
      // post-rebuild case. That is the ordinary dangling reference the projector
      // deliberately tolerates, not something to delete.
      await projectTagRow(_small);
      await seedOutcome('o1');
      await db.customInsert(
        'INSERT INTO "todo_tags" ("id", "todo_id", "tag_id", "user_id") '
        'VALUES (?, ?, ?, ?)',
        variables: [
          Variable<String>(todoTagIdFor('o1', _large)),
          const Variable<String>('o1'),
          const Variable<String>(_large),
          const Variable<String>(_userId),
        ],
      );
      capture.clear();

      await reconciler.reconcile({todoTagsCollection});

      final junctions = await db.select(db.todoTags).get();
      expect(junctions.single.tagId, _large, reason: 'left as a dangling reference');
      expect(capture.recorded, isEmpty);
    });

    test('leaves a junction alone when no live tag holds the pair', () async {
      await seedOutcome('o1');
      await db.customInsert(
        'INSERT INTO "todo_tags" ("id", "todo_id", "tag_id", "user_id") '
        'VALUES (?, ?, ?, ?)',
        variables: [
          Variable<String>(todoTagIdFor('o1', _large)),
          const Variable<String>('o1'),
          const Variable<String>(_large),
          const Variable<String>(_userId),
        ],
      );
      await recordDeadTag(_large);
      capture.clear();

      await reconciler.reconcile({todoTagsCollection});

      expect((await db.select(db.todoTags).get()).single.tagId, _large);
      expect(capture.recorded, isEmpty);
    });

    test('picks MIN(id) when several live tags hold the pair', () async {
      // Both passes agree on the survivor, so the rehome cannot undo the fold.
      await projectTagRow(_small);
      await projectTagRow(_third);
      await seedOutcome('o1');
      await db.customInsert(
        'INSERT INTO "todo_tags" ("id", "todo_id", "tag_id", "user_id") '
        'VALUES (?, ?, ?, ?)',
        variables: [
          Variable<String>(todoTagIdFor('o1', _large)),
          const Variable<String>('o1'),
          const Variable<String>(_large),
          const Variable<String>(_userId),
        ],
      );
      await recordDeadTag(_large);

      await reconciler.reconcile({tagsCollection});

      // The fold ran first and collapsed {_small, _third} onto _small; the rehome
      // then landed the orphan on that same survivor.
      expect(await tagIds(), {_small});
      expect((await db.select(db.todoTags).get()).single.tagId, _small);
    });

    test('reconcile is a no-op for collections that cannot affect tags', () async {
      await projectTagRow(_small);
      await projectTagRow(_large);
      capture.clear();

      await reconciler.reconcile({todosCollection, timeLogsCollection});

      expect(await tagIds(), {_small, _large},
          reason: 'a batch with no tag-shaped entity is not a reconcile trigger');
      expect(capture.recorded, isEmpty);
    });
  });

  group('DomainProjector.project reports what it touched', () {
    test("the reconcile trigger is the projector's own touched set", () async {
      // `project` returns the collections whose rows actually changed, which is
      // exactly what `SyncClient.pull` and `rebuildDomainFromOpLog` hand the
      // reconciler — so the trigger is derived from the projection rather than
      // guessed at from the batch.
      final sync = SyncDatabase(NativeDatabase.memory());
      addTearDown(sync.close);
      final projector =
          DomainProjector(registry: CollectionRegistry(sync), domain: db);

      expect(await projector.project(const <AffectedEntity>[]), isEmpty);

      await recordLiveTagEntity(sync, _small);
      expect(
        await projector
            .project([(collection: tagsCollection, entityId: _small)]),
        {tagsCollection},
      );

      // A collection whose entity is *held back* — a required column has not
      // arrived yet — writes no row, so it names nothing and triggers nothing.
      await recordReducedField(
          sync, tagsCollection, _large, 'name', '"Alice"',
          withClock: true);
      expect(
        await projector
            .project([(collection: tagsCollection, entityId: _large)]),
        isEmpty,
        reason: 'an incomplete entity lands on a later pass, and until then '
            'there is nothing for a convergence pass to look at',
      );
    });
  });
}
