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

Future<void> _insertTodo(
  GtdDatabase db, {
  required String id,
  required String title,
  String? notes,
  String? energyLevel,
  int? timeEstimate,
  DateTime? dueDate,
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
    userId: const Value(_user),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
}

Future<String> _insertTag(
  GtdDatabase db, {
  required String name,
  required String type,
}) async {
  final tag = TagsCompanion.insert(
    name: name,
    type: Value(type),
    userId: _user,
  );
  await db.tagDao.upsertTag(tag);
  // Retrieve the inserted tag's id
  final tags = await db.tagDao.watchByType(type).first;
  return tags.firstWhere((t) => t.name == name).id;
}

Future<void> _insertCapture(
  GtdDatabase db, {
  required String id,
  required String title,
  String? notes,
  bool clarified = false,
}) async {
  final now = DateTime.now();
  await db.captureDao.insertCapture(CapturesCompanion(
    id: Value(id),
    title: Value(title),
    notes: Value(notes),
    clarifiedAt: clarified ? Value(now) : const Value.absent(),
    userId: const Value(_user),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
}

void main() {
  setUpAll(configureSqliteForTests);

  group('SearchDao — text search', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('partial title match (case-insensitive)', () async {
      await _insertTodo(db, id: 'a', title: 'Buy groceries');
      await _insertTodo(db, id: 'b', title: 'Call dentist');

      final results = await db.searchDao
          .search(const SearchQuery(text: 'groc'))
          .first;

      expect(results.length, 1);
      expect(results.first.todo!.id, 'a');
      expect(results.first.matchedFields, contains(SearchMatchField.title));
    });

    test('uppercase query matches lowercase title', () async {
      await _insertTodo(db, id: 'a', title: 'buy groceries');

      final results = await db.searchDao
          .search(const SearchQuery(text: 'BUY'))
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
          .search(const SearchQuery(text: 'plumber'))
          .first;

      expect(results.length, 1);
      expect(results.first.todo!.id, 'a');
      expect(results.first.matchedFields, contains(SearchMatchField.notes));
      expect(results.first.matchSnippet, isNotNull);
      expect(results.first.matchSnippet, contains('plumber'));
    });

    test('tag name match (context tag)', () async {
      await _insertTodo(db, id: 'a', title: 'Task A');
      final tagId = await _insertTag(db, name: 'office', type: 'context');
      await db.tagDao.assignTag('a', tagId, _user);

      final results = await db.searchDao
          .search(const SearchQuery(text: 'office'))
          .first;

      expect(results.length, 1);
      expect(results.first.todo!.id, 'a');
      expect(results.first.matchedFields, contains(SearchMatchField.contextTag));
    });

    test('project tag match', () async {
      await _insertTodo(db, id: 'a', title: 'Write spec');
      final tagId = await _insertTag(db, name: 'WebProject', type: 'project');
      await db.tagDao.assignTag('a', tagId, _user);

      final results = await db.searchDao
          .search(const SearchQuery(text: 'WebProject'))
          .first;

      expect(results.length, 1);
      expect(results.first.matchedFields, contains(SearchMatchField.projectTag));
    });

    test('area tag match', () async {
      await _insertTodo(db, id: 'a', title: 'Review docs');
      final tagId = await _insertTag(db, name: 'Health', type: 'area');
      await db.tagDao.assignTag('a', tagId, _user);

      final results = await db.searchDao
          .search(const SearchQuery(text: 'Health'))
          .first;

      expect(results.length, 1);
      expect(results.first.matchedFields, contains(SearchMatchField.areaTag));
    });

    test('no match returns empty', () async {
      await _insertTodo(db, id: 'a', title: 'Buy groceries');

      final results = await db.searchDao
          .search(const SearchQuery(text: 'zzznomatch'))
          .first;

      expect(results, isEmpty);
    });

    test('todos without tags are still returned when title matches', () async {
      await _insertTodo(db, id: 'a', title: 'Standalone task');

      final results = await db.searchDao
          .search(const SearchQuery(text: 'Standalone'))
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
          .search(const SearchQuery(text: 'phone'))
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
      await db.todoDao.markDone('a');
      await _insertTodo(db, id: 'b', title: 'Active thing');

      final results = await db.searchDao
          .search(const SearchQuery(text: 'thing'))
          .first;

      expect(results.length, 1);
      expect(results.first.todo!.id, 'b');
    });

    test('includeDone shows done tasks', () async {
      await _insertTodo(db, id: 'a', title: 'Done thing');
      await db.todoDao.markDone('a');

      final results = await db.searchDao
          .search(const SearchQuery(text: 'thing', includeDone: true))
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
          .search(const SearchQuery(text: 'Task', energyLevels: {'low'}))
          .first;

      expect(results.length, 1);
      expect(results.first.todo!.id, 'a');
    });

    test('time estimate filter excludes over-estimate and includes null', () async {
      await _insertTodo(db, id: 'a', title: 'Quick', timeEstimate: 15);
      await _insertTodo(db, id: 'b', title: 'Long', timeEstimate: 120);
      await _insertTodo(db, id: 'c', title: 'No estimate');

      // Use an empty text query so the time-estimate filter is the only constraint.
      final results = await db.searchDao
          .search(const SearchQuery(timeEstimateMaxMinutes: 30))
          .first;

      expect(results.map((r) => r.todo!.id), containsAll(['a', 'c']));
      expect(results.map((r) => r.todo!.id), isNot(contains('b')));
    });

    test('tag-scope filter (tagIds)', () async {
      await _insertTodo(db, id: 'a', title: 'Tagged');
      await _insertTodo(db, id: 'b', title: 'Untagged');
      final tagId = await _insertTag(db, name: 'work', type: 'context');
      await db.tagDao.assignTag('a', tagId, _user);

      final results = await db.searchDao
          .search(SearchQuery(tagIds: {tagId}))
          .first;

      expect(results.length, 1);
      expect(results.first.todo!.id, 'a');
    });
  });

  group('SearchDao — empty query', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('empty query returns empty stream immediately', () async {
      await _insertTodo(db, id: 'a', title: 'Something');

      final results =
          await db.searchDao.search(const SearchQuery()).first;

      expect(results, isEmpty);
    });
  });

  group('SearchDao — reactive updates', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('stream re-emits when a matching todo is inserted', () async {
      final stream = db.searchDao
          .search(const SearchQuery(text: 'hello'))
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

  group('SearchDao — countDoneOnlyMatches', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('returns 0 for empty text', () async {
      await _insertTodo(db, id: 'a', title: 'Done task');
      await db.todoDao.markDone('a');

      final count = await db.searchDao
          .countDoneOnlyMatches(const SearchQuery())
          .first;

      expect(count, 0);
    });

    test('returns 0 when includeDone is already true', () async {
      await _insertTodo(db, id: 'a', title: 'Done task');
      await db.todoDao.markDone('a');

      final count = await db.searchDao
          .countDoneOnlyMatches(
            const SearchQuery(text: 'task', includeDone: true),
          )
          .first;

      expect(count, 0);
    });

    test('counts done tasks matching title', () async {
      await _insertTodo(db, id: 'a', title: 'Done task');
      await db.todoDao.markDone('a');
      await _insertTodo(db, id: 'b', title: 'Active task');

      final count = await db.searchDao
          .countDoneOnlyMatches(const SearchQuery(text: 'task'))
          .first;

      expect(count, 1);
    });

    test('counts done tasks matching notes', () async {
      await _insertTodo(
        db,
        id: 'a',
        title: 'Done task',
        notes: 'important plumber call',
      );
      await db.todoDao.markDone('a');

      final count = await db.searchDao
          .countDoneOnlyMatches(const SearchQuery(text: 'plumber'))
          .first;

      expect(count, 1);
    });

    test('does not count active tasks', () async {
      await _insertTodo(db, id: 'a', title: 'Active task');

      final count = await db.searchDao
          .countDoneOnlyMatches(const SearchQuery(text: 'task'))
          .first;

      expect(count, 0);
    });

    test('respects tag-scope filter', () async {
      await _insertTodo(db, id: 'a', title: 'Done task');
      await db.todoDao.markDone('a');
      await _insertTodo(db, id: 'b', title: 'Done tagged task');
      await db.todoDao.markDone('b');
      final tagId = await _insertTag(db, name: 'work', type: 'context');
      await db.tagDao.assignTag('b', tagId, _user);

      final count = await db.searchDao
          .countDoneOnlyMatches(SearchQuery(text: 'task', tagIds: {tagId}))
          .first;

      expect(count, 1);
    });

    test('reacts to database changes', () async {
      await _insertTodo(db, id: 'a', title: 'Future done task');

      final stream = db.searchDao
          .countDoneOnlyMatches(const SearchQuery(text: 'task'));

      final it = StreamIterator(stream);

      expect(await it.moveNext(), isTrue);
      expect(it.current, 0);

      await db.todoDao.markDone('a');

      expect(await it.moveNext(), isTrue);
      expect(it.current, 1);

      await it.cancel();
    });
  });

  group('SearchDao — Inbox Captures (issue #184)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('an unclarified Capture is findable by title', () async {
      await _insertCapture(db, id: 'c1', title: 'Call the plumber');

      final results =
          await db.searchDao.search(const SearchQuery(text: 'plumber')).first;

      expect(results, hasLength(1));
      expect(results.single.isCapture, isTrue);
      expect(results.single.id, 'c1');
      expect(results.single.title, 'Call the plumber');
      expect(results.single.matchedFields, contains(SearchMatchField.title));
    });

    test('a Capture is findable by its notes, with a snippet', () async {
      await _insertCapture(
        db,
        id: 'c1',
        title: 'Errand',
        notes: 'remember the plumber quote',
      );

      final results =
          await db.searchDao.search(const SearchQuery(text: 'plumber')).first;

      expect(results.single.id, 'c1');
      expect(results.single.matchedFields, contains(SearchMatchField.notes));
      expect(results.single.matchSnippet, contains('plumber'));
    });

    test('a clarified Capture is not returned', () async {
      // It is already represented by the Outcome it produced; returning both
      // would show the user the same thing twice.
      await _insertCapture(
        db,
        id: 'c1',
        title: 'Call the plumber',
        clarified: true,
      );

      final results =
          await db.searchDao.search(const SearchQuery(text: 'plumber')).first;

      expect(results, isEmpty);
    });

    test('Outcomes and Captures both come back for one term', () async {
      await _insertTodo(db, id: 't1', title: 'plumber invoice');
      await _insertCapture(db, id: 'c1', title: 'call plumber');

      final results =
          await db.searchDao.search(const SearchQuery(text: 'plumber')).first;

      expect(results.map((r) => r.id), containsAll(['t1', 'c1']));
      expect(results.where((r) => r.isCapture).map((r) => r.id), ['c1']);
    });

    test('a tag hint makes its Capture findable by tag name', () async {
      final tagId = await _insertTag(db, name: 'errands', type: 'context');
      await _insertCapture(db, id: 'c1', title: 'Something vague');
      await db.captureDao.assignTagHint('c1', tagId, _user);

      final results =
          await db.searchDao.search(const SearchQuery(text: 'errands')).first;

      expect(results.map((r) => r.id), contains('c1'));
    });

    test('a structured attribute filter excludes Captures', () async {
      await _insertTodo(db, id: 't1', title: 'plumber invoice',
          energyLevel: 'high');
      await _insertCapture(db, id: 'c1', title: 'call plumber');

      final results = await db.searchDao
          .search(const SearchQuery(text: 'plumber', energyLevels: {'high'}))
          .first;

      // Energy, estimate and due date are Outcome attributes a Capture has no
      // column for (ADR-0006), so filtering on one is a question a Capture
      // cannot answer — it drops out rather than matching vacuously.
      expect(results.map((r) => r.id), ['t1']);
    });
  });
}
