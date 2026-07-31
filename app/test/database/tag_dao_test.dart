import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/tag_dao.dart' show todoTagIdFor;
import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

const _userId = 'test-user';

void main() {
  setUpAll(configureSqliteForTests);

  group('TagDao', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('upsertTag creates a new tag', () async {
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('t1'),
        name: const Value('work'),
        type: const Value('context'),
        userId: const Value(_userId),
      ));

      final tags = await db.tagDao.watchByType('context').first;
      expect(tags.length, 1);
      expect(tags.first.name, 'work');
    });

    test('upsertTag updates an existing tag (conflict update)', () async {
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('t2'),
        name: const Value('home'),
        type: const Value('context'),
        userId: const Value(_userId),
      ));
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('t2'),
        name: const Value('home-v2'),
        type: const Value('context'),
        userId: const Value(_userId),
      ));

      final tags = await db.tagDao.watchByType('context').first;
      expect(tags.length, 1);
      expect(tags.first.name, 'home-v2');
    });

    test('upsertTag preserves absent fields (e.g. color) on update', () async {
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('t3'),
        name: const Value('errand'),
        color: const Value('#ff0000'),
        type: const Value('context'),
        userId: const Value(_userId),
      ));

      // Update name only — color must survive.
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('t3'),
        name: const Value('errand-v2'),
        type: const Value('context'),
        userId: const Value(_userId),
      ));

      final tags = await db.tagDao.watchByType('context').first;
      expect(tags.length, 1);
      expect(tags.first.name, 'errand-v2');
      expect(tags.first.color, '#ff0000');
    });

    test('assignTag creates a junction row', () async {
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
        id: const Value('todo1'),
        title: const Value('Test task'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('ctx1'),
        name: const Value('phone'),
        type: const Value('context'),
        userId: const Value(_userId),
      ));

      await db.tagDao.assignTag('todo1', 'ctx1', _userId);

      final rows = await (db.select(db.todoTags)
            ..where((jt) => jt.todoId.equals('todo1')))
          .get();
      expect(rows.length, 1);
      expect(rows.first.tagId, 'ctx1');
      expect(rows.first.userId, _userId);
    });

    test('assignTag is idempotent — re-assigning keeps a single row', () async {
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
        id: const Value('todo-idem'),
        title: const Value('Idempotency task'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('ctx-idem'),
        name: const Value('idem'),
        type: const Value('context'),
        userId: const Value(_userId),
      ));

      // Assign the same tag three times; the deterministic id should make
      // INSERT OR REPLACE collapse every call onto the same junction row.
      await db.tagDao.assignTag('todo-idem', 'ctx-idem', _userId);
      await db.tagDao.assignTag('todo-idem', 'ctx-idem', _userId);
      await db.tagDao.assignTag('todo-idem', 'ctx-idem', _userId);

      final rows = await (db.select(db.todoTags)
            ..where((jt) => jt.todoId.equals('todo-idem')))
          .get();
      expect(rows.length, 1);
      expect(rows.first.id, todoTagIdFor('todo-idem', 'ctx-idem'));
    });

    test('upsertTag no longer deletes a tag that occupies the same (name, type)',
        () async {
      // The INSERT OR REPLACE footgun the dropped constraint carried: under
      // `UNIQUE (name, type)` a colliding write resolved by **deleting** the other
      // tag row — id, references and all — silently, since FK enforcement is off
      // (#637). With no constraint to conflict on there is nothing to replace, so
      // both rows survive and the duplicate becomes the ordinary transient state
      // `DomainReconciler`'s fold collapses (#605).
      //
      // Both branches of `upsertTag`, since each reached the conflict differently:
      // a *fresh* id falls through to the raw insert, and an *existing* id takes
      // the fill-from-stored-row path and re-inserts.
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('ctx-incumbent'),
        name: const Value('phone'),
        type: const Value('context'),
        userId: const Value(_userId),
      ));
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('ctx-usurper'),
        name: const Value('phone'),
        type: const Value('context'),
        userId: const Value(_userId),
      ));

      /// Every context tag as `id -> name`.
      ///
      /// The pair, not the id alone: "nobody was evicted" is only half the
      /// claim — the write also has to have *landed*, and a no-op write would
      /// satisfy a set-of-ids assertion perfectly.
      Future<Map<String, String>> contextTagNames() async => {
            for (final tag in await db.tagDao.watchByType('context').first)
              tag.id: tag.name,
          };

      expect(
        await contextTagNames(),
        {'ctx-incumbent': 'phone', 'ctx-usurper': 'phone'},
        reason: 'a fresh-id write must not evict the incumbent, and both rows '
            'hold the duplicate pair',
      );

      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('ctx-other'),
        name: const Value('errand'),
        type: const Value('context'),
        userId: const Value(_userId),
      ));
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('ctx-other'),
        name: const Value('phone'),
      ));

      expect(
        await contextTagNames(),
        {
          'ctx-incumbent': 'phone',
          'ctx-usurper': 'phone',
          'ctx-other': 'phone',
        },
        reason: 'renaming onto an occupied pair evicts nobody AND renames: '
            'three rows now hold (phone, context)',
      );
      // The partial companion carried no `type` or `user_id`, so the
      // fill-from-stored-row branch had to supply them. A rename that dropped
      // them would leave the row out of `watchByType('context')` entirely, so
      // read them back rather than inferring it.
      final renamed = await (db.select(db.tags)
            ..where((tag) => tag.id.equals('ctx-other')))
          .getSingle();
      expect(renamed.name, 'phone');
      expect(renamed.type, 'context');
      expect(renamed.userId, _userId);
    });

    test('enforceSingleProject removes old project and assigns new one',
        () async {
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
        id: const Value('todo2'),
        title: const Value('Multi-project task'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));

      // Create two project tags.
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('p1'),
        name: const Value('Project Alpha'),
        type: const Value('project'),
        userId: const Value(_userId),
      ));
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('p2'),
        name: const Value('Project Beta'),
        type: const Value('project'),
        userId: const Value(_userId),
      ));

      // Assign first project.
      await db.tagDao.enforceSingleProject('todo2', _userId, 'p1');
      // Reassign to second project.
      await db.tagDao.enforceSingleProject('todo2', _userId, 'p2');

      // Only the second project should remain.
      final rows = await (db.select(db.todoTags)
            ..where((jt) => jt.todoId.equals('todo2')))
          .get();
      expect(rows.length, 1);
      expect(rows.first.tagId, 'p2');
      expect(rows.first.userId, _userId);
    });

    test('watchByType returns tags in alphabetical order', () async {
      for (final name in ['zebra', 'alpha', 'middle']) {
        await db.tagDao.upsertTag(TagsCompanion(
          id: Value(name),
          name: Value(name),
          type: const Value('label'),
          userId: const Value(_userId),
        ));
      }

      final tags = await db.tagDao.watchByType('label').first;
      expect(tags.map((t) => t.name).toList(), ['alpha', 'middle', 'zebra']);
    });

    test('createPersonTag is idempotent — returns same id, one row', () async {
      final id1 = await db.tagDao.createPersonTag('Alice', _userId);
      final id2 = await db.tagDao.createPersonTag('Alice', _userId);

      expect(id1, id2);
      final rows = await db.tagDao.watchPersonTags().first;
      expect(rows, hasLength(1));
      expect(rows.first.name, 'Alice');
    });

    test('findOrCreateTag is idempotent per (name, type)', () async {
      final ctxId1 = await db.tagDao.findOrCreateTag('foo', 'context', _userId);
      final ctxId2 = await db.tagDao.findOrCreateTag('foo', 'context', _userId);
      final projId1 =
          await db.tagDao.findOrCreateTag('bar', 'project', _userId);
      final projId2 =
          await db.tagDao.findOrCreateTag('bar', 'project', _userId);
      final personId1 =
          await db.tagDao.findOrCreateTag('baz', 'person', _userId);
      final personId2 =
          await db.tagDao.findOrCreateTag('baz', 'person', _userId);

      expect(ctxId1, ctxId2);
      expect(projId1, projId2);
      expect(personId1, personId2);

      expect((await db.tagDao.watchByType('context').first), hasLength(1));
      expect((await db.tagDao.watchByType('project').first), hasLength(1));
      expect((await db.tagDao.watchByType('person').first), hasLength(1));
    });

    test('findOrCreateTag returns distinct ids for same name, different types',
        () async {
      final ctxId = await db.tagDao.findOrCreateTag('foo', 'context', _userId);
      final projId =
          await db.tagDao.findOrCreateTag('foo', 'project', _userId);

      expect(ctxId, isNot(projId));
    });

    test('a plain insert of a duplicate (name, type) is accepted', () async {
      // The inverse of the retired `UNIQUE (name, type)` tripwire (ADR-0043), and
      // asserted through the statement shape production issues raw:
      // `DomainProjector._upsert` locates a tag by `id` and, finding none,
      // INSERTs. Reduced state can hold two Tag entities for one pair, so its
      // projection has to be able to hold two rows — otherwise the projector
      // raises `SqliteException(2067)` and rolls back the whole pull batch (#605).
      //
      // *Absence* of the constraint is pinned by `PRAGMA index_list` in
      // `schema_baseline_test.dart`, since an insert succeeding cannot distinguish
      // "the constraint is gone" from "the migration never ran".
      await db.into(db.tags).insert(TagsCompanion(
            id: const Value('dup1'),
            name: const Value('Alice'),
            type: const Value('person'),
            userId: const Value(_userId),
          ));
      await db.into(db.tags).insert(TagsCompanion(
            id: const Value('dup2'),
            name: const Value('Alice'),
            type: const Value('person'),
            userId: const Value(_userId),
          ));

      expect(
        (await db.select(db.tags).get()).map((row) => row.id).toSet(),
        {'dup1', 'dup2'},
      );
    });
  });

  // **`foldDuplicateTags` is covered in full by `sync/domain_reconciler_test.dart`**,
  // where it belongs: the fold is one of the two convergence passes the
  // `DomainReconciler` drives, its ranking rule (`MIN(id)` alone, never reference
  // counts) is a convergence property rather than a DAO detail, and the op set it
  // authors — the half that carries the decision to peers — is only assertable
  // against a recording capture seam. The cross-device statement it exists to make
  // is `sync/tag_convergence_test.dart`.
  //
  // What stays here is the DAO-local half: that the schema accepts a duplicate pair
  // at all (above), and that the `(name, type)` lookups stay deterministic while
  // one is on disk.
  group('TagDao lookups with duplicates on disk', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('the fold is a no-op when no duplicates exist', () async {
      await db.tagDao.findOrCreateTag('Alice', 'person', _userId);
      await db.tagDao.findOrCreateTag('Bob', 'person', _userId);

      await db.tagDao.foldDuplicateTags();

      final rows = await db.tagDao.watchPersonTags().first;
      expect(rows, hasLength(2));
    });

    test('findOrCreateTag and findPersonTagByName both return MIN(id)', () async {
      // Deterministic across devices, and the same rule the fold ranks by, so a
      // lookup made before the fold has run agrees with the survivor it picks.
      for (final id in ['dup-b', 'dup-a']) {
        await db.into(db.tags).insert(TagsCompanion(
              id: Value(id),
              name: const Value('Alice'),
              type: const Value('person'),
              userId: const Value(_userId),
            ));
      }

      expect(await db.tagDao.findOrCreateTag('Alice', 'person', _userId), 'dup-a');
      expect((await db.tagDao.findPersonTagByName('Alice'))!.id, 'dup-a');
      expect((await db.select(db.tags).get()), hasLength(2),
          reason: 'a lookup must not mint a third row');
    });
  });
}
