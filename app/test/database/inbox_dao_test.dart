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

      final items = await db.inboxDao.watchInbox().first;
      expect(items.length, 1);
      expect(items.first.clarified, isFalse);
    });

    test('insertTodo stores row visible in watchInbox', () async {
      await db.inboxDao.insertTodo(_companion(id: 'a', title: 'Buy milk'));

      final items = await db.inboxDao.watchInbox().first;
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
      await db.inboxDao.processInboxItem('b');

      final items = await db.inboxDao.watchInbox().first;
      expect(items.length, 1);
      expect(items.first.id, 'a');
    });

    test('watchInbox excludes rows where clarified = true', () async {
      await db.inboxDao.insertTodo(_companion(id: 'a', title: 'Item'));
      await db.inboxDao.processInboxItem('a');

      final items = await db.inboxDao.watchInbox().first;
      expect(items, isEmpty);
    });

    test('processInboxItem sets clarified = true', () async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Process me'));
      await db.inboxDao.processInboxItem('x');

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.clarified, isTrue);
    });

    test('processInboxItem removes row from inbox watch', () async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Process me'));
      await db.inboxDao.processInboxItem('x');

      final items = await db.inboxDao.watchInbox().first;
      expect(items, isEmpty);
    });

    test('processInboxItem then assign person tag: clarified + person tag linked',
        () async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Process me'));
      await db.inboxDao.processInboxItem('x');
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('alice-tag'),
        name: Value('Alice'),
        type: Value('person'),
        userId: Value(_userId),
      ));
      await db.tagDao.assignTag('x', 'alice-tag', _userId);

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.clarified, isTrue);

      final links = await (db.select(db.todoTags)
            ..where((tt) => tt.todoId.equals('x') & tt.tagId.equals('alice-tag')))
          .get();
      expect(links.length, 1);
    });

    test('deleteTodo removes row from inbox watch', () async {
      await db.inboxDao.insertTodo(_companion(id: 'del', title: 'Delete me'));
      await db.inboxDao.deleteTodo('del');

      final items = await db.inboxDao.watchInbox().first;
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

      final items = await db.inboxDao.watchInbox().first;
      expect(items.first.id, 'new');
      expect(items.last.id, 'old');
    });
  });
}
