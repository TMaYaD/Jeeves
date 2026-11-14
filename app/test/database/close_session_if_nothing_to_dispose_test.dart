import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';

import '../test_helpers.dart';

const _userId = 'local';

Future<void> _outcome(GtdDatabase db, String id, {bool done = false}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        intent: const Value('next'),
        userId: const Value(_userId),
        doneAt: Value(done ? now : null),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() => db = GtdDatabase(NativeDatabase.memory()));
  tearDown(() async => db.close());

  Future<bool> tryClose(String sessionId) => db.focusSessionDao
      .closeSessionIfNothingToDispose(sessionId: sessionId);

  Future<bool> isOpen() async =>
      await db.focusSessionDao.getActiveSession() != null;

  test('an empty Review surface closes', () async {
    final id = await db.focusSessionDao.openSession(userId: _userId, taskIds: []);
    expect(await tryClose(id), isTrue);
    expect(await isOpen(), isFalse);
  });

  test('every Outcome done, including an off-Plan one, closes', () async {
    await _outcome(db, 'plan', done: true);
    await _outcome(db, 'off', done: true);
    final id = await db.focusSessionDao
        .openSession(userId: _userId, taskIds: ['plan']);
    await db.focusSessionDao.setCurrentTask(sessionId: id, taskId: 'off');
    await db.focusSessionDao.setCurrentTask(sessionId: id, taskId: null);
    expect(await tryClose(id), isTrue);
    expect(await isOpen(), isFalse);
  });

  test('an unfinished Plan Outcome refuses and leaves the session open',
      () async {
    await _outcome(db, 'plan');
    final id = await db.focusSessionDao
        .openSession(userId: _userId, taskIds: ['plan']);
    expect(await tryClose(id), isFalse);
    expect(await isOpen(), isTrue);
  });

  test('an unfinished off-Plan Outcome refuses and leaves the session open',
      () async {
    await _outcome(db, 'plan', done: true);
    await _outcome(db, 'off');
    final id = await db.focusSessionDao
        .openSession(userId: _userId, taskIds: ['plan']);
    await db.focusSessionDao.setCurrentTask(sessionId: id, taskId: 'off');
    await db.focusSessionDao.setCurrentTask(sessionId: id, taskId: null);
    expect(await tryClose(id), isFalse);
    expect(await isOpen(), isTrue);
  });
}
