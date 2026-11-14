import 'package:drift/drift.dart' hide isNull;
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
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
    id: Value(id),
    title: Value(title),
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
          await db.tagDao.watchTagsWithActiveCount('context').first;
      expect(results, hasLength(1));
      expect(results.first.tag.name, 'work');
      expect(results.first.count, 0);
    });

    test('counts only non-done todos', () async {
      await _insertTag(db, id: 'ctx1', name: 'work');
      final t1 = await _insertTodo(db,
          id: 't1', title: 'Task A');
      final t2 = await _insertTodo(db,
          id: 't2', title: 'Task B');
      await db.todoDao.markDone(t2);
      // An Inbox Capture carrying the tag as a hint is not an Outcome.
      final now = DateTime.now();
      await db.captureDao.insertCapture(CapturesCompanion(
        id: const Value('c1'),
        title: const Value('Task C'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
      await db.captureDao.assignTagHint('c1', 'ctx1', _userId);
      await _assignTag(db, t1, 'ctx1');
      await _assignTag(db, t2, 'ctx1');

      final results =
          await db.tagDao.watchTagsWithActiveCount('context').first;
      expect(results.first.count, 1); // only t1 (not done) is counted
    });

    test('count updates reactively when a todo is completed', () async {
      await _insertTag(db, id: 'ctx1', name: 'work');
      final t1 = await _insertTodo(db,
          id: 't1', title: 'Active task');
      await _assignTag(db, t1, 'ctx1');

      // Single subscription — two separate `.first` calls would create
      // fresh streams and hide any reactivity bug.
      final counts = db.tagDao
          .watchTagsWithActiveCount('context')
          .map((rows) => rows.first.count);
      final expectation = expectLater(counts, emitsInOrder([1, 0]));

      // Let the initial query emit `1` before the write. `markDone` is now
      // atomic (it runs inside GtdDatabase.capturing's transaction), so it
      // holds the single connection until commit; without this settle the
      // subscription's opening SELECT would queue behind the write and the
      // stream would only ever see the post-commit `0`.
      await pumpEventQueue();

      // Mark done — should push a new emission on the same stream.
      await db.todoDao.markDone(t1);

      await expectation;
    });

    test('returns tags sorted alphabetically', () async {
      for (final name in ['zebra', 'alpha', 'middle']) {
        await _insertTag(db, id: name, name: name);
      }
      final results =
          await db.tagDao.watchTagsWithActiveCount('context').first;
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
          await db.tagDao.watchByType('context').first;
      expect(tags.first.name, 'office');
      expect(tags.first.color, '#ff0000');
    });

    test(
        'rename into an existing (name, type) folds into the survivor instead '
        'of recreating duplicates', () async {
      await _insertTag(db, id: 'ctx-src', name: 'work');
      await _insertTag(db, id: 'ctx-dst', name: 'office');

      final todoId = await _insertTodo(db, id: 'todo-rename', title: 'Task');
      await _assignTag(db, todoId, 'ctx-src');

      await db.tagDao.rename('ctx-src', 'office');

      // Source tag is gone, target survives — invariant: one row per
      // (name, type).
      final all = await db.tagDao.watchByType('context').first;
      expect(all, hasLength(1));
      expect(all.first.id, 'ctx-dst');
      expect(all.first.name, 'office');

      // Junction repointed to the surviving tag id.
      final links = await (db.select(db.todoTags)
            ..where((tt) => tt.todoId.equals(todoId)))
          .get();
      expect(links, hasLength(1));
      expect(links.single.tagId, 'ctx-dst');
    });

    test('rename into a same-name different-type does not merge', () async {
      await _insertTag(db, id: 'ctx-shared', name: 'work', type: 'context');
      await _insertTag(db, id: 'proj-shared', name: 'office', type: 'project');

      await db.tagDao.rename('ctx-shared', 'office');

      final ctx = await db.tagDao.watchByType('context').first;
      final proj = await db.tagDao.watchByType('project').first;
      expect(ctx, hasLength(1));
      expect(ctx.first.id, 'ctx-shared');
      expect(ctx.first.name, 'office');
      expect(proj, hasLength(1));
      expect(proj.first.id, 'proj-shared');
    });

    test('renaming to the current name is a no-op', () async {
      await _insertTag(db, id: 'ctx1', name: 'work');
      await db.tagDao.rename('ctx1', 'work');
      final tags = await db.tagDao.watchByType('context').first;
      expect(tags, hasLength(1));
      expect(tags.first.id, 'ctx1');
      expect(tags.first.name, 'work');
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
          await db.tagDao.watchByType('context').first;
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
          await db.tagDao.watchByType('context').first;
      expect(tags.first.color, isNull);
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
          id: 't1', title: 'Task');
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
          await db.tagDao.watchByType('context').first;
      final remainingIds = remaining.map((t) => t.id).toList();
      expect(remainingIds, isNot(contains('src')));
    });

    test('throws on self-merge without deleting data', () async {
      await _insertTag(db, id: 'src', name: 'old');
      final t1 = await _insertTodo(db,
          id: 't1', title: 'Task');
      await _assignTag(db, t1, 'src');

      expect(() => db.tagDao.merge('src', 'src'), throwsArgumentError);

      final tags = await db.tagDao.watchByType('context').first;
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
          id: 't1', title: 'Task');
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

  group('TagDao.merge across both junctions', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    Future<void> insertCapture(String id) =>
        db.captureDao.insertCapture(CapturesCompanion(
          id: Value(id),
          title: Value('Capture $id'),
          captureSource: const Value('manual'),
          userId: const Value(_userId),
          createdAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ));

    for (final kind in ['context', 'project', 'person']) {
      test('$kind: moves Outcome links and Capture hints, leaving none on the source',
          () async {
        await _insertTag(db, id: 'src', name: 'old', type: kind);
        await _insertTag(db, id: 'tgt', name: 'new', type: kind);
        await _insertTodo(db, id: 't1', title: 'Task');
        await _insertTodo(db, id: 't2', title: 'Both');
        await insertCapture('c1');
        await _assignTag(db, 't1', 'src');
        await _assignTag(db, 't2', 'src');
        await _assignTag(db, 't2', 'tgt');
        await db.captureDao.assignTagHint('c1', 'src', _userId);

        await db.tagDao.merge('src', 'tgt');

        final todoRows = await db.select(db.todoTags).get();
        expect(todoRows.map((r) => r.tagId).toSet(), {'tgt'});
        expect(todoRows.where((r) => r.todoId == 't2'), hasLength(1));
        expect(todoRows, hasLength(2));
        final captureRows = await db.select(db.captureTags).get();
        expect(captureRows, hasLength(1));
        expect(captureRows.single.tagId, 'tgt');
        expect(captureRows.single.captureId, 'c1');
        final ids = (await db.select(db.tags).get()).map((t) => t.id);
        expect(ids, ['tgt']);
        expect(await db.select(db.todos).get(), hasLength(2));
      });
    }

    test('refuses a merge across kinds and changes nothing', () async {
      await _insertTag(db, id: 'src', name: 'Alice', type: 'person');
      await _insertTag(db, id: 'tgt', name: 'work', type: 'context');
      await _insertTodo(db, id: 't1', title: 'Task');
      await _assignTag(db, 't1', 'src');

      await expectLater(db.tagDao.merge('src', 'tgt'), throwsArgumentError);

      expect(await db.select(db.tags).get(), hasLength(2));
      expect((await db.select(db.todoTags).get()).single.tagId, 'src');
    });

    test('refuses a missing target', () async {
      await _insertTag(db, id: 'src', name: 'old');
      await expectLater(db.tagDao.merge('src', 'nope'), throwsArgumentError);
      expect(await db.select(db.tags).get(), hasLength(1));
    });

    test('rename onto a taken name of the same kind merges', () async {
      await _insertTag(db, id: 'a', name: 'Alice', type: 'person');
      await _insertTag(db, id: 'b', name: 'Alise', type: 'person');
      await _insertTodo(db, id: 't1', title: 'Task');
      await _assignTag(db, 't1', 'b');

      await db.tagDao.rename('b', 'Alice');

      final all = await db.select(db.tags).get();
      expect(all.map((t) => t.id), ['a']);
      expect((await db.select(db.todoTags).get()).single.tagId, 'a');
    });
  });

  group('TagDao.deleteTag', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    for (final kind in ['context', 'project', 'person']) {
      test('$kind: removes the entry from every Outcome and Capture, keeping both',
          () async {
        await _insertTag(db, id: 'gone', name: 'x', type: kind);
        await _insertTag(db, id: 'keep', name: 'y', type: kind);
        await _insertTodo(db, id: 't1', title: 'Task');
        await _insertTodo(db, id: 't2', title: 'Other');
        await db.captureDao.insertCapture(CapturesCompanion(
          id: const Value('c1'),
          title: const Value('Capture'),
          captureSource: const Value('manual'),
          userId: const Value(_userId),
          createdAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ));
        await _assignTag(db, 't1', 'gone');
        await _assignTag(db, 't2', 'gone');
        await _assignTag(db, 't2', 'keep');
        await db.captureDao.assignTagHint('c1', 'gone', _userId);
        await db.captureDao.assignTagHint('c1', 'keep', _userId);

        await db.tagDao.deleteTag('gone');

        expect((await db.select(db.tags).get()).map((t) => t.id), ['keep']);
        final todoRows = await db.select(db.todoTags).get();
        expect(todoRows.map((r) => '${r.todoId}/${r.tagId}'), ['t2/keep']);
        final captureRows = await db.select(db.captureTags).get();
        expect(captureRows.map((r) => r.tagId), ['keep']);
        expect(await db.select(db.todos).get(), hasLength(2));
        expect(await db.select(db.captures).get(), hasLength(1));
      });
    }

    test('an unknown id is a no-op', () async {
      await _insertTag(db, id: 'keep', name: 'y');
      await db.tagDao.deleteTag('nope');
      expect(await db.select(db.tags).get(), hasLength(1));
    });
  });

  group('TodoDao tag filtering', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('watchNext with no tagIds returns all next actions', () async {
      await _insertTodo(db, id: 't1', title: 'A');
      await _insertTodo(db, id: 't2', title: 'B');
      final results =
          await db.todoDao.watchNext().first;
      expect(results, hasLength(2));
    });

    test('watchNext with tagIds returns only matching todos', () async {
      await _insertTag(db, id: 'ctx1', name: 'work');
      await _insertTag(db, id: 'ctx2', name: 'home');
      final t1 = await _insertTodo(db,
          id: 't1', title: 'Work task');
      final t2 = await _insertTodo(db,
          id: 't2', title: 'Home task');
      await _assignTag(db, t1, 'ctx1');
      await _assignTag(db, t2, 'ctx2');

      final results = await db.todoDao
          .watchNext(tagIds: {'ctx1'}).first;
      expect(results, hasLength(1));
      expect(results.first.id, t1);
    });

    test('watchNext with two tagIds uses AND semantics', () async {
      await _insertTag(db, id: 'ctx1', name: 'work');
      await _insertTag(db, id: 'ctx2', name: 'phone');
      // t1 has both tags; t2 has only one
      final t1 = await _insertTodo(db,
          id: 't1', title: 'Both');
      final t2 = await _insertTodo(db,
          id: 't2', title: 'One');
      await _assignTag(db, t1, 'ctx1');
      await _assignTag(db, t1, 'ctx2');
      await _assignTag(db, t2, 'ctx1');

      final results = await db.todoDao
          .watchNext(tagIds: {'ctx1', 'ctx2'}).first;
      expect(results, hasLength(1));
      expect(results.first.id, t1);
    });

    test('watchPersonTagged with tagIds filters correctly', () async {
      await _insertTag(db, id: 'ctx1', name: 'errand');
      await _insertTag(db, id: 'person1', name: 'Alice', type: 'person');
      await _insertTag(db, id: 'person2', name: 'Bob', type: 'person');
      await _insertTodo(db, id: 't1', title: 'Waiting tagged');
      await _insertTodo(db, id: 't2', title: 'Waiting untagged');
      // Both todos have person tags (making them Waiting For items).
      await _assignTag(db, 't1', 'person1');
      await _assignTag(db, 't2', 'person2');
      // Only t1 also has the context tag filter.
      await _assignTag(db, 't1', 'ctx1');

      final results = await db.todoDao
          .watchPersonTagged(tagIds: {'ctx1'}).first;
      expect(results, hasLength(1));
      expect(results.first.id, 't1');
    });

    test('watchPersonTaggedGrouped with tagIds keeps grouping and filters',
        () async {
      await _insertTag(db, id: 'ctx1', name: 'errand');
      await _insertTag(db, id: 'ctx2', name: 'phone');
      await _insertTag(db, id: 'person1', name: 'Alice', type: 'person');
      await _insertTag(db, id: 'person2', name: 'Bob', type: 'person');
      await _insertTodo(db, id: 't1', title: 'Both ctx');
      await _insertTodo(db, id: 't2', title: 'One ctx');
      await _assignTag(db, 't1', 'person1');
      await _assignTag(db, 't2', 'person2');
      await _assignTag(db, 't1', 'ctx1');
      await _assignTag(db, 't1', 'ctx2');
      await _assignTag(db, 't2', 'ctx1');

      final one = await db.todoDao
          .watchPersonTaggedGrouped(tagIds: {'ctx1'}).first;
      expect(one.keys.map((t) => t.name), ['Alice', 'Bob']);

      final both = await db.todoDao
          .watchPersonTaggedGrouped(tagIds: {'ctx1', 'ctx2'}).first;
      expect(both.keys.map((t) => t.name), ['Alice']);
      expect(both.values.single.map((t) => t.id), ['t1']);

      final none = await db.todoDao.watchPersonTaggedGrouped().first;
      expect(none.keys.map((t) => t.name), ['Alice', 'Bob']);
    });

  });
}
