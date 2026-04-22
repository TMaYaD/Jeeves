import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart';
import '../test_helpers.dart';

const _uid = 'user-1';
const _today = '2025-01-15';
const _tomorrow = '2025-01-16';

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  var taskSeq = 0;

  setUp(() {
    db = GtdDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<String> insertTask({
    required String state,
    bool? selectedForToday,
    String? dailySelectionDate,
    int timeEstimate = 0,
    int timeSpentMinutes = 0,
    String? inProgressSince,
  }) async {
    final id = 'task-${taskSeq++}';
    final now = DateTime.now();
    await db.into(db.todos).insert(TodosCompanion(
      id: Value(id),
      title: Value('Task $id'),
      state: Value(state),
      userId: Value(_uid),
      createdAt: Value(now),
      updatedAt: Value(now),
      selectedForToday: Value(selectedForToday),
      dailySelectionDate: Value(dailySelectionDate),
      timeEstimate: Value(timeEstimate > 0 ? timeEstimate : null),
      timeSpentMinutes: Value(timeSpentMinutes),
      inProgressSince: Value(inProgressSince),
    ));
    return id;
  }

  // ---------------------------------------------------------------------------
  // watchCompletedToday
  // ---------------------------------------------------------------------------

  group('watchCompletedToday', () {
    test('returns done tasks selected for today', () async {
      final id = await insertTask(
        state: GtdState.done.value,
        selectedForToday: true,
        dailySelectionDate: _today,
        timeEstimate: 30,
        timeSpentMinutes: 25,
      );

      final result =
          await db.todoDao.watchCompletedToday(_uid, _today).first;
      expect(result.map((t) => t.id), contains(id));
    });

    test('excludes done tasks not selected for today', () async {
      await insertTask(
        state: GtdState.done.value,
        selectedForToday: false,
        dailySelectionDate: _today,
      );

      final result =
          await db.todoDao.watchCompletedToday(_uid, _today).first;
      expect(result, isEmpty);
    });

    test('excludes done tasks from a different date', () async {
      await insertTask(
        state: GtdState.done.value,
        selectedForToday: true,
        dailySelectionDate: '2025-01-14',
      );

      final result =
          await db.todoDao.watchCompletedToday(_uid, _today).first;
      expect(result, isEmpty);
    });

    test('excludes non-done tasks even if selected today', () async {
      await insertTask(
        state: GtdState.nextAction.value,
        selectedForToday: true,
        dailySelectionDate: _today,
      );

      final result =
          await db.todoDao.watchCompletedToday(_uid, _today).first;
      expect(result, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // watchUnfinishedSelectedToday
  // ---------------------------------------------------------------------------

  group('watchUnfinishedSelectedToday', () {
    test('returns selected non-done tasks for today', () async {
      final id = await insertTask(
        state: GtdState.nextAction.value,
        selectedForToday: true,
        dailySelectionDate: _today,
      );

      final result = await db.todoDao
          .watchUnfinishedSelectedToday(_uid, _today)
          .first;
      expect(result.map((t) => t.id), contains(id));
    });

    test('excludes done tasks', () async {
      await insertTask(
        state: GtdState.done.value,
        selectedForToday: true,
        dailySelectionDate: _today,
      );

      final result = await db.todoDao
          .watchUnfinishedSelectedToday(_uid, _today)
          .first;
      expect(result, isEmpty);
    });

    test('excludes tasks not selected for today', () async {
      await insertTask(
        state: GtdState.nextAction.value,
        selectedForToday: false,
        dailySelectionDate: _today,
      );

      final result = await db.todoDao
          .watchUnfinishedSelectedToday(_uid, _today)
          .first;
      expect(result, isEmpty);
    });

    test('includes in_progress tasks selected today', () async {
      final now = DateTime.now();
      final id = await insertTask(
        state: GtdState.inProgress.value,
        selectedForToday: true,
        dailySelectionDate: _today,
        inProgressSince: now.toIso8601String(),
      );

      final result = await db.todoDao
          .watchUnfinishedSelectedToday(_uid, _today)
          .first;
      expect(result.map((t) => t.id), contains(id));
    });
  });

  // ---------------------------------------------------------------------------
  // rolloverTask
  // ---------------------------------------------------------------------------

  group('rolloverTask', () {
    test('preselects task for tomorrow', () async {
      final id = await insertTask(
        state: GtdState.nextAction.value,
        selectedForToday: true,
        dailySelectionDate: _today,
      );

      await db.todoDao.rolloverTask(id, _uid, _tomorrow);

      final task = await db.todoDao.getTodo(id, _uid);
      expect(task?.selectedForToday, isTrue);
      expect(task?.dailySelectionDate, equals(_tomorrow));
      expect(task?.state, equals(GtdState.nextAction.value));
    });

    test('logs elapsed time and reverts in_progress to next_action', () async {
      final started = DateTime(2025, 1, 15, 10, 0);
      final now = DateTime(2025, 1, 15, 10, 45);
      const initialSpent = 10;
      const elapsedMinutes = 45;
      final id = await insertTask(
        state: GtdState.inProgress.value,
        selectedForToday: true,
        dailySelectionDate: _today,
        inProgressSince: started.toIso8601String(),
        timeSpentMinutes: initialSpent,
      );

      await db.todoDao.rolloverTask(id, _uid, _tomorrow, now: now);

      final task = await db.todoDao.getTodo(id, _uid);
      expect(task?.state, equals(GtdState.nextAction.value));
      expect(task?.inProgressSince, isNull);
      expect(task?.timeSpentMinutes, equals(initialSpent + elapsedMinutes));
      expect(task?.selectedForToday, isTrue);
      expect(task?.dailySelectionDate, equals(_tomorrow));
    });

    test('removes task from today\'s unfinished list after rollover', () async {
      final id = await insertTask(
        state: GtdState.nextAction.value,
        selectedForToday: true,
        dailySelectionDate: _today,
      );

      await db.todoDao.rolloverTask(id, _uid, _tomorrow);

      final unfinished = await db.todoDao
          .watchUnfinishedSelectedToday(_uid, _today)
          .first;
      expect(unfinished.map((t) => t.id), isNot(contains(id)));
    });
  });

  // ---------------------------------------------------------------------------
  // returnToNextActions
  // ---------------------------------------------------------------------------

  group('returnToNextActions', () {
    test('clears daily selection fields', () async {
      final id = await insertTask(
        state: GtdState.nextAction.value,
        selectedForToday: true,
        dailySelectionDate: _today,
      );

      await db.todoDao.returnToNextActions(id, _uid);

      final task = await db.todoDao.getTodo(id, _uid);
      expect(task?.selectedForToday, isNull);
      expect(task?.dailySelectionDate, isNull);
      expect(task?.state, equals(GtdState.nextAction.value));
    });

    test('forces scheduled task back to next_action', () async {
      final id = await insertTask(
        state: GtdState.scheduled.value,
        selectedForToday: true,
        dailySelectionDate: _today,
      );

      await db.todoDao.returnToNextActions(id, _uid);

      final task = await db.todoDao.getTodo(id, _uid);
      expect(task?.state, equals(GtdState.nextAction.value));
      expect(task?.selectedForToday, isNull);
      expect(task?.dailySelectionDate, isNull);
    });

    test('logs elapsed time and reverts in_progress to next_action', () async {
      final started = DateTime(2025, 1, 15, 9, 0);
      final now = DateTime(2025, 1, 15, 9, 20);
      const initialSpent = 5;
      const elapsedMinutes = 20;
      final id = await insertTask(
        state: GtdState.inProgress.value,
        selectedForToday: true,
        dailySelectionDate: _today,
        inProgressSince: started.toIso8601String(),
        timeSpentMinutes: initialSpent,
      );

      await db.todoDao.returnToNextActions(id, _uid, now: now);

      final task = await db.todoDao.getTodo(id, _uid);
      expect(task?.state, equals(GtdState.nextAction.value));
      expect(task?.inProgressSince, isNull);
      expect(task?.timeSpentMinutes, equals(initialSpent + elapsedMinutes));
      expect(task?.selectedForToday, isNull);
      expect(task?.dailySelectionDate, isNull);
    });

    test('removes task from today\'s unfinished list', () async {
      final id = await insertTask(
        state: GtdState.nextAction.value,
        selectedForToday: true,
        dailySelectionDate: _today,
      );

      await db.todoDao.returnToNextActions(id, _uid);

      final unfinished = await db.todoDao
          .watchUnfinishedSelectedToday(_uid, _today)
          .first;
      expect(unfinished.map((t) => t.id), isNot(contains(id)));
    });
  });
}
