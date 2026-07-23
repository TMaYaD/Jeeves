import 'package:drift/drift.dart' hide isNull, isNotNull;
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

  // The todos-based inbox (watchInbox/insertTodo/deleteTodo) is superseded by
  // the Capture inbox (ADR-0006); processInboxItem is InboxDao's only live
  // production surface (via ClarificationService). insertTodo appears below
  // purely as a fixture helper.
  group('InboxDao', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('processInboxItem sets clarified = true and removes it from watchInbox',
        () async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Process me'));
      await db.inboxDao.processInboxItem('x');

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.clarified, isTrue);
      expect(await db.inboxDao.watchInbox().first, isEmpty);
    });

    test('processInboxItem stamps lastClarifiedAt', () async {
      // Promoting a Capture to a clarified Outcome IS Outcome creation
      // (ADR-0006: Capture is distinct from Outcome). Per CONTEXT.md ~L152
      // Outcome creation stamps last_clarified_at.
      await db.inboxDao.insertTodo(_companion(id: 'lc', title: 'Process me'));

      // Confirm freshly captured rows are unclarified-and-unstamped.
      final beforeRow =
          await (db.select(db.todos)..where((t) => t.id.equals('lc')))
              .getSingle();
      expect(beforeRow.lastClarifiedAt, isNull);

      await db.inboxDao.processInboxItem('lc');

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('lc')))
              .getSingle();
      expect(row.lastClarifiedAt, isNotNull);
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

  });
}
