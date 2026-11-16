/// The Timeboxed switch on an Action (issue #923).
///
/// One nullable boolean on the Action row: whether its estimate is a limit
/// rather than a guess. What is pinned here is the rule the switch obeys — it
/// belongs to the Action it was set on, it is cleared with the estimate it
/// belongs to, and a successor Action never inherits it.
@TestOn('!browser')
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';

import '../test_helpers.dart';

const _userId = 'local';
final _ts = DateTime.utc(2026, 11, 16, 9);

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    await db.todoDao.insertOutcome(
      id: 't1',
      title: 'Write the report',
      userId: _userId,
      now: _ts,
    );
    await db.todoDao.insertOutcome(
      id: 't2',
      title: 'Something else',
      userId: _userId,
      now: _ts,
    );
  });
  tearDown(() async => db.close());

  Future<String> currentActionId(String outcomeId) async =>
      (await db.actionDao.getCurrentAction(outcomeId))!.id;

  test('the switch is stored on the Action it was set on', () async {
    await db.actionDao.setCurrentAction('t1', 'Draft', now: _ts);
    final id = await currentActionId('t1');

    await db.actionDao.setTimeboxed(id, true, now: _ts);

    expect((await db.actionDao.getCurrentAction('t1'))!.timeboxed, isTrue);
  });

  test('turning the switch off stores false, not an absence', () async {
    await db.actionDao.setCurrentAction('t1', 'Draft', now: _ts);
    final id = await currentActionId('t1');
    await db.actionDao.setTimeboxed(id, true, now: _ts);

    await db.actionDao.setTimeboxed(id, false, now: _ts);

    expect((await db.actionDao.getCurrentAction('t1'))!.timeboxed, isFalse);
  });

  test('setting the same value again writes nothing', () async {
    await db.actionDao.setCurrentAction('t1', 'Draft', now: _ts);
    final id = await currentActionId('t1');
    await db.actionDao.setTimeboxed(id, true, now: _ts);

    // A later turn of the same switch is not a change: the row keeps its
    // stamp, so no needless op reaches the other device.
    await db.actionDao
        .setTimeboxed(id, true, now: _ts.add(const Duration(minutes: 5)));

    expect((await db.actionDao.getCurrentAction('t1'))!.updatedAt, _ts);
  });

  test('clearing the estimate clears the switch with it', () async {
    await db.actionDao.setCurrentAction('t1', 'Draft', timeEstimate: 30, now: _ts);
    final id = await currentActionId('t1');
    await db.actionDao.setTimeboxed(id, true, now: _ts);

    await db.actionDao.editAction(id, clearTimeEstimate: true, now: _ts);

    final action = (await db.actionDao.getCurrentAction('t1'))!;
    expect(action.timeEstimate, isNull);
    expect(action.timeboxed, isFalse);
  });

  test('a successor Action does not inherit the switch', () async {
    await db.actionDao.setCurrentAction('t1', 'Draft', timeEstimate: 30, now: _ts);
    final id = await currentActionId('t1');
    await db.actionDao.setTimeboxed(id, true, now: _ts);

    await db.actionDao.supersedeCurrentAction('t1', newActionText: 'The successor', now: _ts);

    final successor = (await db.actionDao.getCurrentAction('t1'))!;
    expect(successor.id, isNot(id));
    expect(successor.timeboxed, isNull);
  });

  test('the switch belongs to one Outcome only', () async {
    await db.actionDao.setCurrentAction('t1', 'Draft', now: _ts);
    await db.actionDao.setCurrentAction('t2', 'Other', now: _ts);
    final id = await currentActionId('t1');

    await db.actionDao.setTimeboxed(id, true, now: _ts);

    expect((await db.actionDao.getCurrentAction('t2'))!.timeboxed, isNull);
  });
}
