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
        'upsertTag and assignTag work on PowerSync view-backed schema — '
        'regression guard: no ON CONFLICT DO UPDATE on views', () async {
      // Replace real tables with views + INSTEAD OF INSERT triggers to
      // simulate the PowerSync schema.  SQLite rejects the UPSERT syntax
      // "ON CONFLICT DO UPDATE" on views at parse time; any regression to
      // insertOnConflictUpdate() will throw a SqliteException here.
      await db.customStatement('''
        CREATE TABLE ps_data__tags (
          id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT,
          type TEXT NOT NULL DEFAULT 'context', user_id TEXT NOT NULL
        )
      ''');
      await db.customStatement('DROP TABLE IF EXISTS tags');
      await db.customStatement(
        'CREATE VIEW tags AS SELECT * FROM ps_data__tags',
      );
      await db.customStatement('''
        CREATE TRIGGER tags_insert INSTEAD OF INSERT ON tags BEGIN
          INSERT OR REPLACE INTO ps_data__tags (id, name, color, type, user_id)
          VALUES (NEW.id, NEW.name, NEW.color, NEW.type, NEW.user_id);
        END
      ''');

      await db.customStatement('''
        CREATE TABLE ps_data__todo_tags (
          id TEXT PRIMARY KEY, todo_id TEXT NOT NULL,
          tag_id TEXT NOT NULL, user_id TEXT NOT NULL
        )
      ''');
      await db.customStatement('DROP TABLE IF EXISTS todo_tags');
      await db.customStatement(
        'CREATE VIEW todo_tags AS SELECT * FROM ps_data__todo_tags',
      );
      await db.customStatement('''
        CREATE TRIGGER todo_tags_insert INSTEAD OF INSERT ON todo_tags BEGIN
          INSERT OR REPLACE INTO ps_data__todo_tags (id, todo_id, tag_id, user_id)
          VALUES (NEW.id, NEW.todo_id, NEW.tag_id, NEW.user_id);
        END
      ''');

      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('ctx-view'),
        name: const Value('phone'),
        type: const Value('context'),
        userId: const Value(_userId),
      ));

      // Two calls — idempotency requires exactly one row.
      await db.tagDao.assignTag('todo-view', 'ctx-view', _userId);
      await db.tagDao.assignTag('todo-view', 'ctx-view', _userId);

      final rows = await (db.select(db.todoTags)
            ..where((jt) => jt.todoId.equals('todo-view')))
          .get();
      expect(rows.length, 1);
      expect(rows.first.id, todoTagIdFor('todo-view', 'ctx-view'));
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

    test('findPersonTagByName returns null when no row matches', () async {
      final result = await db.tagDao.findPersonTagByName('Ghost');
      expect(result, isNull);
    });

    test(
        'findPersonTagByName tolerates legacy (name, person) duplicates '
        "and returns a deterministic row instead of crashing", () async {
      // Replace `tags` with a view-backed schema so duplicate rows can be
      // inserted directly into the backing table — the unique tripwire on the
      // real Drift table would otherwise reject the second insert.
      await db.customStatement('''
        CREATE TABLE ps_data__tags (
          id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT,
          type TEXT NOT NULL DEFAULT 'context', user_id TEXT NOT NULL
        )
      ''');
      await db.customStatement('DROP TABLE IF EXISTS tags');
      await db.customStatement(
        'CREATE VIEW tags AS SELECT * FROM ps_data__tags',
      );

      await db.customStatement(
        "INSERT INTO ps_data__tags (id, name, type, user_id) "
        "VALUES ('alice-b', 'Alice', 'person', ?)",
        [_userId],
      );
      await db.customStatement(
        "INSERT INTO ps_data__tags (id, name, type, user_id) "
        "VALUES ('alice-a', 'Alice', 'person', ?)",
        [_userId],
      );

      final tag = await db.tagDao.findPersonTagByName('Alice');
      expect(tag, isNotNull);
      // MIN(id) deterministically wins so the read path agrees with
      // findOrCreateTag and dedupeTags on which row to keep.
      expect(tag!.id, 'alice-a');
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
        'tripwire: raw insert of duplicate (name, type) throws under unique constraint',
        () async {
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

  group('TagDao.dedupeTags', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test(
        'collapses duplicate (name, type) rows, repoints todo_tags, '
        'survives PK collision on (todo_id, canonical_tag_id)', () async {
      // Use the view-backed schema so the unique-key tripwire on the real
      // table doesn't block the test setup — production duplicates land in
      // ps_data__tags via PowerSync, not via direct table inserts.
      await db.customStatement('''
        CREATE TABLE ps_data__tags (
          id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT,
          type TEXT NOT NULL DEFAULT 'context', user_id TEXT NOT NULL
        )
      ''');
      await db.customStatement('DROP TABLE IF EXISTS tags');
      await db.customStatement(
        'CREATE VIEW tags AS SELECT * FROM ps_data__tags',
      );
      await db.customStatement('''
        CREATE TRIGGER tags_insert INSTEAD OF INSERT ON tags BEGIN
          INSERT OR REPLACE INTO ps_data__tags (id, name, color, type, user_id)
          VALUES (NEW.id, NEW.name, NEW.color, NEW.type, NEW.user_id);
        END
      ''');
      await db.customStatement('''
        CREATE TRIGGER tags_delete INSTEAD OF DELETE ON tags BEGIN
          DELETE FROM ps_data__tags WHERE id = OLD.id;
        END
      ''');

      await db.customStatement('''
        CREATE TABLE ps_data__todo_tags (
          id TEXT PRIMARY KEY, todo_id TEXT NOT NULL,
          tag_id TEXT NOT NULL, user_id TEXT NOT NULL
        )
      ''');
      await db.customStatement('DROP TABLE IF EXISTS todo_tags');
      await db.customStatement(
        'CREATE VIEW todo_tags AS SELECT * FROM ps_data__todo_tags',
      );
      await db.customStatement('''
        CREATE TRIGGER todo_tags_insert INSTEAD OF INSERT ON todo_tags BEGIN
          INSERT OR REPLACE INTO ps_data__todo_tags (id, todo_id, tag_id, user_id)
          VALUES (NEW.id, NEW.todo_id, NEW.tag_id, NEW.user_id);
        END
      ''');
      await db.customStatement('''
        CREATE TRIGGER todo_tags_delete INSTEAD OF DELETE ON todo_tags BEGIN
          DELETE FROM ps_data__todo_tags WHERE id = OLD.id;
        END
      ''');

      // Two duplicate "Alice" person rows + one unrelated "Bob" row.
      Future<void> rawInsertTag(String id, String name, String type) async {
        await db.into(db.tags).insert(TagsCompanion(
              id: Value(id),
              name: Value(name),
              type: Value(type),
              userId: const Value(_userId),
            ));
      }

      await rawInsertTag('alice-a', 'Alice', 'person');
      await rawInsertTag('alice-b', 'Alice', 'person');
      await rawInsertTag('bob', 'Bob', 'person');

      // Insert two junction rows pointing at the two Alice ids for the SAME
      // todo, so the rewrite forces a collision on the canonical junction id.
      // Use the same deterministic id scheme production uses (todoTagIdFor)
      // so the replay collapses via INSERT OR REPLACE on the backing table's
      // id PK — mirroring how junction rows are minted by assignTag.
      await db.into(db.todoTags).insert(TodoTagsCompanion(
            id: Value(todoTagIdFor('todo-1', 'alice-a')),
            todoId: const Value('todo-1'),
            tagId: const Value('alice-a'),
            userId: const Value(_userId),
          ));
      await db.into(db.todoTags).insert(TodoTagsCompanion(
            id: Value(todoTagIdFor('todo-1', 'alice-b')),
            todoId: const Value('todo-1'),
            tagId: const Value('alice-b'),
            userId: const Value(_userId),
          ));

      await db.tagDao.dedupeTags();

      // Exactly one Alice row remains; Bob untouched.
      final aliceRows = await (db.select(db.tags)
            ..where((t) => t.name.equals('Alice')))
          .get();
      expect(aliceRows, hasLength(1));
      final canonicalAlice = aliceRows.single.id;

      final bobRows = await (db.select(db.tags)
            ..where((t) => t.name.equals('Bob')))
          .get();
      expect(bobRows, hasLength(1));

      // One junction row survives, repointed to the canonical Alice id, with
      // the deterministic id derived from (todo_id, canonical_tag_id).
      final allLinks = await (db.select(db.todoTags)
            ..where((tt) => tt.todoId.equals('todo-1')))
          .get();
      expect(allLinks, hasLength(1));
      expect(allLinks.single.tagId, canonicalAlice);
      expect(allLinks.single.id, todoTagIdFor('todo-1', canonicalAlice));
    });

    test('dedupeTags is a no-op when no duplicates exist', () async {
      await db.tagDao.findOrCreateTag('Alice', 'person', _userId);
      await db.tagDao.findOrCreateTag('Bob', 'person', _userId);

      await db.tagDao.dedupeTags();

      final rows = await db.tagDao.watchPersonTags().first;
      expect(rows, hasLength(2));
    });
  });
}
