/// The limit status of a Timeboxed Action (issue #923).
///
/// The status is derived, never stored: the limit is the Action's estimate,
/// the instant it passed comes from the Action's TimeLogs, and the counts
/// come from the Sprints recorded against it. Asserted over a real store, so
/// the derivation is exercised against the same rows the app reads.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/timeboxed.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/timeboxed_limit_provider.dart';

import '../test_helpers.dart';

const _userId = 'local';
final _ts = DateTime.utc(2026, 11, 16, 9);

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    await db.todoDao.insertOutcome(
      id: 't1',
      title: 'Write the report',
      userId: _userId,
      now: _ts,
    );
    await db.actionDao
        .setCurrentAction('t1', 'Draft', timeEstimate: 30, now: _ts);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<String> actionId() async =>
      (await db.actionDao.getCurrentAction('t1'))!.id;

  Future<TimeboxedLimitStatus?> status() async =>
      container.read(timeboxedLimitStatusProvider('t1').future);

  test('an Action that is not Timeboxed has no status', () async {
    expect(await status(), isNull);
  });

  test('the switch with an estimate is a limit', () async {
    await db.actionDao.setTimeboxed(await actionId(), true, now: _ts);

    final current = await status();

    expect(current, isNotNull);
    expect(current!.limitMinutes, 30);
    expect(current.hasPassed, isFalse);
    expect(current.limitPassedAt, isNull);
    expect(current.minutesPast(_ts), 0);
    expect(current.sprintsBeforeLimit, 0);
    expect(current.sprintsPastLimit, 0);
  });

  test('the switch needs an estimate: a merged "estimate cleared" reads as off',
      () async {
    await db.actionDao.setTimeboxed(await actionId(), true, now: _ts);
    // Another device cleared the estimate; the switch survived the merge. A
    // limit of nothing is not a limit.
    await db.customStatement('UPDATE actions SET time_estimate = NULL');

    expect(await status(), isNull);
  });

  test('logged time past the estimate passes the limit', () async {
    await db.actionDao.setTimeboxed(await actionId(), true, now: _ts);
    await db.timeLogDao.openLog(taskId: 't1', userId: _userId, now: _ts);
    await db.timeLogDao.closeLog(
      taskId: 't1',
      now: _ts.add(const Duration(minutes: 45)),
    );

    final current = await status();

    expect(current!.hasPassed, isTrue);
    expect(current.limitPassedAt, _ts.add(const Duration(minutes: 30)));
    expect(current.minutesPast(_ts.add(const Duration(minutes: 52))), 22);
  });

  test('Sprints are counted on the side of the limit they started', () async {
    await db.actionDao.setTimeboxed(await actionId(), true, now: _ts);
    await db.timeLogDao.openLog(taskId: 't1', userId: _userId, now: _ts);
    await db.timeLogDao.closeLog(
      taskId: 't1',
      now: _ts.add(const Duration(minutes: 45)),
    );
    // The first Sprint started before the limit passed, the second after.
    await db.sprintDao.startSprint(
      taskId: 't1',
      userId: _userId,
      plannedDurationMinutes: 20,
      now: _ts.add(const Duration(minutes: 10)),
    );
    await db.sprintDao.startSprint(
      taskId: 't1',
      userId: _userId,
      plannedDurationMinutes: 20,
      now: _ts.add(const Duration(minutes: 40)),
    );

    final current = await status();

    expect(current!.sprintsBeforeLimit, 1);
    expect(current.sprintsPastLimit, 1);
    expect(current.sprintStarts, hasLength(2));
    expect(current.runningSprintPastLimitNumber, 1);
  });

  test('turning the switch off leaves no status behind', () async {
    final id = await actionId();
    await db.actionDao.setTimeboxed(id, true, now: _ts);
    expect(await status(), isNotNull);

    await db.actionDao.setTimeboxed(id, false, now: _ts);

    expect(await status(), isNull);
  });
}
