import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/search_query.dart';
import 'package:jeeves/models/search_result.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

const _user = 'test-user';
const _otherUser = 'other-user';

Future<void> _insertTodo(
  GtdDatabase db, {
  required String id,
  required String title,
  String? notes,
  String? energyLevel,
  int? timeEstimate,
  DateTime? dueDate,
  String userId = _user,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
    id: Value(id),
    title: Value(title),
    notes: Value(notes),
    energyLevel: Value(energyLevel),
    timeEstimate: Value(timeEstimate),
    dueDate: Value(dueDate),
    clarified: const Value(true),
    userId: Value(userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
}

Future<String> _insertTag(
  GtdDatabase db, {
  required String name,
  required String type,
  String userId = _user,
}) async {
  final tag = TagsCompanion.insert(
    name: name,
    type: Value(type),
    userId: userId,
  );
  await db.tagDao.upsertTag(tag);
  // Retrieve the inserted tag's id
  final tags = await db.tagDao.watchByType(userId, type).first;
  return tags.firstWhere((t) => t.name == name).id;
}

void main() {
  setUpAll(configureSqliteForTests);

  group('SearchDao — text search', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('exact title match', () async {
      await _insertTodo(db, id: 'a', title: 'Buy groceries');
      await _insertTodo(db, id: 'b', title: 'Call dentist');

      final results = await db.searchDao
          .search(_user, const SearchQuery(text: 'Buy groceries'))
          .first;

      expect(results.length, 1);
      expect(results.first.todo.id, 'a');
      expect(results.first.matchedFields, contains(SearchMatchField.title));
    });

    test('partial title match (case-insensitive)', () async {
      await _insertTodo(db, id: 'a', title: 'Buy groceries');
      await _insertTodo(db, id: 'b', title: 'Call dentist');

      final results = await db.searchDao
          .search(_user, const SearchQuery(text: 'groc'))
          .first;

      expect(results.length, 1);
      expect(results.first.todo.id, 'a');
    });

    test('uppercase query matches lowercase title', () async {
      await _insertTodo(db, id: 'a', title: 'buy groceries');

      final results = await db.searchDao
          .search(_user, const SearchQuery(text: 'BUY'))
          .first;

      expect(results.length, 1);
    });

    test('notes match with snippet', () async {
      await _insertTodo(
        db,
        id: 'a',
        title: 'Task A',
        notes: 'Remember to call the plumber about the leak',
      );
      await _insertTodo(db, id: 'b', title: 'Task B', notes: 'Nothing here');

      final results = await db.searchDao
          .search(_user, const SearchQuery(text: 'plumber'))
          .first;

      expect(results.length, 1);
      expect(results.first.todo.id, 'a');
      expect(results.first.matchedFields, contains(SearchMatchField.notes));
      expect(results.first.matchSnippet, isNotNull);
      expect(results.first.matchSnippet, contains('plumber'));
    });

    test('tag name match (context tag)', () async {
      await _insertTodo(db, id: 'a', title: 'Task A');
      final tagId = await _insertTag(db, name: 'office', type: 'context');
      await db.tagDao.assignTag('a', tagId, _user);

      final results = await db.searchDao
          .search(_user, const SearchQuery(text: 'office'))
          .first;

      expect(results.length, 1);
      expect(results.first.todo.id, 'a');
      expect(results.first.matchedFields, contains(SearchMatchField.contextTag));
    });

    test('project tag match', () async {
      await _insertTodo(db, id: 'a', title: 'Write spec');
      final tagId = await _insertTag(db, name: 'WebProject', type: 'project');
      await db.tagDao.assignTag('a', tagId, _user);

      final results = await db.searchDao
          .search(_user, const SearchQuery(text: 'WebProject'))
          .first;

      expect(results.length, 1);
      expect(results.first.matchedFields, contains(SearchMatchField.projectTag));
    });

    test('area tag match', () async {
      await _insertTodo(db, id: 'a', title: 'Review docs');
      final tagId = await _insertTag(db, name: 'Health', type: 'area');
      await db.tagDao.assignTag('a', tagId, _user);

      final results = await db.searchDao
          .search(_user, const SearchQuery(text: 'Health'))
          .first;

      expect(results.length, 1);
      expect(results.first.matchedFields, contains(SearchMatchField.areaTag));
    });

    test('no match returns empty', () async {
      await _insertTodo(db, id: 'a', title: 'Buy groceries');

      final results = await db.searchDao
          .search(_user, const SearchQuery(text: 'zzznomatch'))
          .first;

      expect(results, isEmpty);
    });

    test('todos without tags are still returned when title matches', () async {
      await _insertTodo(db, id: 'a', title: 'Standalone task');

      final results = await db.searchDao
          .search(_user, const SearchQuery(text: 'Standalone'))
          .first;

      expect(results.length, 1);
      expect(results.first.tags, isEmpty);
    });

    test('all tags for matched todo are returned, not just matching tag', () async {
      await _insertTodo(db, id: 'a', title: 'Multi-tag task');
      final ctx = await _insertTag(db, name: 'phone', type: 'context');
      final proj = await _insertTag(db, name: 'MyProject', type: 'project');
      await db.tagDao.assignTag('a', ctx, _user);
      await db.tagDao.assignTag('a', proj, _user);

      final results = await db.searchDao
          .search(_user, const SearchQuery(text: 'phone'))
          .first;

      expect(results.length, 1);
      // Both tags should be present even though only 'phone' matched
      expect(results.first.tags.map((t) => t.name), containsAll(['phone', 'MyProject']));
    });
  });

  group('SearchDao — done filtering', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('done tasks excluded by default', () async {
      await _insertTodo(db, id: 'a', title: 'Done thing');
      await db.todoDao.markDone('a', _user);
      await _insertTodo(db, id: 'b', title: 'Active thing');

      final results = await db.searchDao
          .search(_user, const SearchQuery(text: 'thing'))
          .first;

      expect(results.length, 1);
      expect(results.first.todo.id, 'b');
    });

    test('includeDone shows done tasks', () async {
      await _insertTodo(db, id: 'a', title: 'Done thing');
      await db.todoDao.markDone('a', _user);

      final results = await db.searchDao
          .search(_user, const SearchQuery(text: 'thing', includeDone: true))
          .first;

      expect(results.length, 1);
    });
  });

  group('SearchDao — structured filters', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('energy level filter', () async {
      await _insertTodo(db, id: 'a', title: 'Task', energyLevel: 'low');
      await _insertTodo(db, id: 'b', title: 'Task', energyLevel: 'high');
      await _insertTodo(db, id: 'c', title: 'Task');

      final results = await db.searchDao
          .search(
            _user,
            const SearchQuery(text: 'Task', energyLevels: {'low'}),
          )
          .first;

      expect(results.length, 1);
      expect(results.first.todo.id, 'a');
    });

    test('time estimate filter excludes over-estimate and includes null', () async {
      await _insertTodo(db, id: 'a', title: 'Quick', timeEstimate: 15);
      await _insertTodo(db, id: 'b', title: 'Long', timeEstimate: 120);
      await _insertTodo(db, id: 'c', title: 'No estimate');

      // Use an empty text query so the time-estimate filter is the only constraint.
      final results2 = await db.searchDao
          .search(
            _user,
            const SearchQuery(timeEstimateMaxMinutes: 30),
          )
          .first;

      expect(results2.map((r) => r.todo.id), containsAll(['a', 'c']));
      expect(results2.map((r) => r.todo.id), isNot(contains('b')));
    });

    test('tag-scope filter (tagIds)', () async {
      await _insertTodo(db, id: 'a', title: 'Tagged');
      await _insertTodo(db, id: 'b', title: 'Untagged');
      final tagId = await _insertTag(db, name: 'work', type: 'context');
      await db.tagDao.assignTag('a', tagId, _user);

      final results = await db.searchDao
          .search(_user, SearchQuery(tagIds: {tagId}))
          .first;

      expect(results.length, 1);
      expect(results.first.todo.id, 'a');
    });
  });

  group('SearchDao — user isolation', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('results are scoped to userId', () async {
      await _insertTodo(db, id: 'a', title: 'My task', userId: _user);
      await _insertTodo(db, id: 'b', title: 'Their task', userId: _otherUser);

      final results = await db.searchDao
          .search(_user, const SearchQuery(text: 'task'))
          .first;

      expect(results.length, 1);
      expect(results.first.todo.id, 'a');
    });
  });

  group('SearchDao — empty query', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('empty query returns empty stream immediately', () async {
      await _insertTodo(db, id: 'a', title: 'Something');

      final results =
          await db.searchDao.search(_user, const SearchQuery()).first;

      expect(results, isEmpty);
    });
  });

  group('SearchDao — reactive updates', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('stream re-emits when a matching todo is inserted', () async {
      final stream = db.searchDao
          .search(_user, const SearchQuery(text: 'hello'))
          .map((r) => r.length);

      final it = StreamIterator(stream);

      // First emission: nothing matches.
      expect(await it.moveNext(), isTrue);
      expect(it.current, 0);

      await _insertTodo(db, id: 'x', title: 'hello world');

      // Next emission fires once Drift re-fetches after the write.
      expect(await it.moveNext(), isTrue);
      expect(it.current, greaterThan(0));

      await it.cancel();
    });
  });
}
