/// Stopping an Action at its Timeboxed limit (issue #49).
///
/// The stop is a closing that is neither a completion nor a replacement: the
/// Action keeps the time it logged, gains the stopped-at-the-limit mark, and no
/// successor inherits it. These tests pin the write itself, the replay, the
/// stale-current refusal, and the way the Outcome's history reads it back —
/// and the rule that the stop rides the verdict's own write, so a verdict
/// that fails to land leaves the Action current.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/action_dao.dart' show ActionDao;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/routing_kind.dart';

import '../test_helpers.dart';

const _userId = 'test-user';
final _t0 = DateTime.parse('2026-07-01T09:00:00.000Z');
final _t1 = DateTime.parse('2026-07-01T10:00:00.000Z');
final _t2 = DateTime.parse('2026-07-01T11:00:00.000Z');
/// 25 minutes after [_t1]: the time the seeded Action logged.
final _t1_25 = DateTime.parse('2026-07-01T10:25:00.000Z');

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

/// An Outcome with a current Action, its estimate, and 25 minutes logged.
Future<void> _seed(
  GtdDatabase db, {
  String outcomeId = 'o1',
  String actionId = 'a1',
  int? timeEstimate = 30,
}) async {
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(outcomeId),
        title: Value('Outcome $outcomeId'),
        userId: const Value(_userId),
        intent: const Value('next'),
        createdAt: Value(_t0),
        updatedAt: Value(_t0),
      ));
  await db.into(db.actions).insert(ActionsCompanion(
        id: Value(actionId),
        outcomeId: Value(outcomeId),
        userId: const Value(_userId),
        actionText: const Value('Draft the work'),
        role: const Value('current'),
        timeEstimate: Value(timeEstimate),
        createdAt: Value(_t1),
        updatedAt: Value(_t1),
      ));
  // 25 minutes of work, logged and closed: the Action's time is kept.
  await db.into(db.timeLogs).insert(TimeLogsCompanion(
        id: Value('log-1'),
        taskId: Value(outcomeId),
        actionId: Value(actionId),
        userId: const Value(_userId),
        startedAt: Value(_t1.toIso8601String()),
        endedAt: Value(_t1_25.toIso8601String()),
      ));
}

Future<Action?> _action(GtdDatabase db, String id) async {
  final row = await (db.select(db.actions)..where((a) => a.id.equals(id)))
      .getSingleOrNull();
  return row;
}

