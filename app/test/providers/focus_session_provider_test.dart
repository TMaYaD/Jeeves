import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_provider.dart';

import '../test_helpers.dart';

// currentUserIdProvider defaults to 'local' — no override needed.
const _userId = 'local';

ProviderContainer _makeContainer(GtdDatabase db) => ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((_) => db),
      ],
    );

Future<Todo> _insertTask(GtdDatabase db) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
    title: Value('Test Task'),
    userId: Value(_userId),
    createdAt: Value(now),
  ));
  final rows = await db.select(db.todos).get();
  return rows.last;
}

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    focusSessionPlanningCompletionNotifier.value = false;
  });

  group('FocusModeState.elapsed', () {
    test('returns zero when no session active', () {
      const s = FocusModeState();
      expect(s.elapsed, Duration.zero);
    });

    test('returns net elapsed when running', () {
      final start = DateTime.now().subtract(const Duration(minutes: 5));
      final s = FocusModeState(sessionStart: start);
      expect(s.elapsed.inMinutes, 5);
    });

    test('elapsed is frozen when paused', () {
      final start = DateTime.now().subtract(const Duration(minutes: 10));
      final pauseStart = DateTime.now().subtract(const Duration(minutes: 3));
      final s = FocusModeState(
        sessionStart: start,
        isPaused: true,
        pauseStart: pauseStart,
      );
      // Elapsed at pause = 10m - 3m = 7m
      expect(s.elapsed.inMinutes, 7);
    });

    test('accumulated reduces elapsed', () {
      final start = DateTime.now().subtract(const Duration(minutes: 10));
      final s = FocusModeState(
        sessionStart: start,
        accumulated: const Duration(minutes: 3),
      );
      expect(s.elapsed.inMinutes, 7);
    });
  });

  group('FocusModeNotifier — pure state transitions', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
    });

    tearDown(() => container.dispose());

    test('initial state is inactive', () {
      final s = container.read(focusModeProvider);
      expect(s.isActive, isFalse);
      expect(s.isPaused, isFalse);
      expect(s.activeTodoId, isNull);
    });

    test('resumeFrom sets active session', () {
      final since = DateTime.now().subtract(const Duration(minutes: 5));
      container.read(focusModeProvider.notifier).resumeFrom('id-1', since);
      final s = container.read(focusModeProvider);
      expect(s.isActive, isTrue);
      expect(s.activeTodoId, 'id-1');
      expect(s.sessionStart, since);
    });

    test('resumeFrom while paused folds pause gap into accumulated', () {
      final since = DateTime.now().subtract(const Duration(minutes: 10));
      final pauseTime = DateTime.now();
      final resumeTime = pauseTime.add(const Duration(milliseconds: 100));

      container.read(focusModeProvider.notifier).resumeFrom('id-1', since);
      container.read(focusModeProvider.notifier).pauseFocus(now: pauseTime);
      expect(container.read(focusModeProvider).isPaused, isTrue);

      // Simulate exit → re-enter: resumeFrom called with same todoId while paused.
      container
          .read(focusModeProvider.notifier)
          .resumeFrom('id-1', since, now: resumeTime);
      final s = container.read(focusModeProvider);

      expect(s.isPaused, isFalse);
      expect(s.sessionStart, since);
      expect(s.accumulated, const Duration(milliseconds: 100));
    });

    test('pauseFocus freezes timer', () {
      final since = DateTime.now().subtract(const Duration(minutes: 5));
      container.read(focusModeProvider.notifier).resumeFrom('id-1', since);
      container.read(focusModeProvider.notifier).pauseFocus();
      final s = container.read(focusModeProvider);
      expect(s.isPaused, isTrue);
      expect(s.pauseStart, isNotNull);
    });

    test('pauseFocus is idempotent when already paused', () {
      final since = DateTime.now().subtract(const Duration(minutes: 5));
      container.read(focusModeProvider.notifier).resumeFrom('id-1', since);
      container.read(focusModeProvider.notifier).pauseFocus();
      final firstPause = container.read(focusModeProvider).pauseStart;
      container.read(focusModeProvider.notifier).pauseFocus();
      expect(container.read(focusModeProvider).pauseStart, firstPause);
    });

    test('resumeFocus accumulates pause duration', () {
      final since = DateTime.now().subtract(const Duration(minutes: 10));
      final pauseTime = DateTime.now();
      final resumeTime = pauseTime.add(const Duration(seconds: 90));

      container.read(focusModeProvider.notifier).resumeFrom('id-1', since);
      container.read(focusModeProvider.notifier).pauseFocus(now: pauseTime);
      container.read(focusModeProvider.notifier).resumeFocus(now: resumeTime);
      final s = container.read(focusModeProvider);
      expect(s.isPaused, isFalse);
      expect(s.pauseStart, isNull);
      expect(s.accumulated, const Duration(seconds: 90));
    });

    test('resumeFocus no-ops when not paused', () {
      final since = DateTime.now().subtract(const Duration(minutes: 5));
      container.read(focusModeProvider.notifier).resumeFrom('id-1', since);
      container.read(focusModeProvider.notifier).resumeFocus();
      expect(container.read(focusModeProvider).accumulated, Duration.zero);
    });

  });

  group('FocusModeNotifier — startFocus / endFocus (integration)', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = _makeContainer(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('activates session and opens a time log', () async {
      final todo = await _insertTask(db);
      // An open session must exist before startFocus is called.
      await db.focusSessionDao.openSession(userId: _userId, taskIds: [todo.id]);

      await container.read(focusModeProvider.notifier).startFocus(todo.id);

      final s = container.read(focusModeProvider);
      expect(s.activeTodoId, todo.id);
      expect(s.isActive, isTrue);
      expect(s.sessionStart, isNotNull);

      // A time log must have been opened by setCurrentTask.
      final log = await db.timeLogDao.watchActiveLog(_userId).first;
      expect(log, isNotNull);
      expect(log!.taskId, todo.id);
      expect(DateTime.parse(log.startedAt), s.sessionStart!.toUtc());

      // Session's current_task_id must point to the focused task.
      final session = await db.focusSessionDao.getActiveSession(_userId);
      expect(session?.currentTaskId, todo.id);

      // The time log must be linked to the session.
      expect(log.focusSessionId, session?.id);
    });

    test('throws StateError when a different task is already active', () async {
      final todo1 = await _insertTask(db);
      final todo2 = await _insertTask(db);
      await db.focusSessionDao
          .openSession(userId: _userId, taskIds: [todo1.id, todo2.id]);

      await container.read(focusModeProvider.notifier).startFocus(todo1.id);

      expect(
        () => container.read(focusModeProvider.notifier).startFocus(todo2.id),
        throwsA(isA<StateError>()),
      );
    });

    test('throws StateError when no open focus session exists', () async {
      final todo = await _insertTask(db);
      // No session opened — startFocus should reject immediately.
      expect(
        () => container.read(focusModeProvider.notifier).startFocus(todo.id),
        throwsA(isA<StateError>()),
      );
    });

    test('endFocus clears provider state and closes time log', () async {
      final todo = await _insertTask(db);
      await db.focusSessionDao.openSession(userId: _userId, taskIds: [todo.id]);
      await container.read(focusModeProvider.notifier).startFocus(todo.id);

      await container.read(focusModeProvider.notifier).endFocus();

      final s = container.read(focusModeProvider);
      expect(s.isActive, isFalse);
      expect(s.sessionStart, isNull);
      expect(s.accumulated, Duration.zero);

      // Time log must be closed.
      final log = await db.timeLogDao.watchActiveLog(_userId).first;
      expect(log, isNull);

      // Session's current_task_id must be cleared.
      final session = await db.focusSessionDao.getActiveSession(_userId);
      expect(session?.currentTaskId, isNull);
    });
  });
}
