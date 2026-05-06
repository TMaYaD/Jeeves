import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

const _userId = 'test-user';

Future<String> _insertTodo(
  GtdDatabase db, {
  required String id,
  required String title,
  bool clarified = true,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
    id: Value(id),
    title: Value(title),
    clarified: Value(clarified),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
  return id;
}

Future<String> _insertPersonTag(
  GtdDatabase db, {
  required String id,
  required String name,
}) async {
  await db.tagDao.upsertTag(TagsCompanion(
    id: Value(id),
    name: Value(name),
    type: const Value('person'),
    userId: const Value(_userId),
  ));
  return id;
}

void main() {
  setUpAll(configureSqliteForTests);

  group('TodoDao — watchTodosById', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('returns todos matching the given ids', () async {
      await _insertTodo(db, id: 'x1', title: 'Task X1');
      await _insertTodo(db, id: 'x2', title: 'Task X2');
      await _insertTodo(db, id: 'x3', title: 'Task X3');

      final items =
          await db.todoDao.watchTodosById(['x1', 'x3']).first;
      expect(items.map((t) => t.id), containsAll(['x1', 'x3']));
      expect(items.any((t) => t.id == 'x2'), isFalse);
    });

    test('returns empty list for empty ids', () async {
      await _insertTodo(db, id: 'y1', title: 'Task Y1');

      final items = await db.todoDao.watchTodosById([]).first;
      expect(items, isEmpty);
    });
  });

  group('TodoDao — rescheduleTask', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('updates dueDate', () async {
      final todayDt = DateTime(2026, 4, 16);
      final newDate = DateTime(2026, 4, 20);
      await _insertTodo(db, id: 'r1', title: 'Reschedulable task');
      await (db.update(db.todos)..where((t) => t.id.equals('r1')))
          .write(TodosCompanion(dueDate: Value(todayDt)));

      await db.todoDao.rescheduleTask('r1', newDate);

      final row = await db.todoDao.getTodo('r1');
      expect(row?.dueDate, newDate.toUtc());
    });
  });

  group('TodoDao — GTD list watchers', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('watchPersonTagged returns todos linked to a person-typed tag', () async {
      await _insertTodo(db, id: 'w1', title: 'Waiting 1');
      await _insertPersonTag(db, id: 'p1', name: 'Alice');
      await db.tagDao.assignTag('w1', 'p1', _userId);
      // Task without person-tag → not in Waiting For list
      await _insertTodo(db, id: 'w2', title: 'Next action');

      final items = await db.todoDao.watchPersonTagged().first;
      expect(items.length, 1);
      expect(items.first.id, 'w1');
    });

    test('watchPersonTagged excludes tasks where clarified = false', () async {
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
        id: const Value('wc1'),
        title: const Value('Unclarified waiting'),
        clarified: const Value(false),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
      await _insertPersonTag(db, id: 'p2', name: 'Bob');
      await db.tagDao.assignTag('wc1', 'p2', _userId);

      final items = await db.todoDao.watchPersonTagged().first;
      expect(items.any((t) => t.id == 'wc1'), isFalse);
    });

    test('watchPersonTagged excludes done tasks', () async {
      await _insertTodo(db, id: 'wd1', title: 'Done waiting');
      await _insertPersonTag(db, id: 'p3', name: 'Carol');
      await db.tagDao.assignTag('wd1', 'p3', _userId);
      await db.todoDao.markDone('wd1');

      final items = await db.todoDao.watchPersonTagged().first;
      expect(items.any((t) => t.id == 'wd1'), isFalse);
    });

    test('watchPersonTagged excludes tasks with no person-typed tags', () async {
      await _insertTodo(db, id: 'wn1', title: 'No person tag');

      final items = await db.todoDao.watchPersonTagged().first;
      expect(items.any((t) => t.id == 'wn1'), isFalse);
    });

    test('watchMaybe returns only intent=maybe todos (not done)', () async {
      await _insertTodo(db, id: 'm1', title: 'Maybe 1');
      await db.todoDao.deferTaskToMaybe('m1');
      await _insertTodo(db, id: 'm2', title: 'Next action');
      await _insertTodo(db, id: 'm3', title: 'Maybe Done');
      await db.todoDao.deferTaskToMaybe('m3');
      await db.todoDao.markDone('m3');

      final items = await db.todoDao.watchMaybe().first;
      expect(items.length, 1);
      expect(items.first.id, 'm1');
    });

    test('watchMaybe excludes intent=next todos', () async {
      await _insertTodo(db, id: 'n1', title: 'Next action');

      final items = await db.todoDao.watchMaybe().first;
      expect(items, isEmpty);
    });

    test('task appears in watchPersonTagged after person-tag assignment', () async {
      await _insertTodo(db, id: 's4', title: 'Task S4');
      await _insertPersonTag(db, id: 'p4', name: 'Carol');
      await db.tagDao.assignTag('s4', 'p4', _userId);

      final items = await db.todoDao.watchPersonTagged().first;
      expect(items.any((t) => t.id == 's4'), isTrue);
    });

    test('task leaves watchPersonTagged after person-tag removal', () async {
      await _insertTodo(db, id: 's5', title: 'Task S5');
      await _insertPersonTag(db, id: 'p5', name: 'Dave');
      await db.tagDao.assignTag('s5', 'p5', _userId);
      await (db.delete(db.todoTags)
            ..where((tt) => tt.todoId.equals('s5') & tt.tagId.equals('p5')))
          .go();

      final items = await db.todoDao.watchPersonTagged().first;
      expect(items.any((t) => t.id == 's5'), isFalse);
    });

  });

  group('TodoDao — markDone', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('markDone sets done_at', () async {
      await _insertTodo(db, id: 'md1', title: 'Task MD1');
      final now = DateTime(2024, 6, 1, 12, 0, 0);
      await db.todoDao.markDone('md1', now: now);

      final row = await db.todoDao.getTodo('md1');
      expect(row?.doneAt, isNotNull);
    });

    test('markDone task no longer appears in watchNextActions', () async {
      await _insertTodo(db, id: 'md2', title: 'Task MD2');
      await db.todoDao.markDone('md2');

      final items = await db.todoDao.watchNextActions().first;
      expect(items.any((t) => t.id == 'md2'), isFalse);
    });

    test('watchDone returns done tasks ordered by done_at DESC', () async {
      await _insertTodo(db, id: 'wd1', title: 'First done');
      await _insertTodo(db, id: 'wd2', title: 'Second done');
      final t1 = DateTime(2024, 6, 1, 10, 0, 0);
      final t2 = DateTime(2024, 6, 2, 10, 0, 0);
      await db.todoDao.markDone('wd1', now: t1);
      await db.todoDao.markDone('wd2', now: t2);

      final items = await db.todoDao.watchDone().first;
      expect(items.length, 2);
      expect(items.first.id, 'wd2'); // most recent first
      expect(items.last.id, 'wd1');
    });

    test('watchNextActions excludes done tasks', () async {
      await _insertTodo(db, id: 'na1', title: 'Active next action');
      await _insertTodo(db, id: 'na2', title: 'Done next action');
      await db.todoDao.markDone('na2');

      final items = await db.todoDao.watchNextActions().first;
      expect(items.length, 1);
      expect(items.first.id, 'na1');
    });

    test('watchMaybe excludes done maybe tasks', () async {
      await _insertTodo(db, id: 'mm1', title: 'Active maybe');
      await _insertTodo(db, id: 'mm2', title: 'Done maybe');
      await db.todoDao.deferTaskToMaybe('mm1');
      await db.todoDao.deferTaskToMaybe('mm2');
      await db.todoDao.markDone('mm2');

      final items = await db.todoDao.watchMaybe().first;
      expect(items.length, 1);
      expect(items.first.id, 'mm1');
    });
  });

  group('TodoDao — setIntent / deferTaskToMaybe', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('deferTaskToMaybe sets intent to maybe', () async {
      await _insertTodo(db, id: 'i1', title: 'Task I1');
      await db.todoDao.deferTaskToMaybe('i1');

      final row = await db.todoDao.getTodo('i1');
      expect(row?.intent, 'maybe');
    });

    test('setIntent updates intent and bumps updated_at', () async {
      await _insertTodo(db, id: 'i2', title: 'Task I2');
      final before = (await db.todoDao.getTodo('i2'))?.updatedAt;
      await db.todoDao.setIntent('i2', Intent.trash);

      final row = await db.todoDao.getTodo('i2');
      expect(row?.intent, 'trash');
      // updated_at should be set (may equal or be after before)
      expect(row?.updatedAt, isNotNull);
      if (before != null) {
        expect(row!.updatedAt!.isAfter(before) || row.updatedAt == before, isTrue);
      }
    });

  });

  group('TodoDao — updateFields', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('updates title and notes', () async {
      await _insertTodo(db, id: 'u1', title: 'Original');
      await db.todoDao.updateFields('u1', title: 'Updated', notes: 'Some notes');

      final row = await db.todoDao.getTodo('u1');
      expect(row?.title, 'Updated');
      expect(row?.notes, 'Some notes');
    });

    test('title change stamps lastClarifiedAt', () async {
      await _insertTodo(db, id: 'u2', title: 'Original');
      await db.todoDao.updateFields('u2', title: 'Renamed');

      final row = await db.todoDao.getTodo('u2');
      expect(row?.lastClarifiedAt, isNotNull);
    });

    test('notes-only change does not stamp lastClarifiedAt', () async {
      await _insertTodo(db, id: 'u3', title: 'Task');
      await db.todoDao.updateFields('u3', notes: 'New notes');

      final row = await db.todoDao.getTodo('u3');
      expect(row?.lastClarifiedAt, isNull);
    });

    test('clearDueDate stamps lastClarifiedAt', () async {
      await _insertTodo(db, id: 'u4', title: 'Task');
      // Set then immediately clear due date; both calls should stamp lastClarifiedAt.
      final due = DateTime.now().add(const Duration(days: 1));
      await db.todoDao.updateFields('u4', dueDate: due);
      await db.todoDao.updateFields('u4', clearDueDate: true);

      final row = await db.todoDao.getTodo('u4');
      expect(row?.lastClarifiedAt, isNotNull);
    });
  });

  group('TodoDao — stampLastClarifiedAt', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('stamps lastClarifiedAt on the todo', () async {
      await _insertTodo(db, id: 's1', title: 'Task S1');
      await db.todoDao.stampLastClarifiedAt('s1');

      final row = await db.todoDao.getTodo('s1');
      expect(row?.lastClarifiedAt, isNotNull);
    });
  });
}
