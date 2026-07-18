/// Tests for the local-only Inbox carve-out (issue #184 Phase 2).
///
/// A signed-in user's Inbox is moved out of `todos` server-side by Alembic
/// 0026 and arrives via sync. A user who has never signed in has no server, so
/// [carveOutLocalInbox] does the same move on-device. Without it their entire
/// Inbox would vanish the moment the UI started reading `captures`.
///
/// These drive the production SQL against a real SQLite database — PowerSync
/// only supplies the surrounding transaction, so the statements are what needs
/// covering.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/services/migration_service.dart';
import '../test_helpers.dart';

const _userId = 'local';

/// Runs the carve-out against [db], wiring the read/write pair to Drift.
Future<int> _carve(GtdDatabase db, {String userId = _userId}) => db.transaction(
      () => carveOutLocalInbox(
        query: (sql, args) async {
          final rows = await db
              .customSelect(
                sql,
                variables: [for (final a in args) Variable<String>(a as String?)],
              )
              .get();
          return [for (final r in rows) r.data];
        },
        exec: (sql, args) => db.customStatement(sql, args),
        userId: userId,
      ),
    );

Future<void> _insertTodo(
  GtdDatabase db, {
  required String id,
  required String title,
  String? notes,
  bool clarified = false,
  String userId = _userId,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        notes: Value(notes),
        clarified: Value(clarified),
        captureSource: const Value('manual'),
        userId: Value(userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() => db = GtdDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('an unclarified todo becomes an Inbox Capture, keeping its id',
      () async {
    await _insertTodo(db, id: 't1', title: 'Buy milk', notes: 'Full fat');

    expect(await _carve(db), 1);

    final capture = await db.captureDao.getCapture('t1');
    expect(capture, isNotNull);
    expect(capture!.title, 'Buy milk');
    expect(capture.notes, 'Full fat');
    expect(capture.captureSource, 'manual');
    // Still in the Inbox — the move must not clarify anything.
    expect(capture.clarifiedAt, isNull);
    expect(await db.captureDao.watchInbox().first, hasLength(1));

    // And the original is gone, so the item isn't in both halves at once.
    expect(await db.todoDao.getTodo('t1'), isNull);
  });

  test('a clarified todo is left alone', () async {
    await _insertTodo(db, id: 't1', title: 'Already an Outcome', clarified: true);

    expect(await _carve(db), 0);

    expect(await db.captureDao.getCapture('t1'), isNull);
    expect(await db.todoDao.getTodo('t1'), isNotNull,
        reason: 'clarified rows are Outcomes and stay in todos');
  });

  test('todo_tags become capture_tags hints, and the originals are removed',
      () async {
    await _insertTodo(db, id: 't1', title: 'Call plumber');
    final tagId = await db.tagDao.findOrCreateTag('errands', 'context', _userId);
    await db.tagDao.assignTag('t1', tagId, _userId);

    expect(await _carve(db), 1);

    expect(await db.captureDao.tagHintIdsForCapture('t1'), {tagId});
    final leftoverLinks = await (db.select(db.todoTags)
          ..where((t) => t.todoId.equals('t1')))
        .get();
    expect(leftoverLinks, isEmpty);
    // The tag itself is shared vocabulary and must survive the move.
    expect(await db.tagDao.watchByType('context').first, hasLength(1));
  });

  test('another user\'s rows are untouched', () async {
    await _insertTodo(db, id: 'mine', title: 'Local item');
    await _insertTodo(db, id: 'theirs', title: 'Synced item', userId: 'user-42');

    expect(await _carve(db), 1);

    expect(await db.captureDao.getCapture('mine'), isNotNull);
    expect(await db.captureDao.getCapture('theirs'), isNull);
    expect(await db.todoDao.getTodo('theirs'), isNotNull);
  });

  test('a second run is a no-op', () async {
    await _insertTodo(db, id: 't1', title: 'Buy milk');

    expect(await _carve(db), 1);
    // Re-running on every launch must not duplicate or re-clarify anything.
    expect(await _carve(db), 0);

    expect(await db.select(db.captures).get(), hasLength(1));
    expect(await db.captureDao.watchInbox().first, hasLength(1));
    expect(await db.todoDao.getTodo('t1'), isNull);
  });

  test('a partially-carved row is finished, not stranded', () async {
    // Mirrors a half-applied run: the Capture exists but the todo row and its
    // tags were not yet moved. The retry must finish the job — skipping the
    // row (as a NOT EXISTS guard would) leaves the item in both halves of the
    // split forever.
    await _insertTodo(db, id: 't1', title: 'Buy milk');
    final tagId = await db.tagDao.findOrCreateTag('errands', 'context', _userId);
    await db.tagDao.assignTag('t1', tagId, _userId);
    final now = DateTime.now();
    await db.captureDao.insertCapture(CapturesCompanion(
      id: const Value('t1'),
      title: const Value('Buy milk'),
      userId: const Value(_userId),
      createdAt: Value(now),
      updatedAt: Value(now),
    ));

    expect(await _carve(db), 1);

    // Exactly one Capture (the insert is OR IGNORE, so no collision), its tag
    // hint now copied, and the leftover original cleared.
    expect(await db.select(db.captures).get(), hasLength(1));
    expect(await db.captureDao.tagHintIdsForCapture('t1'), {tagId});
    expect(await db.todoDao.getTodo('t1'), isNull,
        reason: 'the leftover original must not survive as a duplicate Inbox '
            'representation');
  });

  test('an empty inbox carves nothing', () async {
    expect(await _carve(db), 0);
    expect(await db.select(db.captures).get(), isEmpty);
  });
}
