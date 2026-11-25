/// The current Action of an Outcome, with the text it carries and the time it
/// governs (issue #1073).
///
/// The rules under test: the text and the time come from one Action, a
/// successor does not inherit its predecessor's time, and a named window
/// governs the Time context beside it.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/models/time_window_hours.dart';

import '../test_helpers.dart';

const _userId = 'test-user';
final _ts = DateTime.utc(2026, 11, 24, 9);

final _storeHours = <int, DayHours>{
  for (var day = 1; day <= 5; day++)
    day: (startMinute: 11 * 60, endMinute: 20 * 60),
};

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = GtdDatabase(NativeDatabase.memory());
  });
  tearDown(() async => db.close());

  /// An Outcome with a current Action, optionally carrying a window and a Time
  /// context.
  Future<void> seedOutcome(
    String actionId, {
    String? windowId,
    String? timeContext,
  }) async {
    await db.into(db.todos).insert(TodosCompanion(
          id: Value('todo-$actionId'),
          title: Value('outcome $actionId'),
          userId: const Value(_userId),
          createdAt: Value(_ts),
          updatedAt: Value(_ts),
        ));
    await db.into(db.actions).insert(ActionsCompanion(
          id: Value(actionId),
          outcomeId: Value('todo-$actionId'),
          userId: const Value(_userId),
          actionText: Value('action $actionId'),
          role: const Value('current'),
          timeWindowId: Value(windowId),
          timeContext: Value(timeContext),
          createdAt: Value(_ts),
        ));
  }

  Future<String?> createWindow(String name) =>
      db.timeWindowDao.createTimeWindow(
        name: name,
        hours: _storeHours,
        userId: _userId,
        now: _ts,
      );

  test('the Action\'s text and its time come from one read', () async {
    final windowId = await createWindow('Store hours');
    await seedOutcome('a1', windowId: windowId);

    final actions = await db.actionDao.watchCurrentActions().first;

    expect(actions.keys, {'todo-a1'});
    expect(actions['todo-a1']!.actionText, 'action a1');
    expect(actions['todo-a1']!.timeWindow!.id, windowId);
    expect(actions['todo-a1']!.timeWindow!.name, 'Store hours');
    expect(actions['todo-a1']!.timeContext, isNull);
  });

  test('a successor does not inherit its predecessor\'s time', () async {
    final windowId = await createWindow('Store hours');
    await seedOutcome('a1', windowId: windowId);
    await seedPlannedAction(
      db,
      outcomeId: 'todo-a1',
      text: 'action a2',
      userId: _userId,
      id: 'a2',
      position: 0,
      now: _ts,
    );

    await db.actionDao.supersedeAndPromote('a2', now: _ts);

    final actions = await db.actionDao.watchCurrentActions().first;
    expect(actions['todo-a1']!.actionText, 'action a2');
    expect(actions['todo-a1']!.timeWindow, isNull);
    expect(actions['todo-a1']!.timeContext, isNull);
  });

  test('a window governs the Time context beside it', () async {
    final windowId = await createWindow('Store hours');
    await seedOutcome(
      'a1',
      windowId: windowId,
      timeContext:
          TimeContext.create(fromDate: DateTime(2030, 1, 1))!.encode(),
    );

    final actions = await db.actionDao.watchCurrentActions().first;

    expect(actions['todo-a1']!.timeWindow!.name, 'Store hours');
    expect(actions['todo-a1']!.timeContext, isNull);
  });

  test('a Time context alone is the Action\'s time', () async {
    await seedOutcome(
      'a1',
      timeContext:
          TimeContext.create(fromDate: DateTime(2030, 1, 1))!.encode(),
    );

    final actions = await db.actionDao.watchCurrentActions().first;

    expect(actions['todo-a1']!.timeWindow, isNull);
    expect(actions['todo-a1']!.timeContext!.fromDate, DateTime(2030, 1, 1));
  });

  test('an Outcome with no current Action is absent', () async {
    await db.into(db.todos).insert(TodosCompanion(
          id: const Value('todo-a1'),
          title: const Value('outcome a1'),
          userId: const Value(_userId),
          createdAt: Value(_ts),
          updatedAt: Value(_ts),
        ));

    final actions = await db.actionDao.watchCurrentActions().first;

    expect(actions, isEmpty);
  });
}
