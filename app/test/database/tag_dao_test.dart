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

    test(
        'upsertTag with a fresh id claiming an occupied (name, type) replaces '
        'the incumbent instead of duplicating it', () async {
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('ctx-incumbent'),
        name: const Value('phone'),
        type: const Value('context'),
        userId: const Value(_userId),
      ));

      // `upsertTag` finds no row under the new id and falls through to
      // INSERT OR REPLACE, which resolves the table's `UNIQUE (name, type)`
      // conflict by *deleting* the incumbent — id and all. That is precisely
      // why nothing in the app creates a tag by calling this directly:
      // `findOrCreateTag` reuses the existing row, and `rename` folds into
      // `merge` rather than writing a colliding one.
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('ctx-usurper'),
        name: const Value('phone'),
        type: const Value('context'),
        userId: const Value(_userId),
      ));

      final tags = await db.tagDao.watchByType('context').first;
      expect(tags, hasLength(1));
      expect(tags.single.id, 'ctx-usurper');
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

    test(
        'tripwire: a plain insert of a duplicate (name, type) throws under the '
        'unique key', () async {
      // The `UNIQUE (name, type)` tripwire on the real table (`tables.dart`),
      // asserted through the statement shape production actually issues raw:
      // `DomainProjector._upsert` locates a tag by `id` and, finding none,
      // INSERTs. So this is not only a guard on the DAO — it is the reason a
      // duplicate `(name, type)` cannot reach disk at all (see the
      // `TagDao.dedupeTags` group below).
      await db.into(db.tags).insert(TagsCompanion(
            id: const Value('dup1'),
            name: const Value('Alice'),
            type: const Value('person'),
            userId: const Value(_userId),
          ));

      expect(
        () => db.into(db.tags).insert(TagsCompanion(
              id: const Value('dup2'),
              name: const Value('Alice'),
              type: const Value('person'),
              userId: const Value(_userId),
            )),
        throwsA(isA<SqliteException>()),
      );
    });
  });

  // **`dedupeTags`' collapse path is unreachable on the real schema, so only
  // its no-op contract is asserted here.**
  //
  // `tags` carries `UNIQUE (name, type)` (`tables.dart`), and nothing can put a
  // second row with a duplicate pair behind it: DAO writes go through
  // `INSERT OR REPLACE`, which resolves the conflict by replacing rather than
  // duplicating, and production's one raw `INSERT INTO tags` —
  // `DomainProjector._upsert`, which locates a tag by `id` — raises
  // `SqliteException(2067)` instead (the `tripwire:` test above pins that
  // statement shape). The pre-#595 store was where duplicates could exist:
  // `tags` was a constraint-free view over a PowerSync backing table, so a
  // peer's independently minted "Home" landed as a second row. That topology is
  // gone (ADR-0035) and the old local store is deleted rather than converted,
  // so it cannot arrive on disk either. The test that used to cover the collapse
  // rebuilt that view topology purely so its own fixture could get past the
  // unique key.
  //
  // The behaviours it asserted are covered on the real schema elsewhere, by the
  // reachable route to the same collapse — `TagDao.merge` and the `rename` that
  // folds into it, in `tag_filter_dao_test.dart`: junction rows repointed onto
  // the surviving tag id, the resulting `(todo_id, tag_id)` PK collision
  // collapsing to one row, the losing tag deleted, unrelated tags untouched.
  // Its deterministic junction id is pinned by `assignTag is idempotent` above.
  // What is left uncovered is `dedupeTags`' own group ranking (most references
  // wins, `MIN(id)` as tiebreaker), because no input can reach it.
  //
  // The projector raising instead of converging is a live defect rather than a
  // property of the design — see #605, which also decides whether the fix makes
  // this path reachable again or retires the dedupe machinery.
  group('TagDao.dedupeTags', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('dedupeTags is a no-op when no duplicates exist', () async {
      await db.tagDao.findOrCreateTag('Alice', 'person', _userId);
      await db.tagDao.findOrCreateTag('Bob', 'person', _userId);

      await db.tagDao.dedupeTags();

      final rows = await db.tagDao.watchPersonTags().first;
      expect(rows, hasLength(2));
    });
  });
}
