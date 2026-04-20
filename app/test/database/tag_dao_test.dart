import 'package:drift/drift.dart';
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

      final tags = await db.tagDao.watchByType(_userId, 'context').first;
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

      final tags = await db.tagDao.watchByType(_userId, 'context').first;
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

      final tags = await db.tagDao.watchByType(_userId, 'context').first;
      expect(tags.length, 1);
      expect(tags.first.name, 'errand-v2');
      expect(tags.first.color, '#ff0000');
    });

    test('assignTag creates a junction row', () async {
      final now = DateTime.now();
      await db.inboxDao.insertTodo(TodosCompanion(
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
      await db.inboxDao.insertTodo(TodosCompanion(
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
      await db.inboxDao.insertTodo(TodosCompanion(
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

      final tags = await db.tagDao.watchByType(_userId, 'label').first;
      expect(tags.map((t) => t.name).toList(), ['alpha', 'middle', 'zebra']);
    });
  });
}
