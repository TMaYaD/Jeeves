import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

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

      await db.tagDao.assignTag('todo1', 'ctx1');

      final rows = await (db.select(db.todoTags)
            ..where((jt) => jt.todoId.equals('todo1')))
          .get();
      expect(rows.length, 1);
      expect(rows.first.tagId, 'ctx1');
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
