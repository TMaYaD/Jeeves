import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

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
  await db.inboxDao.insertTodo(TodosCompanion(
    id: Value(id),
    title: Value(title),
    state: const Value('inbox'),
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
      final log = await db.timeLogDao.watchActiveLog(_userId).first;
      expect(log, isNull);
    });

    test('watchActiveLog returns the open log after openLog', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      await db.timeLogDao
          .openLog(taskId: 'task1', userId: _userId, now: DateTime.now());

      final log = await db.timeLogDao.watchActiveLog(_userId).first;
      expect(log, isNotNull);
      expect(log!.taskId, 'task1');
    });

    test('watchActiveLog returns null after closeLog', () async {
      await _insertTodo(db, id: 'task1', title: 'Task 1');
      await db.timeLogDao
          .openLog(taskId: 'task1', userId: _userId, now: DateTime.now());
      await db.timeLogDao.closeLog(taskId: 'task1', now: DateTime.now());

      final log = await db.timeLogDao.watchActiveLog(_userId).first;
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
  });
}
