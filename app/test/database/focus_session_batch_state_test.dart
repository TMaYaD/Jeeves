/// The small-task suggestion state on the open session's Plan entries
/// (issue #407): an accepted batch and a "Not today".
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

const _userId = 'test-user';

Future<void> _insertTodo(GtdDatabase db, String id) async {
  final now = DateTime.utc(2026, 11, 16, 8);
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late String sessionId;

  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    for (final id in ['a', 'b', 'c']) {
      await _insertTodo(db, id);
    }
    sessionId = await db.focusSessionDao
        .openSession(userId: _userId, taskIds: ['a', 'b', 'c']);
  });
  tearDown(() async => db.close());

  test('an entry that was never batched or declined is absent', () async {
    expect(await db.focusSessionDao.watchActiveSessionBatchState().first,
        isEmpty);
  });

  test('an accepted batch and a declined entry are reported, others are not',
      () async {
    await db.focusSessionDao.acceptBatch(
      sessionId: sessionId,
      batchId: 'batch-1',
      startByTaskId: {
        'a': DateTime.utc(2026, 11, 16, 10),
        'b': DateTime.utc(2026, 11, 16, 10, 10),
      },
    );
    await db.focusSessionDao.declineBatchSuggestion(
      sessionId: sessionId,
      taskIds: ['c'],
      declinedAt: DateTime.utc(2026, 11, 16, 9),
    );

    final state =
        await db.focusSessionDao.watchActiveSessionBatchState().first;
    expect(state.keys.toSet(), {'a', 'b', 'c'});
    expect(state['a'], (batchId: 'batch-1', declined: false));
    expect(state['b'], (batchId: 'batch-1', declined: false));
    expect(state['c'], (batchId: null, declined: true));
  });

  test('accepting stores each member\'s start time with the batch', () async {
    await db.focusSessionDao.acceptBatch(
      sessionId: sessionId,
      batchId: 'batch-1',
      startByTaskId: {'a': DateTime.utc(2026, 11, 16, 10)},
    );
    final pins =
        await db.focusSessionDao.watchActiveSessionPinnedStarts().first;
    expect(pins, {'a': DateTime.utc(2026, 11, 16, 10)});
  });

  test('moving a member through setPinnedStart takes it out of the batch',
      () async {
    await db.focusSessionDao.acceptBatch(
      sessionId: sessionId,
      batchId: 'batch-1',
      startByTaskId: {
        'a': DateTime.utc(2026, 11, 16, 10),
        'b': DateTime.utc(2026, 11, 16, 10, 10),
      },
    );
    await db.focusSessionDao.setPinnedStart(
      sessionId: sessionId,
      taskId: 'b',
      pinnedStartAt: DateTime.utc(2026, 11, 16, 15),
    );
    final state =
        await db.focusSessionDao.watchActiveSessionBatchState().first;
    expect(state.keys.toSet(), {'a'});
  });

  test('the state ends with the session', () async {
    await db.focusSessionDao.declineBatchSuggestion(
      sessionId: sessionId,
      taskIds: ['a'],
      declinedAt: DateTime.utc(2026, 11, 16, 9),
    );
    await db.focusSessionDao.closeSession(sessionId: sessionId);
    expect(await db.focusSessionDao.watchActiveSessionBatchState().first,
        isEmpty);
  });
}
