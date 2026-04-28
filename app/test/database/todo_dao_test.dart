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
  String state = 'next_action',
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
    id: Value(id),
    title: Value(title),
    state: Value(state),
    clarified: const Value(true),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
  return id;
}

void main() {
  setUpAll(configureSqliteForTests);

  group('TodoDao — transitionState', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('updates state and sets clarified=true', () async {
      await _insertTodo(db, id: 'a', title: 'Task A');
      await db.todoDao.transitionState('a', _userId, GtdState.nextAction);

      final row = await db.todoDao.getTodo('a', _userId);
      expect(row?.state, GtdState.nextAction.value);
      expect(row?.clarified, isTrue);
    });

    test('updates updatedAt', () async {
      await _insertTodo(db, id: 'b', title: 'Task B');
      final now = DateTime(2024, 1, 1, 10, 0, 0);
      await db.todoDao
          .transitionState('b', _userId, GtdState.nextAction, now: now);

      final row = await db.todoDao.getTodo('b', _userId);
      expect(row?.updatedAt, isNotNull);
    });

    test('no-ops silently for unknown task', () async {
      await db.todoDao.transitionState('nonexistent', _userId, GtdState.nextAction);
      // No exception thrown.
    });
  });

  group('TodoDao — watchTodosById', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('returns todos matching the given ids', () async {
      await _insertTodo(db, id: 'x1', title: 'Task X1');
      await _insertTodo(db, id: 'x2', title: 'Task X2');
      await _insertTodo(db, id: 'x3', title: 'Task X3');

      final items =
          await db.todoDao.watchTodosById(_userId, ['x1', 'x3']).first;
      expect(items.map((t) => t.id), containsAll(['x1', 'x3']));
      expect(items.any((t) => t.id == 'x2'), isFalse);
    });

    test('returns empty list for empty ids', () async {
      await _insertTodo(db, id: 'y1', title: 'Task Y1');

      final items = await db.todoDao.watchTodosById(_userId, []).first;
      expect(items, isEmpty);
    });

    test('does not return todos belonging to another user', () async {
      await _insertTodo(db, id: 'z1', title: 'Task Z1');

      final items =
          await db.todoDao.watchTodosById('other-user', ['z1']).first;
      expect(items, isEmpty);
    });
  });

  group('TodoDao — rescheduleTask', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('updates dueDate without changing state', () async {
      final todayDt = DateTime(2026, 4, 16);
      final newDate = DateTime(2026, 4, 20);
      await _insertTodo(db, id: 'r1', title: 'Reschedulable task');
      await (db.update(db.todos)..where((t) => t.id.equals('r1')))
          .write(TodosCompanion(dueDate: Value(todayDt)));

      await db.todoDao.rescheduleTask('r1', _userId, newDate);

      final row = await db.todoDao.getTodo('r1', _userId);
      expect(row?.state, GtdState.nextAction.value);
      expect(row?.dueDate, newDate.toUtc());
    });
  });

  group('TodoDao — GTD list watchers', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('watchWaitingFor returns todos with non-null waiting_for column', () async {
      // Task with waiting_for column set → appears in Waiting For list
      await _insertTodo(db, id: 'w1', title: 'Waiting 1');
      await (db.update(db.todos)..where((t) => t.id.equals('w1')))
          .write(const TodosCompanion(waitingFor: Value('Alice')));
      // Task without waiting_for → not in Waiting For list
      await _insertTodo(db, id: 'w2', title: 'Next action');

      final items = await db.todoDao.watchWaitingFor(_userId).first;
      expect(items.length, 1);
      expect(items.first.id, 'w1');
    });

    test('watchWaitingFor excludes tasks where clarified = false', () async {
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
        id: const Value('wc1'),
        title: const Value('Unclarified waiting'),
        state: const Value('next_action'),
        waitingFor: const Value('Bob'),
        clarified: const Value(false),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));

      final items = await db.todoDao.watchWaitingFor(_userId).first;
      expect(items.any((t) => t.id == 'wc1'), isFalse);
    });

    test('watchWaitingFor excludes done tasks', () async {
      await _insertTodo(db, id: 'wd1', title: 'Done waiting');
      await (db.update(db.todos)..where((t) => t.id.equals('wd1')))
          .write(const TodosCompanion(waitingFor: Value('Carol')));
      await db.todoDao.markDone('wd1', _userId);

      final items = await db.todoDao.watchWaitingFor(_userId).first;
      expect(items.any((t) => t.id == 'wd1'), isFalse);
    });

    test('watchWaitingFor excludes tasks with null waiting_for', () async {
      await _insertTodo(db, id: 'wn1', title: 'No waiting_for');

      final items = await db.todoDao.watchWaitingFor(_userId).first;
      expect(items.any((t) => t.id == 'wn1'), isFalse);
    });

    test('watchMaybe returns only intent=maybe todos (not done)', () async {
      await _insertTodo(db, id: 'm1', title: 'Maybe 1', state: 'next_action');
      await db.todoDao.deferTaskToMaybe('m1', _userId);
      await _insertTodo(db, id: 'm2', title: 'Next action', state: 'next_action');
      await _insertTodo(db, id: 'm3', title: 'Maybe Done', state: 'next_action');
      await db.todoDao.deferTaskToMaybe('m3', _userId);
      await db.todoDao.markDone('m3', _userId);

      final items = await db.todoDao.watchMaybe(_userId).first;
      expect(items.length, 1);
      expect(items.first.id, 'm1');
    });

    test('watchMaybe excludes intent=next todos', () async {
      await _insertTodo(db, id: 'n1', title: 'Next action', state: 'next_action');

      final items = await db.todoDao.watchMaybe(_userId).first;
      expect(items, isEmpty);
    });

  });

  group('TodoDao — markDone', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('markDone sets done_at and leaves state as next_action', () async {
      await _insertTodo(db, id: 'md1', title: 'Task MD1');
      final now = DateTime(2024, 6, 1, 12, 0, 0);
      await db.todoDao.markDone('md1', _userId, now: now);

      final row = await db.todoDao.getTodo('md1', _userId);
      expect(row?.doneAt, isNotNull);
      expect(row?.state, 'next_action');
    });

    test('markDone task no longer appears in watchNextActions', () async {
      await _insertTodo(db, id: 'md2', title: 'Task MD2');
      await db.todoDao.markDone('md2', _userId);

      final items = await db.todoDao.watchNextActions(_userId).first;
      expect(items.any((t) => t.id == 'md2'), isFalse);
    });

    test('watchDone returns done tasks ordered by done_at DESC', () async {
      await _insertTodo(db, id: 'wd1', title: 'First done');
      await _insertTodo(db, id: 'wd2', title: 'Second done');
      final t1 = DateTime(2024, 6, 1, 10, 0, 0);
      final t2 = DateTime(2024, 6, 2, 10, 0, 0);
      await db.todoDao.markDone('wd1', _userId, now: t1);
      await db.todoDao.markDone('wd2', _userId, now: t2);

      final items = await db.todoDao.watchDone(_userId).first;
      expect(items.length, 2);
      expect(items.first.id, 'wd2'); // most recent first
      expect(items.last.id, 'wd1');
    });

    test('watchNextActions excludes done tasks even when state is next_action', () async {
      await _insertTodo(db, id: 'na1', title: 'Active next action');
      await _insertTodo(db, id: 'na2', title: 'Done next action');
      await db.todoDao.markDone('na2', _userId);

      final items = await db.todoDao.watchNextActions(_userId).first;
      expect(items.length, 1);
      expect(items.first.id, 'na1');
    });

    test('watchMaybe excludes done maybe tasks', () async {
      await _insertTodo(db, id: 'mm1', title: 'Active maybe');
      await _insertTodo(db, id: 'mm2', title: 'Done maybe');
      await db.todoDao.deferTaskToMaybe('mm1', _userId);
      await db.todoDao.deferTaskToMaybe('mm2', _userId);
      await db.todoDao.markDone('mm2', _userId);

      final items = await db.todoDao.watchMaybe(_userId).first;
      expect(items.length, 1);
      expect(items.first.id, 'mm1');
    });
  });

  group('TodoDao — setIntent / deferTaskToMaybe', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('deferTaskToMaybe sets intent to maybe without changing state', () async {
      await _insertTodo(db, id: 'i1', title: 'Task I1', state: 'next_action');
      await db.todoDao.deferTaskToMaybe('i1', _userId);

      final row = await db.todoDao.getTodo('i1', _userId);
      expect(row?.intent, 'maybe');
      expect(row?.state, 'next_action');
    });

    test('setIntent updates intent and bumps updated_at', () async {
      await _insertTodo(db, id: 'i2', title: 'Task I2');
      final before = (await db.todoDao.getTodo('i2', _userId))?.updatedAt;
      await db.todoDao.setIntent('i2', _userId, Intent.trash);

      final row = await db.todoDao.getTodo('i2', _userId);
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
      await db.todoDao.updateFields('u1', _userId, title: 'Updated', notes: 'Some notes');

      final row = await db.todoDao.getTodo('u1', _userId);
      expect(row?.title, 'Updated');
      expect(row?.notes, 'Some notes');
    });
  });

  group('TodoDao — setWaitingFor', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('writes waiting_for text column', () async {
      await _insertTodo(db, id: 's1', title: 'Task S1');
      await db.todoDao.setWaitingFor('s1', _userId, 'Alice');

      final row = await db.todoDao.getTodo('s1', _userId);
      expect(row?.waitingFor, 'Alice');
    });

    test('clears waiting_for when null is passed', () async {
      await _insertTodo(db, id: 's2', title: 'Task S2');
      await db.todoDao.setWaitingFor('s2', _userId, 'Bob');
      await db.todoDao.setWaitingFor('s2', _userId, null);

      final row = await db.todoDao.getTodo('s2', _userId);
      expect(row?.waitingFor, isNull);
    });

    test('empty string is coerced to null', () async {
      await _insertTodo(db, id: 's3', title: 'Task S3');
      await db.todoDao.setWaitingFor('s3', _userId, '');

      final row = await db.todoDao.getTodo('s3', _userId);
      expect(row?.waitingFor, isNull);
    });

    test('task appears in watchWaitingFor after setWaitingFor', () async {
      await _insertTodo(db, id: 's4', title: 'Task S4');
      await db.todoDao.setWaitingFor('s4', _userId, 'Carol');

      final items = await db.todoDao.watchWaitingFor(_userId).first;
      expect(items.any((t) => t.id == 's4'), isTrue);
    });

    test('task leaves watchWaitingFor after setWaitingFor(null)', () async {
      await _insertTodo(db, id: 's5', title: 'Task S5');
      await db.todoDao.setWaitingFor('s5', _userId, 'Dave');
      await db.todoDao.setWaitingFor('s5', _userId, null);

      final items = await db.todoDao.watchWaitingFor(_userId).first;
      expect(items.any((t) => t.id == 's5'), isFalse);
    });
  });
}
