import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

const _userId = 'test-user';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<String> _insertTodo(
  GtdDatabase db, {
  required String id,
  required String title,
  required String state,
  bool clarified = true,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
    id: Value(id),
    title: Value(title),
    state: Value(state),
    clarified: Value(clarified),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
  return id;
}

Future<String> _insertTag(
  GtdDatabase db, {
  required String id,
  required String name,
  String type = 'context',
}) async {
  await db.tagDao.upsertTag(TagsCompanion(
    id: Value(id),
    name: Value(name),
    type: Value(type),
    userId: const Value(_userId),
  ));
  return id;
}

Future<void> _assignTag(GtdDatabase db, String todoId, String tagId) =>
    db.tagDao.assignTag(todoId, tagId, _userId);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(configureSqliteForTests);

  group('TagDao.watchTagsWithActiveCount', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('returns zero count for tag with no todos', () async {
      await _insertTag(db, id: 'ctx1', name: 'work');
      final results =
          await db.tagDao.watchTagsWithActiveCount(_userId, 'context').first;
      expect(results, hasLength(1));
      expect(results.first.tag.name, 'work');
      expect(results.first.count, 0);
    });

    test('counts only clarified non-done todos', () async {
      await _insertTag(db, id: 'ctx1', name: 'work');
      final t1 = await _insertTodo(db,
          id: 't1', title: 'Task A', state: 'next_action');
      final t2 = await _insertTodo(db,
          id: 't2', title: 'Task B', state: 'next_action');
      await db.todoDao.markDone(t2, _userId);
      final t3 = await _insertTodo(db,
          id: 't3', title: 'Task C', state: 'next_action', clarified: false);
      await _assignTag(db, t1, 'ctx1');
      await _assignTag(db, t2, 'ctx1');
      await _assignTag(db, t3, 'ctx1');

      final results =
          await db.tagDao.watchTagsWithActiveCount(_userId, 'context').first;
      expect(results.first.count, 1); // only t1 (clarified, not done) is counted
    });

    test('count updates reactively when a todo is completed', () async {
      await _insertTag(db, id: 'ctx1', name: 'work');
      final t1 = await _insertTodo(db,
          id: 't1', title: 'Active task', state: 'next_action');
      await _assignTag(db, t1, 'ctx1');

      // Single subscription — two separate `.first` calls would create
      // fresh streams and hide any reactivity bug.
      final counts = db.tagDao
          .watchTagsWithActiveCount(_userId, 'context')
          .map((rows) => rows.first.count);
      final expectation = expectLater(counts, emitsInOrder([1, 0]));

      // Mark done — should push a new emission on the same stream.
      await db.todoDao.markDone(t1, _userId);

      await expectation;
    });

    test('returns tags sorted alphabetically', () async {
      for (final name in ['zebra', 'alpha', 'middle']) {
        await _insertTag(db, id: name, name: name);
      }
      final results =
          await db.tagDao.watchTagsWithActiveCount(_userId, 'context').first;
      expect(results.map((r) => r.tag.name).toList(),
          ['alpha', 'middle', 'zebra']);
    });
  });

  group('TagDao.rename', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('renames a tag preserving colour', () async {
      await _insertTag(db, id: 'ctx1', name: 'work');
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('ctx1'),
        color: Value('#ff0000'),
      ));
      await db.tagDao.rename('ctx1', 'office');
      final tags =
          await db.tagDao.watchByType(_userId, 'context').first;
      expect(tags.first.name, 'office');
      expect(tags.first.color, '#ff0000');
    });
  });

  group('TagDao.updateColor', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('sets a colour on a tag', () async {
      await _insertTag(db, id: 'ctx1', name: 'work');
      await db.tagDao.updateColor('ctx1', '#3b82f6');
      final tags =
          await db.tagDao.watchByType(_userId, 'context').first;
      expect(tags.first.color, '#3b82f6');
    });

    test('clears a colour when null is passed', () async {
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('ctx1'),
        name: Value('work'),
        type: Value('context'),
        userId: Value(_userId),
        color: Value('#ff0000'),
      ));
      await db.tagDao.updateColor('ctx1', null);
      final tags =
          await db.tagDao.watchByType(_userId, 'context').first;
      expect(tags.first.color, equals(null));
    });
  });

  group('TagDao.merge', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('reassigns todo_tags from source to target', () async {
      await _insertTag(db, id: 'src', name: 'old');
      await _insertTag(db, id: 'tgt', name: 'new');
      final t1 = await _insertTodo(db,
          id: 't1', title: 'Task', state: 'next_action');
      await _assignTag(db, t1, 'src');

      await db.tagDao.merge('src', 'tgt');

      final rows = await (db.select(db.todoTags)
            ..where((tt) => tt.todoId.equals(t1)))
          .get();
      expect(rows, hasLength(1));
      expect(rows.first.tagId, 'tgt');
    });

    test('deletes source tag after merge', () async {
      await _insertTag(db, id: 'src', name: 'old');
      await _insertTag(db, id: 'tgt', name: 'new');
      await db.tagDao.merge('src', 'tgt');

      final remaining =
          await db.tagDao.watchByType(_userId, 'context').first;
      final remainingIds = remaining.map((t) => t.id).toList();
      expect(remainingIds, isNot(contains('src')));
    });

    test('throws on self-merge without deleting data', () async {
      await _insertTag(db, id: 'src', name: 'old');
      final t1 = await _insertTodo(db,
          id: 't1', title: 'Task', state: 'next_action');
      await _assignTag(db, t1, 'src');

      expect(() => db.tagDao.merge('src', 'src'), throwsArgumentError);

      final tags = await db.tagDao.watchByType(_userId, 'context').first;
      expect(tags.map((t) => t.id), contains('src'));
      final rows = await (db.select(db.todoTags)
            ..where((tt) => tt.todoId.equals(t1)))
          .get();
      expect(rows, hasLength(1));
      expect(rows.single.tagId, 'src');
    });

    test('merge is idempotent when todo already has target tag', () async {
      await _insertTag(db, id: 'src', name: 'old');
      await _insertTag(db, id: 'tgt', name: 'new');
      final t1 = await _insertTodo(db,
          id: 't1', title: 'Task', state: 'next_action');
      // Assign both tags to the same todo
      await _assignTag(db, t1, 'src');
      await _assignTag(db, t1, 'tgt');

      await db.tagDao.merge('src', 'tgt');

      final rows = await (db.select(db.todoTags)
            ..where((tt) => tt.todoId.equals(t1)))
          .get();
      expect(rows, hasLength(1));
      expect(rows.first.tagId, 'tgt');
    });
  });

  group('TodoDao tag filtering', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('watchNextActions with no tagIds returns all next actions', () async {
      await _insertTodo(db, id: 't1', title: 'A', state: 'next_action');
      await _insertTodo(db, id: 't2', title: 'B', state: 'next_action');
      final results =
          await db.todoDao.watchNextActions(_userId).first;
      expect(results, hasLength(2));
    });

    test('watchNextActions with tagIds returns only matching todos', () async {
      await _insertTag(db, id: 'ctx1', name: 'work');
      await _insertTag(db, id: 'ctx2', name: 'home');
      final t1 = await _insertTodo(db,
          id: 't1', title: 'Work task', state: 'next_action');
      final t2 = await _insertTodo(db,
          id: 't2', title: 'Home task', state: 'next_action');
      await _assignTag(db, t1, 'ctx1');
      await _assignTag(db, t2, 'ctx2');

      final results = await db.todoDao
          .watchNextActions(_userId, tagIds: {'ctx1'}).first;
      expect(results, hasLength(1));
      expect(results.first.id, t1);
    });

    test('watchNextActions with two tagIds uses AND semantics', () async {
      await _insertTag(db, id: 'ctx1', name: 'work');
      await _insertTag(db, id: 'ctx2', name: 'phone');
      // t1 has both tags; t2 has only one
      final t1 = await _insertTodo(db,
          id: 't1', title: 'Both', state: 'next_action');
      final t2 = await _insertTodo(db,
          id: 't2', title: 'One', state: 'next_action');
      await _assignTag(db, t1, 'ctx1');
      await _assignTag(db, t1, 'ctx2');
      await _assignTag(db, t2, 'ctx1');

      final results = await db.todoDao
          .watchNextActions(_userId, tagIds: {'ctx1', 'ctx2'}).first;
      expect(results, hasLength(1));
      expect(results.first.id, t1);
    });

    test('watchWaitingFor with tagIds filters correctly', () async {
      await _insertTag(db, id: 'ctx1', name: 'errand');
      final t1 = await _insertTodo(db,
          id: 't1', title: 'Waiting tagged', state: 'waiting_for');
      await _insertTodo(db,
          id: 't2', title: 'Waiting untagged', state: 'waiting_for');
      await _assignTag(db, t1, 'ctx1');

      final results = await db.todoDao
          .watchWaitingFor(_userId, tagIds: {'ctx1'}).first;
      expect(results, hasLength(1));
      expect(results.first.id, t1);
    });

    test('watchByState with tagIds filters correctly', () async {
      await _insertTag(db, id: 'ctx1', name: 'errand');
      final t1 = await _insertTodo(db,
          id: 't1', title: 'Blocked tagged', state: 'next_action');
      await _insertTodo(db,
          id: 't2', title: 'Blocked untagged', state: 'next_action');
      await _assignTag(db, t1, 'ctx1');

      final results = await db.todoDao
          .watchByState(_userId, 'next_action', tagIds: {'ctx1'}).first;
      expect(results, hasLength(1));
      expect(results.first.id, t1);
    });
  });

  group('InboxDao tag filtering', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('watchInbox with tagIds returns only matching inbox items', () async {
      await _insertTag(db, id: 'ctx1', name: 'work');
      final now = DateTime.now();
      await db.inboxDao.insertTodo(TodosCompanion(
        id: const Value('i1'),
        title: const Value('Tagged inbox item'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
      await db.inboxDao.insertTodo(TodosCompanion(
        id: const Value('i2'),
        title: const Value('Untagged inbox item'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
      await db.tagDao.assignTag('i1', 'ctx1', _userId);

      final results = await db.inboxDao
          .watchInbox(_userId, tagIds: {'ctx1'}).first;
      expect(results, hasLength(1));
      expect(results.first.id, 'i1');
    });

    test('watchInbox with no tagIds returns all inbox items', () async {
      final now = DateTime.now();
      await db.inboxDao.insertTodo(TodosCompanion(
        id: const Value('i1'),
        title: const Value('A'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
      await db.inboxDao.insertTodo(TodosCompanion(
        id: const Value('i2'),
        title: const Value('B'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));

      final results =
          await db.inboxDao.watchInbox(_userId).first;
      expect(results, hasLength(2));
    });
  });
}
