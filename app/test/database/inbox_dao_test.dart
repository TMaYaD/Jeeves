import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/gtd_state_machine.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase.forTesting(NativeDatabase.memory());

const _userId = 'test-user';

TodosCompanion _companion({
  required String id,
  required String title,
  String state = 'inbox',
  String? captureSource = 'manual',
}) {
  final now = DateTime.now();
  return TodosCompanion(
    id: Value(id),
    title: Value(title),
    state: Value(state),
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

    test('insertTodo rejects non-inbox state', () async {
      expect(
        () => db.inboxDao.insertTodo(
          _companion(id: 'bad', title: 'Wrong state', state: 'next_action'),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('watchInbox filters out non-inbox states', () async {
      await db.inboxDao.insertTodo(_companion(id: 'a', title: 'Inbox item'));
      await db.inboxDao.insertTodo(_companion(id: 'b', title: 'Next action'));
      // Transition 'b' out of inbox — the real production path for non-inbox rows.
      await db.inboxDao
          .processInboxItem('b', userId: _userId, newState: 'next_action');

      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items.length, 1);
      expect(items.first.id, 'a');
    });

    test('processInboxItem removes row from inbox watch', () async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Process me'));
      await db.inboxDao
          .processInboxItem('x', userId: _userId, newState: 'next_action');

      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items, isEmpty);
    });

    test('deleteTodo removes row from inbox watch', () async {
      await db.inboxDao.insertTodo(_companion(id: 'del', title: 'Delete me'));
      await db.inboxDao.deleteTodo('del', userId: _userId);

      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items, isEmpty);
    });

    test('processInboxItem rejects invalid transition (inbox → inProgress)', () async {
      await db.inboxDao.insertTodo(_companion(id: 'bad', title: 'Bad transition'));
      await expectLater(
        db.inboxDao.processInboxItem(
            'bad', userId: _userId, newState: 'in_progress'),
        throwsA(isA<InvalidStateTransitionException>()),
      );
      // State must remain unchanged after the rejected transition.
      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items.any((t) => t.id == 'bad' && t.state == 'inbox'), isTrue);
    });

    test('processInboxItem rejects invalid transition (inbox → scheduled)', () async {
      await db.inboxDao.insertTodo(_companion(id: 'bad2', title: 'Also bad'));
      await expectLater(
        db.inboxDao.processInboxItem(
            'bad2', userId: _userId, newState: 'scheduled'),
        throwsA(isA<InvalidStateTransitionException>()),
      );
      // State must remain unchanged after the rejected transition.
      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items.any((t) => t.id == 'bad2' && t.state == 'inbox'), isTrue);
    });

    test('watchInbox returns newest first', () async {
      final earlier = DateTime(2024, 1, 1);
      final later = DateTime(2024, 6, 1);

      await db.inboxDao.insertTodo(TodosCompanion(
        id: const Value('old'),
        title: const Value('Old'),
        state: const Value('inbox'),
        userId: Value(_userId),
        createdAt: Value(earlier),
        updatedAt: Value(earlier),
      ));
      await db.inboxDao.insertTodo(TodosCompanion(
        id: const Value('new'),
        title: const Value('New'),
        state: const Value('inbox'),
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
