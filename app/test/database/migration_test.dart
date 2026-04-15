import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase.forTesting(NativeDatabase.memory());

const _userId = 'test-user';

void main() {
  setUpAll(configureSqliteForTests);

  group('Schema migration', () {
    test('v2 schema: timeSpentMinutes defaults to 0 when not supplied', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      // Insert without specifying the new columns (they use DB defaults).
      final now = DateTime.now();
      await db.inboxDao.insertTodo(TodosCompanion(
        id: const Value('a'),
        title: const Value('Test task'),
        userId: Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));

      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items.length, 1);
      expect(items.first.timeSpentMinutes, 0);
      expect(items.first.inProgressSince, equals(null));
      expect(items.first.blockedByTodoId, equals(null));
    });

    test('v2 schema: inProgressSince and blockedByTodoId can be set', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      final now = DateTime.now();
      final nowIso = now.toIso8601String();
      await db.customInsert(
        'INSERT INTO todos (id, title, state, user_id, created_at, '
        'in_progress_since, time_spent_minutes, blocked_by_todo_id) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('b'),
          Variable.withString('Blocked task'),
          Variable.withString('next_action'),
          Variable.withString(_userId),
          Variable.withDateTime(now),
          Variable.withString(nowIso),
          Variable.withInt(15),
          Variable.withString('other-id'),
        ],
      );

      final todos = await (db.select(db.todos)
            ..where((t) => t.id.equals('b')))
          .get();
      expect(todos.length, 1);
      expect(todos.first.inProgressSince, nowIso);
      expect(todos.first.timeSpentMinutes, 15);
      expect(todos.first.blockedByTodoId, 'other-id');
    });

    test('v2 schema: old data (no new columns) survives intact', () async {
      final db = _openInMemory();
      addTearDown(db.close);

      final now = DateTime.now();
      // Insert a row simulating "pre-v2" data by omitting the new columns.
      await db.customInsert(
        'INSERT INTO todos (id, title, state, user_id, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('legacy'),
          Variable.withString('Legacy task'),
          Variable.withString('inbox'),
          Variable.withString(_userId),
          Variable.withDateTime(now),
          Variable.withDateTime(now),
        ],
      );

      final items = await db.inboxDao.watchInbox(_userId).first;
      expect(items.length, 1);
      expect(items.first.title, 'Legacy task');
      expect(items.first.timeSpentMinutes, 0);
      expect(items.first.inProgressSince, equals(null));
      expect(items.first.blockedByTodoId, equals(null));
    });
  });
}
