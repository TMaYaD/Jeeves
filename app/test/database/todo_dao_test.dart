import 'package:drift/drift.dart';
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

    test('entering inProgress sets inProgressSince', () async {
      await _insertTodo(db, id: 'c', title: 'Task C', state: 'next_action');
      final startTime = DateTime(2024, 1, 1, 10, 0, 0);
      await db.todoDao
          .transitionState('c', _userId, GtdState.inProgress, now: startTime);

      final row = await db.todoDao.getTodo('c', _userId);
      expect(row?.state, GtdState.inProgress.value);
      expect(row?.inProgressSince, startTime.toIso8601String());
    });

    test('leaving inProgress logs elapsed minutes (rounded up)', () async {
      await _insertTodo(db, id: 'd', title: 'Task D', state: 'next_action');
      final start = DateTime(2024, 1, 1, 10, 0, 0);
      await db.todoDao
          .transitionState('d', _userId, GtdState.inProgress, now: start);

      // 95 seconds = 1 minute 35 seconds → rounds up to 2 minutes.
      final finish = start.add(const Duration(seconds: 95));
      await db.todoDao
          .transitionState('d', _userId, GtdState.done, now: finish);

      final row = await db.todoDao.getTodo('d', _userId);
      expect(row?.state, GtdState.done.value);
      expect(row?.timeSpentMinutes, 2);
      expect(row?.inProgressSince, equals(null));
    });

    test('multiple inProgress stints accumulate correctly', () async {
      await _insertTodo(db, id: 'e', title: 'Task E', state: 'next_action');

      // First stint: 30 seconds → rounds up to 1 minute.
      final start1 = DateTime(2024, 1, 1, 9, 0, 0);
      await db.todoDao
          .transitionState('e', _userId, GtdState.inProgress, now: start1);
      final end1 = start1.add(const Duration(seconds: 30));
      await db.todoDao
          .transitionState('e', _userId, GtdState.deferred, now: end1);

      // Move back to next_action → inProgress for a second stint.
      await (db.update(db.todos)..where((t) => t.id.equals('e')))
          .write(const TodosCompanion(state: Value('next_action')));

      // Second stint: 120 seconds → 2 minutes exactly.
      final start2 = DateTime(2024, 1, 2, 10, 0, 0);
      await db.todoDao
          .transitionState('e', _userId, GtdState.inProgress, now: start2);
      final end2 = start2.add(const Duration(seconds: 120));
      await db.todoDao
          .transitionState('e', _userId, GtdState.done, now: end2);

      final row = await db.todoDao.getTodo('e', _userId);
      expect(row?.timeSpentMinutes, 3); // 1 + 2
      expect(row?.inProgressSince, equals(null));
    });

    test('inProgressSince is cleared after exiting inProgress', () async {
      await _insertTodo(db, id: 'f', title: 'Task F', state: 'next_action');
      final start = DateTime(2024, 1, 1, 8, 0, 0);
      await db.todoDao
          .transitionState('f', _userId, GtdState.inProgress, now: start);
      await db.todoDao.transitionState(
        'f',
        _userId,
        GtdState.done,
        now: start.add(const Duration(minutes: 10)),
      );

      final row = await db.todoDao.getTodo('f', _userId);
      expect(row?.inProgressSince, equals(null));
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

    test('watchSomedayMaybe returns only someday_maybe todos', () async {
      await _insertTodo(db, id: 's1', title: 'Someday 1');
      await (db.update(db.todos)..where((t) => t.id.equals('s1')))
          .write(const TodosCompanion(state: Value('someday_maybe')));
      await _insertTodo(db, id: 's2', title: 'Next action');
      await (db.update(db.todos)..where((t) => t.id.equals('s2')))
          .write(const TodosCompanion(state: Value('next_action')));

      final items = await db.todoDao.watchSomedayMaybe(_userId).first;
      expect(items.length, 1);
      expect(items.first.id, 's1');
    });

    test('watchNextActions excludes tasks blocked by incomplete tasks', () async {
      // Blocker in next_action (not done).
      await _insertTodo(db, id: 'blocker', title: 'Blocker');
      await (db.update(db.todos)..where((t) => t.id.equals('blocker')))
          .write(const TodosCompanion(state: Value('next_action')));

      // Blocked task also in next_action.
      await _insertTodo(db, id: 'blocked', title: 'Blocked task');
      await (db.update(db.todos)..where((t) => t.id.equals('blocked'))).write(
        const TodosCompanion(
          state: Value('next_action'),
          blockedByTodoId: Value('blocker'),
        ),
      );

      final items = await db.todoDao.watchNextActions(_userId).first;
      // Only 'blocker' should appear; 'blocked' is hidden.
      expect(items.where((t) => t.id == 'blocked'), isEmpty);
      expect(items.where((t) => t.id == 'blocker'), hasLength(1));
    });

    test('watchNextActions shows blocked task once blocker is done', () async {
      await _insertTodo(db, id: 'blocker2', title: 'Blocker 2');
      await (db.update(db.todos)..where((t) => t.id.equals('blocker2')))
          .write(const TodosCompanion(state: Value('done')));

      await _insertTodo(db, id: 'unblocked', title: 'Now visible');
      await (db.update(db.todos)..where((t) => t.id.equals('unblocked'))).write(
        const TodosCompanion(
          state: Value('next_action'),
          blockedByTodoId: Value('blocker2'),
        ),
      );

      final items = await db.todoDao.watchNextActions(_userId).first;
      expect(items.where((t) => t.id == 'unblocked'), hasLength(1));
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

    test('clearBlockedBy removes blockedByTodoId', () async {
      await _insertTodo(db, id: 'u2', title: 'Blocked task');
      await (db.update(db.todos)..where((t) => t.id.equals('u2')))
          .write(const TodosCompanion(blockedByTodoId: Value('other')));

      await db.todoDao.updateFields('u2', _userId, clearBlockedBy: true);
      final row = await db.todoDao.getTodo('u2', _userId);
      expect(row?.blockedByTodoId, equals(null));
    });
  });
}
