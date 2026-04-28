import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

const _userId = 'test-user';

TodosCompanion _companion({
  required String id,
  required String title,
  String? captureSource = 'manual',
}) {
  final now = DateTime.now();
  return TodosCompanion(
    id: Value(id),
    title: Value(title),
    captureSource: Value(captureSource),
    userId: Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  group('InboxDao', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('insertTodo sets clarified = false', () async {
      await db.inboxDao.insertTodo(_companion(id: 'a', title: 'Buy milk'));

      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items.length, 1);
      expect(items.first.clarified, isFalse);
    });

    test('insertTodo stores row visible in watchInbox', () async {
      await db.inboxDao.insertTodo(_companion(id: 'a', title: 'Buy milk'));

      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items.length, 1);
      expect(items.first.title, 'Buy milk');
    });

    test('duplicate id is rejected', () async {
      await db.inboxDao.insertTodo(_companion(id: 'dup', title: 'First'));
      expect(
        () => db.inboxDao.insertTodo(_companion(id: 'dup', title: 'Second')),
        throwsA(anything),
      );
    });

    test('watchInbox returns rows where clarified = false', () async {
      await db.inboxDao.insertTodo(_companion(id: 'a', title: 'Inbox item'));
      await db.inboxDao.insertTodo(_companion(id: 'b', title: 'Processed item'));
      // Process 'b' — sets clarified = true
      await db.inboxDao.processInboxItem('b', userId: _userId);

      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items.length, 1);
      expect(items.first.id, 'a');
    });

    test('watchInbox excludes rows where clarified = true', () async {
      await db.inboxDao.insertTodo(_companion(id: 'a', title: 'Item'));
      await db.inboxDao.processInboxItem('a', userId: _userId);

      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items, isEmpty);
    });

    test('processInboxItem sets clarified = true', () async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Process me'));
      await db.inboxDao.processInboxItem('x', userId: _userId);

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.clarified, isTrue);
    });

    test('processInboxItem removes row from inbox watch', () async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Process me'));
      await db.inboxDao.processInboxItem('x', userId: _userId);

      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items, isEmpty);
    });

    test('processInboxItem sets optional newState', () async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Process me'));
      await db.inboxDao
          .processInboxItem('x', userId: _userId, newState: 'next_action');

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.clarified, isTrue);
      expect(row.state, 'next_action');
    });

    test('processInboxItemToWaitingFor: sets clarified, state=next_action, and waiting_for column',
        () async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Process me'));
      // Mirrors what FocusSessionPlanningNotifier.processInboxItemToWaitingFor does.
      await db.inboxDao
          .processInboxItem('x', userId: _userId, newState: 'next_action');
      await db.todoDao.setWaitingFor('x', _userId, 'Alice');

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.clarified, isTrue);
      expect(row.state, 'next_action');
      expect(row.waitingFor, 'Alice');
    });

    test('deleteTodo removes row from inbox watch', () async {
      await db.inboxDao.insertTodo(_companion(id: 'del', title: 'Delete me'));
      await db.inboxDao.deleteTodo('del', userId: _userId);

      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items, isEmpty);
    });

    test('watchInbox returns newest first', () async {
      final earlier = DateTime(2024, 1, 1);
      final later = DateTime(2024, 6, 1);

      await db.inboxDao.insertTodo(TodosCompanion(
        id: const Value('old'),
        title: const Value('Old'),
        userId: Value(_userId),
        createdAt: Value(earlier),
        updatedAt: Value(earlier),
      ));
      await db.inboxDao.insertTodo(TodosCompanion(
        id: const Value('new'),
        title: const Value('New'),
        userId: Value(_userId),
        createdAt: Value(later),
        updatedAt: Value(later),
      ));

      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items.first.id, 'new');
      expect(items.last.id, 'old');
    });
  });
}
