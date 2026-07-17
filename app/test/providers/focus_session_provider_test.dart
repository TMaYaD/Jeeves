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
      final log = await db.timeLogDao.watchActiveLog().first;
      expect(log, isNotNull);
      expect(log!.taskId, todo.id);
      expect(DateTime.parse(log.startedAt), s.sessionStart!.toUtc());

      // Session's current_task_id must point to the focused task.
      final session = await db.focusSessionDao.getActiveSession();
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

    test(
        'concurrent startFocus for a different task throws StateError '
        'without opening a second engagement', () async {
      final todo1 = await _insertTask(db);
      final todo2 = await _insertTask(db);

      // Fire both before awaiting either: the second must be rejected by
      // the in-flight guard even though state is still inactive while the
      // first call's DB writes are in progress.
      final first =
          container.read(focusModeProvider.notifier).startFocus(todo1.id);
      await expectLater(
        () => container.read(focusModeProvider.notifier).startFocus(todo2.id),
        throwsA(isA<StateError>()),
      );
      await first;

      final s = container.read(focusModeProvider);
      expect(s.activeTodoId, todo1.id,
          reason: 'the first start wins; the second must not overwrite it');
      final log = await db.timeLogDao.watchActiveLog().first;
      expect(log!.taskId, todo1.id,
          reason: 'exactly one engagement TimeLog may be open');
    });

    test('concurrent startFocus for the same task defers to the first call',
        () async {
      final todo = await _insertTask(db);

      final first =
          container.read(focusModeProvider.notifier).startFocus(todo.id);
      final second =
          container.read(focusModeProvider.notifier).startFocus(todo.id);
      await Future.wait([first, second]);

      final s = container.read(focusModeProvider);
      expect(s.activeTodoId, todo.id);
      final log = await db.timeLogDao.watchActiveLog().first;
      expect(log!.taskId, todo.id);
    });

    test(
        'opens an ad-hoc TimeLog when no open focus session exists '
        '(ADR-0005: engagement is independent of FocusSession)', () async {
      final todo = await _insertTask(db);
      // No session opened — engagement must not be gated on one.
      await container.read(focusModeProvider.notifier).startFocus(todo.id);

      final s = container.read(focusModeProvider);
      expect(s.activeTodoId, todo.id);
      expect(s.isActive, isTrue);

      final log = await db.timeLogDao.watchActiveLog().first;
      expect(log, isNotNull);
      expect(log!.taskId, todo.id);
      expect(log.focusSessionId, isNull,
          reason: 'ad-hoc engagement carries a null session FK');
    });

    test('endFocus closes the ad-hoc TimeLog when no session exists',
        () async {
      final todo = await _insertTask(db);
      await container.read(focusModeProvider.notifier).startFocus(todo.id);

      await container.read(focusModeProvider.notifier).endFocus();

      final s = container.read(focusModeProvider);
      expect(s.isActive, isFalse);
      final log = await db.timeLogDao.watchActiveLog().first;
      expect(log, isNull);
    });

    test(
        'attributes the TimeLog to the open session when engaging an '
        'off-Plan task (Focus may point off-Plan, CONTEXT.md § Engagement)',
        () async {
      final planned = await _insertTask(db);
      final offPlan = await _insertTask(db);
      await db.focusSessionDao
          .openSession(userId: _userId, taskIds: [planned.id]);

      await container.read(focusModeProvider.notifier).startFocus(offPlan.id);

      final log = await db.timeLogDao.watchActiveLog().first;
      expect(log, isNotNull);
      expect(log!.taskId, offPlan.id);

      final session = await db.focusSessionDao.getActiveSession();
      expect(log.focusSessionId, session?.id,
          reason: 'a session open at engagement time attributes the TimeLog');
      expect(session?.currentTaskId, offPlan.id,
          reason: 'the Focus pointer may reference an off-Plan Outcome');
    });

    test('endFocus clears provider state and closes time log', () async {
      final todo = await _insertTask(db);
      await db.focusSessionDao.openSession(userId: _userId, taskIds: [todo.id]);
      await container.read(focusModeProvider.notifier).startFocus(todo.id);

      await container.read(focusModeProvider.notifier).endFocus();

      final s = container.read(focusModeProvider);
      expect(s.isActive, isFalse);
      expect(s.sessionStart, isNull);

      // Time log must be closed.
      final log = await db.timeLogDao.watchActiveLog().first;
      expect(log, isNull);

      // Session's current_task_id must be cleared.
      final session = await db.focusSessionDao.getActiveSession();
      expect(session?.currentTaskId, isNull);
    });
  });
}
