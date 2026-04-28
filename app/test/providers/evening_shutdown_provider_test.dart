/// Tests for [EveningShutdownNotifier] and the stream providers that drive
/// the shutdown ritual UI. Exercises the rewired surface that sits on top of
/// [FocusSessionDao] (post-#185).
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/evening_shutdown_provider.dart';
import '../test_helpers.dart';

// Must match currentUserIdProvider.build() default so the notifier finds tasks.
const _uid = 'local';

// Stub: skip platform-channel calls in the notification helpers but exercise
// the SharedPreferences side effects that real code paths perform.
class _StubShutdownNotifier extends EveningShutdownNotifier {
  @override
  Future<void> skipShutdownToday() async {
    await persistShutdownSkipToday();
  }

  @override
  Future<void> snoozeShutdownNotification(int minutes) async {
    final until = DateTime.now().add(Duration(minutes: minutes));
    await persistShutdownSnoozedUntil(until);
  }
}

ProviderContainer _container(GtdDatabase db) => ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        eveningShutdownProvider.overrideWith(() => _StubShutdownNotifier()),
      ],
    );

Future<String> _insertTodo(
  GtdDatabase db, {
  required String id,
  String? doneAt,
  String intent = 'next',
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Task $id'),
        clarified: const Value(true),
        intent: Value(intent),
        doneAt: Value(doneAt),
        userId: const Value(_uid),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  return id;
}

Future<String> _openSessionWith(
  GtdDatabase db,
  List<String> taskIds,
) =>
    db.focusSessionDao.openSession(userId: _uid, taskIds: taskIds);

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    shutdownCompletionNotifier.value = false;
    shutdownBannerDismissedNotifier.value = false;
  });

  group('EveningShutdownNotifier', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = _container(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    // ---- Step navigation -----------------------------------------------------

    test('starts at step 0', () {
      final state = container.read(eveningShutdownProvider);
      expect(state.currentStep, equals(0));
    });

    test('advanceStep increments currentStep', () {
      final notifier = container.read(eveningShutdownProvider.notifier);
      notifier.advanceStep();
      expect(container.read(eveningShutdownProvider).currentStep, equals(1));
    });

    test('advanceStep clamps at max step', () {
      final notifier = container.read(eveningShutdownProvider.notifier);
      notifier.goToStep(2); // at max
      notifier.advanceStep(); // try to go beyond
      expect(container.read(eveningShutdownProvider).currentStep, equals(2));
    });

    test('goToStep sets step directly', () {
      final notifier = container.read(eveningShutdownProvider.notifier);
      notifier.goToStep(2);
      expect(container.read(eveningShutdownProvider).currentStep, equals(2));
    });

    // ---- closeDay ------------------------------------------------------------

    test('closeDay sets shutdownCompletionNotifier to true', () async {
      await _openSessionWith(db, []);

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.closeDay();
      expect(shutdownCompletionNotifier.value, isTrue);
    });

    test('closeDay persists completion date to SharedPreferences', () async {
      await _openSessionWith(db, []);

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.closeDay();

      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('shutdown_ritual_completed_date');
      expect(stored, isNotNull);
    });

    test('closeDay resets step to 0', () async {
      await _openSessionWith(db, []);

      final notifier = container.read(eveningShutdownProvider.notifier);
      notifier.goToStep(2);
      await notifier.closeDay();
      expect(container.read(eveningShutdownProvider).currentStep, equals(0));
    });

    test('closeDay closes the active focus session', () async {
      final sessionId = await _openSessionWith(db, []);

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.closeDay();

      final session = await db.focusSessionDao.getActiveSession(_uid);
      expect(session, isNull,
          reason: 'closeDay should close the open session');

      final closed = await (db.select(db.focusSessions)
            ..where((s) => s.id.equals(sessionId)))
          .getSingle();
      expect(closed.endedAt, isNotNull);
    });

    test('closeDay tolerates running with no active session', () async {
      // No session opened; closeDay should still flip the completion flag
      // (e.g. user opens settings -> "Start Evening Shutdown" before planning).
      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.closeDay();
      expect(shutdownCompletionNotifier.value, isTrue);
    });

    // ---- dismissBannerForToday -----------------------------------------------

    test('dismissBannerForToday sets shutdownBannerDismissedNotifier',
        () async {
      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.dismissBannerForToday();
      expect(shutdownBannerDismissedNotifier.value, isTrue);
    });

    test('dismissBannerForToday persists dismissed date', () async {
      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.dismissBannerForToday();

      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('shutdown_banner_dismissed_date');
      expect(stored, isNotNull);
    });

    // ---- Disposition recording (in-memory) -----------------------------------

    test('rolloverTask records "rollover" disposition in memory', () async {
      await _insertTodo(db, id: 't1');
      await _openSessionWith(db, ['t1']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      notifier.rolloverTask('t1');

      final state = container.read(eveningShutdownProvider);
      expect(state.dispositions['t1'], equals('rollover'));
    });

    test('returnToNextActions records "leave" disposition in memory',
        () async {
      await _insertTodo(db, id: 't1');
      await _openSessionWith(db, ['t1']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      notifier.returnToNextActions('t1');

      final state = container.read(eveningShutdownProvider);
      expect(state.dispositions['t1'], equals('leave'));
    });

    test('deferTask records "maybe" disposition in memory', () async {
      await _insertTodo(db, id: 't1');
      await _openSessionWith(db, ['t1']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      notifier.deferTask('t1');

      final state = container.read(eveningShutdownProvider);
      expect(state.dispositions['t1'], equals('maybe'));
    });

    // ---- closeDay end-to-end with dispositions -------------------------------

    test('closeDay seeds rollover task ids for tomorrow\'s session', () async {
      await _insertTodo(db, id: 't1');
      await _insertTodo(db, id: 't2');
      await _openSessionWith(db, ['t1', 't2']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      notifier.rolloverTask('t1');
      notifier.returnToNextActions('t2');
      await notifier.closeDay();

      final rolloverIds =
          await db.focusSessionDao.getLastClosedSessionRolloverTaskIds(_uid);
      expect(rolloverIds, contains('t1'));
      expect(rolloverIds, isNot(contains('t2')));
    });

    test('closeDay flips intent to "maybe" for deferred tasks', () async {
      await _insertTodo(db, id: 't1');
      await _openSessionWith(db, ['t1']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      notifier.deferTask('t1');
      await notifier.closeDay();

      final after = await (db.select(db.todos)
            ..where((t) => t.id.equals('t1')))
          .getSingle();
      expect(after.intent, equals('maybe'));
    });

    test('closeDay does NOT mutate intent for "leave" disposition', () async {
      await _insertTodo(db, id: 't1');
      await _openSessionWith(db, ['t1']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      notifier.returnToNextActions('t1');
      await notifier.closeDay();

      final after = await (db.select(db.todos)
            ..where((t) => t.id.equals('t1')))
          .getSingle();
      expect(after.intent, equals('next'),
          reason: 'leave-dispositioned tasks remain in next-actions');
    });

    // ---- Stream providers ----------------------------------------------------

    test('completedTodayProvider emits done tasks in the active session',
        () async {
      await _insertTodo(db,
          id: 't_done',
          doneAt: DateTime.now().toUtc().toIso8601String());
      await _insertTodo(db, id: 't_open');
      await _openSessionWith(db, ['t_done', 't_open']);

      // Sanity: DAO stream emits as expected.
      final raw = await db.focusSessionDao
          .watchSessionTasksForUser(_uid)
          .first
          .timeout(const Duration(seconds: 5));
      expect(raw.map((t) => t.id), containsAll(['t_done', 't_open']));

      // Subscribe explicitly so the StreamProvider has a listener.
      final sub = container.listen<AsyncValue<List<Todo>>>(
        completedTodayProvider, (_, _) {});
      final completed =
          await container.read(completedTodayProvider.future)
              .timeout(const Duration(seconds: 5));
      sub.close();
      expect(completed.map((t) => t.id), equals(['t_done']));
    });

    test(
        'unfinishedSelectedTodayProvider hides tasks once a disposition is recorded',
        () async {
      await _insertTodo(db, id: 't1');
      await _insertTodo(db, id: 't2');
      await _openSessionWith(db, ['t1', 't2']);

      // Hold an active listener so the StreamProvider stays subscribed
      // across the dispositions change below; without a listener, the
      // provider can dispose between reads.
      final sub = container.listen<AsyncValue<List<Todo>>>(
          unfinishedSelectedTodayProvider, (_, _) {});

      final before = await container
          .read(unfinishedSelectedTodayProvider.future)
          .timeout(const Duration(seconds: 5));
      expect(before.map((t) => t.id), containsAll(['t1', 't2']));

      container.read(eveningShutdownProvider.notifier).rolloverTask('t1');

      final after = await container
          .read(unfinishedSelectedTodayProvider.future)
          .timeout(const Duration(seconds: 5));
      sub.close();
      expect(after.map((t) => t.id), equals(['t2']));
    });
  });
}