/// The rows of the `actions` table, read raw so a missing column cannot hide.
Future<List<Map<String, Object?>>> _actionRows(
  GtdDatabase db,
  String outcomeId,
) async {
  final rows = await db.customSelect(
    'SELECT * FROM actions WHERE outcome_id = ?',
    variables: [Variable.withString(outcomeId)],
  ).get();
  return rows.map((row) => row.data).toList();
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() => db = _openInMemory());
  tearDown(() async => db.close());

  test('the stop closes the Action at its limit and keeps its logged time',
      () async {
    await _seed(db);

    await db.actionDao.stopCurrentActionAtLimit(
      'o1',
      expectedActionId: 'a1',
      now: _t2,
    );

    final action = await _action(db, 'a1');
    expect(action, isNotNull);
    // Superseded, not done: the approach ran out of time and the user said so.
    expect(action!.role, 'superseded');
    expect(action.stoppedAtLimitAt, isNotNull);
    expect(action.stoppedAtLimitAt!.toUtc(), _t2);
    // The time it logged is still its own.
    final history = await db.actionDao.getTerminatedActions('o1');
    expect(history.map((e) => e.loggedMinutes), [25]);
    expect(history.single.action.id, 'a1');
  });

  test('the mark alone does not make an Action stopped', () async {
    await _seed(db);
    // A row carrying the mark but still live: the mark has arrived, the role
    // has not. The read rule needs both.
    await db.customStatement(
      'UPDATE actions SET stopped_at_limit_at = ? WHERE id = ?',
      [_t2.toIso8601String(), 'a1'],
    );

    final action = await _action(db, 'a1');
    expect(ActionDao.isStoppedAtLimit(action!), isFalse);
  });

  test('a replay stops nothing', () async {
    await _seed(db);
    await db.actionDao.stopCurrentActionAtLimit(
      'o1',
      expectedActionId: 'a1',
      now: _t2,
    );

    // The same call again: the Action is already terminal, so there is nothing
    // to stop and the mark does not move.
    await db.actionDao.stopCurrentActionAtLimit(
      'o1',
      expectedActionId: 'a1',
      now: _t2.add(const Duration(hours: 1)),
    );

    final action = await _action(db, 'a1');
    expect(action!.stoppedAtLimitAt!.toUtc(), _t2);
  });

  test('a current Action that changed under the sheet is refused', () async {
    await _seed(db);
    // Sync swapped the current Action while the sheet was open.
    await db.customStatement(
      'UPDATE actions SET role = ? WHERE id = ?',
      ['superseded', 'a1'],
    );
    await db.into(db.actions).insert(ActionsCompanion(
          id: const Value('a2'),
          outcomeId: const Value('o1'),
          userId: const Value(_userId),
          actionText: const Value('Something else'),
          role: const Value('current'),
          createdAt: Value(_t2),
          updatedAt: Value(_t2),
        ));

    expect(
      () => db.actionDao.stopCurrentActionAtLimit(
        'o1',
        expectedActionId: 'a1',
        now: _t2,
      ),
      throwsStateError,
    );

    // The Action the user saw is untouched, and so is the one that replaced it.
    expect((await _action(db, 'a1'))!.stoppedAtLimitAt, isNull);
    expect((await _action(db, 'a2'))!.stoppedAtLimitAt, isNull);
  });

  test('the stop rides the verdict\'s own write', () async {
    await _seed(db);

    final landed = await db.todoDao.applyRouting(
      'o1',
      to: RoutingKind.nextAction,
      actionText: 'Carry on with the summary',
      stopAtLimitActionId: 'a1',
      now: _t2,
    );

    expect(landed, isTrue);
    // The Action is closed at its limit…
    final stopped = await _action(db, 'a1');
    expect(stopped!.role, 'superseded');
    expect(stopped.stoppedAtLimitAt, isNotNull);
    // …and the Outcome change landed with it.
    final todo = await db.todoDao.getTodo('o1');
    expect(todo!.intent, 'next');
    expect(todo.lastClarifiedAt, isNotNull);
    // The new Action is the Outcome's current one.
    final current = await db.actionDao.getCurrentAction('o1');
    expect(current!.actionText, 'Carry on with the summary');
  });

  test('a verdict that fails to land leaves the Action current', () async {
    await _seed(db);
    await db.into(db.actions).insert(ActionsCompanion(
          id: const Value('p1'),
          outcomeId: const Value('o1'),
          userId: const Value(_userId),
          actionText: const Value('Planned action'),
          role: const Value('planned'),
          createdAt: Value(_t1),
          updatedAt: Value(_t1),
        ));

    // The promoted Action vanished on another device: the route lands nothing,
    // and the stop must not have landed either.
    await db.customStatement('DELETE FROM actions WHERE id = ?', ['p1']);

    final landed = await db.todoDao.applyRouting(
      'o1',
      to: RoutingKind.nextAction,
      promotePlannedActionId: 'p1',
      stopAtLimitActionId: 'a1',
      now: _t2,
    );

    expect(landed, isFalse);
    final action = await _action(db, 'a1');
    expect(action!.role, 'current');
    expect(action.stoppedAtLimitAt, isNull);
  });

  test('the stop is refused alongside a replacing current Action', () async {
    await _seed(db);

    expect(
      () => db.todoDao.applyRouting(
        'o1',
        to: RoutingKind.nextAction,
        promotePlannedActionId: 'p1',
        replacingCurrentActionId: 'a1',
        stopAtLimitActionId: 'a1',
      ),
      throwsArgumentError,
    );
  });

  test('the stop is refused for trash', () async {
    await _seed(db);

    expect(
      () => db.todoDao.applyRouting(
        'o1',
        to: RoutingKind.trash,
        stopAtLimitActionId: 'a1',
      ),
      throwsArgumentError,
    );
  });

  test('the Outcome\'s history reads the stopped Action back', () async {
    await _seed(db);
    await db.actionDao.stopCurrentActionAtLimit(
      'o1',
      expectedActionId: 'a1',
      now: _t2,
    );

    final history = await db.actionDao.getTerminatedActions('o1');
    expect(history, hasLength(1));
    final entry = history.single;
    expect(entry.action.id, 'a1');
    expect(entry.action.stoppedAtLimitAt, isNotNull);
    expect(entry.loggedMinutes, 25);
  });

  test('the stopped row keeps its own estimate', () async {
    await _seed(db, timeEstimate: 30);
    await db.actionDao.stopCurrentActionAtLimit(
      'o1',
      expectedActionId: 'a1',
      now: _t2,
    );

    final rows = await _actionRows(db, 'o1');
    expect(rows.single['time_estimate'], 30);
  });
}
