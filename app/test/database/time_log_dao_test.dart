import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/time_log_dao.dart' show TimeLogDao;
import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

const _userId = 'test-user';

Future<String> _insertTodo(
  GtdDatabase db, {
  required String id,
  required String title,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
    id: Value(id),
    title: Value(title),
    clarified: const Value(true),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
  return id;
}

void main() {
  setUpAll(configureSqliteForTests);

  group('TimeLogDao', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    // -------------------------------------------------------------------------
    // openLog
    // -------------------------------------------------------------------------

    test('openLog creates a row with correct fields', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      final ts = DateTime(2024, 1, 1, 10, 0, 0);
      await db.timeLogDao.openLog(taskId: 'task1', userId: _userId, now: ts);

      final logs = await db.select(db.timeLogs).get();
      expect(logs.length, 1);
      expect(logs.first.taskId, 'task1');
      expect(logs.first.userId, _userId);
      expect(logs.first.startedAt, ts.toUtc().toIso8601String());
      expect(logs.first.endedAt, isNull);
    });

    test('openLog with existing open log for same user closes it first',
        () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      await _insertTodo(db, id: 'task2', title: 'Task 2');
      final t1 = DateTime(2024, 1, 1, 9, 0, 0);
      final t2 = DateTime(2024, 1, 1, 9, 30, 0);
      await db.timeLogDao.openLog(taskId: 'task1', userId: _userId, now: t1);
      await db.timeLogDao.openLog(taskId: 'task2', userId: _userId, now: t2);

      final logs = await db.select(db.timeLogs).get();
      expect(logs.length, 2);
      final openLogs = logs.where((l) => l.endedAt == null).toList();
      expect(openLogs.length, 1);
      expect(openLogs.first.taskId, 'task2');
    });

    // -------------------------------------------------------------------------
    // closeLog
    // -------------------------------------------------------------------------

    test('closeLog sets ended_at on the open row', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      final start = DateTime(2024, 1, 1, 10, 0, 0);
      final end = start.add(const Duration(minutes: 5));
      await db.timeLogDao.openLog(taskId: 'task1', userId: _userId, now: start);
      await db.timeLogDao.closeLog(taskId: 'task1', now: end);

      final logs = await db.select(db.timeLogs).get();
      expect(logs.length, 1);
      expect(logs.first.endedAt, isNotNull);
      expect(logs.first.startedAt, start.toUtc().toIso8601String());
    });

    test('closeLog on task with no open row is a no-op', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      await db.timeLogDao.closeLog(taskId: 'task1');

      final logs = await db.select(db.timeLogs).get();
      expect(logs.length, 0);
    });

    // -------------------------------------------------------------------------
    // watchActiveLog
    // -------------------------------------------------------------------------

    test('watchActiveLog returns null when no open log', () async {
      final log = await db.timeLogDao.watchActiveLog().first;
      expect(log, isNull);
    });

    test('watchActiveLog returns the open log after openLog', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      await db.timeLogDao
          .openLog(taskId: 'task1', userId: _userId, now: DateTime.now());

      final log = await db.timeLogDao.watchActiveLog().first;
      expect(log, isNotNull);
      expect(log!.taskId, 'task1');
    });

    test('watchActiveLog returns null after closeLog', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      await db.timeLogDao
          .openLog(taskId: 'task1', userId: _userId, now: DateTime.now());
      await db.timeLogDao.closeLog(taskId: 'task1', now: DateTime.now());

      final log = await db.timeLogDao.watchActiveLog().first;
      expect(log, isNull);
    });

    // -------------------------------------------------------------------------
    // totalMinutesForTask
    // -------------------------------------------------------------------------

    test('totalMinutesForTask returns 0 with no logs', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      final total = await db.timeLogDao.totalMinutesForTask('task1');
      expect(total, 0);
    });

    test('totalMinutesForTask sums closed intervals', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      final base = DateTime(2024, 1, 1, 10, 0, 0).toUtc();
      // Stint 1: exactly 1 minute.
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('log1'),
            userId: const Value(_userId),
            taskId: const Value('task1'),
            startedAt: Value(base.toIso8601String()),
            endedAt: Value(
                base.add(const Duration(minutes: 1)).toIso8601String()),
          ));
      // Stint 2: exactly 2 minutes.
      final gap = base.add(const Duration(minutes: 5));
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('log2'),
            userId: const Value(_userId),
            taskId: const Value('task1'),
            startedAt: Value(gap.toIso8601String()),
            endedAt: Value(
                gap.add(const Duration(minutes: 2)).toIso8601String()),
          ));

      final total = await db.timeLogDao.totalMinutesForTask('task1');
      expect(total, 3); // 1 + 2
    });

    test('totalMinutesForTask applies ceiling rounding per interval', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      final base = DateTime(2024, 1, 1, 10, 0, 0).toUtc();
      // 95 seconds → ceil to 2 minutes.
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('log1'),
            userId: const Value(_userId),
            taskId: const Value('task1'),
            startedAt: Value(base.toIso8601String()),
            endedAt: Value(
                base.add(const Duration(seconds: 95)).toIso8601String()),
          ));

      final total = await db.timeLogDao.totalMinutesForTask('task1');
      expect(total, 2);
    });

    test('totalMinutesForTask includes open interval elapsed up to now',
        () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      // Open log started 2 minutes ago.
      final startedAt =
          DateTime.now().toUtc().subtract(const Duration(minutes: 2));
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('log1'),
            userId: const Value(_userId),
            taskId: const Value('task1'),
            startedAt: Value(startedAt.toIso8601String()),
          ));

      final total = await db.timeLogDao.totalMinutesForTask('task1');
      expect(total, greaterThanOrEqualTo(2));
    });

    test('totalMinutesForTask is scoped to task_id', () async {
      await _insertTodo(db, id: 'taskA', title: 'Task A');
      await _insertTodo(db, id: 'taskB', title: 'Task B');
      final base = DateTime(2024, 1, 1, 10, 0, 0).toUtc();
      // taskA: 1 minute.
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('logA'),
            userId: const Value(_userId),
            taskId: const Value('taskA'),
            startedAt: Value(base.toIso8601String()),
            endedAt: Value(
                base.add(const Duration(minutes: 1)).toIso8601String()),
          ));
      // taskB: 5 minutes — must not bleed into taskA's total.
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('logB'),
            userId: const Value(_userId),
            taskId: const Value('taskB'),
            startedAt: Value(base.toIso8601String()),
            endedAt: Value(
                base.add(const Duration(minutes: 5)).toIso8601String()),
          ));

      final totalA = await db.timeLogDao.totalMinutesForTask('taskA');
      expect(totalA, 1);
    });

    // -------------------------------------------------------------------------
    // Action-grain attribution (issue #476)
    // -------------------------------------------------------------------------

    test('openLog stamps the current Action id', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      await db.actionDao.setCurrentAction('task1', 'do the thing');
      final current = await db.actionDao.getCurrentAction('task1');

      await db.timeLogDao
          .openLog(taskId: 'task1', userId: _userId, now: DateTime.now());

      final logs = await db.select(db.timeLogs).get();
      expect(logs.length, 1);
      expect(logs.first.actionId, current!.id);
    });

    test('openLog on an Actionless Outcome leaves action_id NULL', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      // No current Action exists.
      await db.timeLogDao
          .openLog(taskId: 'task1', userId: _userId, now: DateTime.now());

      final logs = await db.select(db.timeLogs).get();
      expect(logs.first.actionId, isNull);
    });

    test('openLog never attributes to a planned or terminated Action',
        () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      // A planned row and a superseded (terminated) row — but no current.
      await db.actionDao.addPlannedAction('task1', 'later step');
      await db.actionDao.setCurrentAction('task1', 'first step');
      await db.actionDao.clearCurrentAction('task1'); // supersede → no current

      await db.timeLogDao
          .openLog(taskId: 'task1', userId: _userId, now: DateTime.now());

      final logs = await db.select(db.timeLogs).get();
      // Resolver filters role='current': planned/terminated can never attach.
      expect(logs.first.actionId, isNull);
    });

    test('openLog does not stamp last_clarified_at', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      await db.actionDao.setCurrentAction('task1', 'do the thing');
      final before = (await (db.select(db.todos)
                ..where((t) => t.id.equals('task1')))
              .getSingle())
          .lastClarifiedAt;

      await db.timeLogDao.openLog(
          taskId: 'task1',
          userId: _userId,
          now: DateTime.now().add(const Duration(hours: 1)));

      final after = (await (db.select(db.todos)
                ..where((t) => t.id.equals('task1')))
              .getSingle())
          .lastClarifiedAt;
      expect(after, before);
    });

    // -------------------------------------------------------------------------
    // Legacy ∪ new equivalence (issue #476): totals are task-grain, so a store
    // mixing NULL-action legacy rows and action-attributed rows sums identically
    // whether or not attribution exists.
    // -------------------------------------------------------------------------

    test('totalMinutesForTask is identical for legacy and action-attributed rows',
        () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      await db.actionDao.setCurrentAction('task1', 'do the thing');
      final current = await db.actionDao.getCurrentAction('task1');
      final base = DateTime(2024, 1, 1, 10, 0, 0).toUtc();

      // Legacy closed stint: 3 minutes, action_id NULL.
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('legacy'),
            userId: const Value(_userId),
            taskId: const Value('task1'),
            startedAt: Value(base.toIso8601String()),
            endedAt:
                Value(base.add(const Duration(minutes: 3)).toIso8601String()),
          ));
      // New closed stint: 4 minutes, action-attributed. Non-straddling so the
      // per-row ceil cannot add a stray minute.
      final gap = base.add(const Duration(minutes: 10));
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('attributed'),
            userId: const Value(_userId),
            taskId: const Value('task1'),
            actionId: Value(current!.id),
            startedAt: Value(gap.toIso8601String()),
            endedAt:
                Value(gap.add(const Duration(minutes: 4)).toIso8601String()),
          ));

      // The task-grain total counts both rows regardless of action attribution.
      final total = await db.timeLogDao.totalMinutesForTask('task1');
      expect(total, 7); // 3 (legacy) + 4 (attributed)
    });

    // -------------------------------------------------------------------------
    // Action-grain derivation (issue #478): the same arithmetic on
    // `action_id`, so a history row can show what that one Action cost.
    // -------------------------------------------------------------------------

    group('totalMinutesSubqueryForAction', () {
      Future<int> minutesFor(GtdDatabase db, String actionId) async {
        final row = await db.customSelect(
          'SELECT ${TimeLogDao.totalMinutesSubqueryForAction('?')} AS m',
          variables: [Variable<String>(actionId)],
          readsFrom: {db.timeLogs},
        ).getSingle();
        return row.read<int>('m');
      }

      test('sums closed logs for one Action and excludes every other row',
          () async {
        await _insertTodo(db, id: 'task1', title: 'Task 1');
        final base = DateTime(2024, 1, 1, 10, 0, 0).toUtc();

        Future<void> log(String id, String? actionId, int minutes,
            {int offsetMinutes = 0}) async {
          final started = base.add(Duration(minutes: offsetMinutes));
          await db.into(db.timeLogs).insert(TimeLogsCompanion(
                id: Value(id),
                userId: const Value(_userId),
                taskId: const Value('task1'),
                actionId: Value(actionId),
                startedAt: Value(started.toIso8601String()),
                endedAt: Value(started
                    .add(Duration(minutes: minutes))
                    .toIso8601String()),
              ));
        }

        await log('mine-a', 'act-1', 3);
        await log('mine-b', 'act-1', 4, offsetMinutes: 10);
        await log('foreign', 'act-2', 50, offsetMinutes: 30);
        await log('legacy', null, 99, offsetMinutes: 90);

        expect(await minutesFor(db, 'act-1'), 7,
            reason: 'only this Action\'s own stints count');
        expect(await minutesFor(db, 'act-2'), 50);
      });

      test('is 0 for an Action with no logs', () async {
        await _insertTodo(db, id: 'task1', title: 'Task 1');
        expect(await minutesFor(db, 'act-none'), 0);
      });
    });
  });
}
