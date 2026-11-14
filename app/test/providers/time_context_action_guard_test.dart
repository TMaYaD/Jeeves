/// A TimeContext edit lands only on the Action the editor was opened for (#238).
///
/// Asserted on the notifier over a real store, not through the open sheet: a
/// widget test cannot replace the Action while the peek's streams are live,
/// because a write from `runAsync` never returns while those reads wait on the
/// fake clock.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/providers/task_detail_provider.dart';

import '../test_helpers.dart';

const _userId = 'local';

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late TaskDetailNotifier notifier;

  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    await db.todoDao.insertOutcome(
        id: 't5', title: 'Ship the release', userId: _userId);
    await seedCurrentAction(db,
        outcomeId: 't5', text: 'do it', userId: _userId, id: 'old-action');
    notifier = TaskDetailNotifier(db: db, userId: _userId, todoId: 't5');
  });
  tearDown(() async => db.close());

  Future<TimeContext?> currentValue() async =>
      TimeContext.tryParse((await db.actionDao.getCurrentAction('t5'))!
          .timeContext);

  Future<void> replaceWithSuccessor() => db.actionDao.supersedeCurrentAction(
      't5', newActionText: 'the successor');

  test('Save after the Action was replaced leaves the successor alone',
      () async {
    await replaceWithSuccessor();
    final wrote = await notifier.setTimeContext(
        TimeContext.create(days: {2}), actionId: 'old-action');

    expect(wrote, isTrue, reason: 'the Outcome is still present');
    expect(await currentValue(), isNull);
  });

  test('Clear after the Action was replaced leaves the successor alone',
      () async {
    await replaceWithSuccessor();
    final successor = (await db.actionDao.getCurrentAction('t5'))!;
    await db.actionDao.setTimeContext(successor.id, TimeContext.create(days: {1}));

    await notifier.setTimeContext(null, actionId: 'old-action');

    expect(await currentValue(), TimeContext.create(days: {1}));
  });

  test('Save on the still-current Action writes it', () async {
    await notifier.setTimeContext(TimeContext.create(days: {2}),
        actionId: 'old-action');
    expect(await currentValue(), TimeContext.create(days: {2}));
  });
}
