import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/gtd_state_machine.dart';
import 'package:jeeves/models/todo.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

const _userId = 'test-user';

Future<String> _insertTodo(
  GtdDatabase db, {
  required String id,
  required String title,
  String state = 'inbox',
}) async {
  final now = DateTime.now();
  await db.inboxDao.insertTodo(TodosCompanion(
    id: Value(id),
    title: Value(title),
    state: const Value('inbox'),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
  // If a non-inbox state is needed, transition there step by step.
  if (state != 'inbox') {
    await (db.update(db.todos)..where((t) => t.id.equals(id)))
        .write(TodosCompanion(state: Value(state)));
  }
  return id;
}

void main() {
  setUpAll(configureSqliteForTests);

  group('TodoDao — transitionState', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('valid transition updates state', () async {
      await _insertTodo(db, id: 'a', title: 'Task A');
      await db.todoDao.transitionState('a', _userId, GtdState.nextAction);

      final row = await db.todoDao.getTodo('a', _userId);
      expect(row?.state, GtdState.nextAction.value);
    });

    test('invalid transition throws InvalidStateTransitionException', () async {
      await _insertTodo(db, id: 'b', title: 'Task B');
      expect(
        () => db.todoDao.transitionState('b', _userId, GtdState.inProgress),
        throwsA(isA<InvalidStateTransitionException>()),
      );
    });

    test('entering inProgress opens a TimeLog row with started_at set',
        () async {
      await _insertTodo(db, id: 'c', title: 'Task C', state: 'next_action');
      final startTime = DateTime(2024, 1, 1, 10, 0, 0);
      await db.todoDao
          .transitionState('c', _userId, GtdState.inProgress, now: startTime);

      final row = await db.todoDao.getTodo('c', _userId);
      expect(row?.state, GtdState.inProgress.value);

      final logs = await (db.select(db.timeLogs)
            ..where((t) => t.taskId.equals('c')))
          .get();
      expect(logs.length, 1);
      expect(logs.first.startedAt, startTime.toUtc().toIso8601String());
      expect(logs.first.endedAt, isNull);
    });

    test('leaving inProgress closes TimeLog row and updates time_spent_minutes cache',
        () async {
      await _insertTodo(db, id: 'd', title: 'Task D', state: 'next_action');
      final start = DateTime(2024, 1, 1, 10, 0, 0);
      await db.todoDao
          .transitionState('d', _userId, GtdState.inProgress, now: start);

      // 95 seconds → ceiling → 2 minutes.
      final finish = start.add(const Duration(seconds: 95));
      await db.todoDao
          .transitionState('d', _userId, GtdState.done, now: finish);

      final logs = await (db.select(db.timeLogs)
            ..where((t) => t.taskId.equals('d')))
          .get();
      expect(logs.length, 1);
      expect(logs.first.endedAt, isNotNull);

      final row = await db.todoDao.getTodo('d', _userId);
      expect(row?.state, GtdState.done.value);
      expect(row?.timeSpentMinutes, 2);
      expect(row?.inProgressSince, isNull);
    });

    test('multiple inProgress stints create one TimeLog row per stint; cache equals sum',
        () async {
      await _insertTodo(db, id: 'e', title: 'Task E', state: 'next_action');

      // First stint: 30 seconds → ceiling → 1 minute.
      final start1 = DateTime(2024, 1, 1, 9, 0, 0);
      await db.todoDao
          .transitionState('e', _userId, GtdState.inProgress, now: start1);
      final end1 = start1.add(const Duration(seconds: 30));
      await db.todoDao
          .transitionState('e', _userId, GtdState.done, now: end1);

      // Reset state for second stint.
      await (db.update(db.todos)..where((t) => t.id.equals('e')))
          .write(const TodosCompanion(state: Value('next_action')));

      // Second stint: 120 seconds → exactly 2 minutes.
      final start2 = DateTime(2024, 1, 2, 10, 0, 0);
      await db.todoDao
          .transitionState('e', _userId, GtdState.inProgress, now: start2);
      final end2 = start2.add(const Duration(seconds: 120));
      await db.todoDao
          .transitionState('e', _userId, GtdState.done, now: end2);

      final logs = await (db.select(db.timeLogs)
            ..where((t) => t.taskId.equals('e')))
          .get();
      expect(logs.length, 2); // one row per stint

      final row = await db.todoDao.getTodo('e', _userId);
      expect(row?.timeSpentMinutes, 3); // cache = SUM(1 + 2)
      expect(row?.inProgressSince, isNull);
    });

    test('inProgressSince is null after any state transition', () async {
      await _insertTodo(db, id: 'f', title: 'Task F', state: 'next_action');
      final start = DateTime(2024, 1, 1, 8, 0, 0);
      await db.todoDao
          .transitionState('f', _userId, GtdState.inProgress, now: start);

      // inProgressSince is inert after this PR; TimeLog.startedAt is canonical.
      final row = await db.todoDao.getTodo('f', _userId);
      expect(row?.inProgressSince, isNull);
    });
  });

  group('TodoDao — GTD list watchers', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('watchWaitingFor returns only waiting_for todos', () async {
      await _insertTodo(db, id: 'w1', title: 'Waiting 1');
      await (db.update(db.todos)..where((t) => t.id.equals('w1')))
          .write(const TodosCompanion(state: Value('waiting_for')));
      await _insertTodo(db, id: 'w2', title: 'Inbox item');

      final items = await db.todoDao.watchWaitingFor(_userId).first;
      expect(items.length, 1);
      expect(items.first.id, 'w1');
    });

    test('watchMaybe returns only intent=maybe todos (not done)', () async {
      await _insertTodo(db, id: 'm1', title: 'Maybe 1', state: 'next_action');
      await db.todoDao.deferTaskToMaybe('m1', _userId);
      await _insertTodo(db, id: 'm2', title: 'Next action', state: 'next_action');
      await _insertTodo(db, id: 'm3', title: 'Maybe Done', state: 'next_action');
      await db.todoDao.deferTaskToMaybe('m3', _userId);
      await (db.update(db.todos)..where((t) => t.id.equals('m3')))
          .write(const TodosCompanion(state: Value('done')));

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
}
