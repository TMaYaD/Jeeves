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

      final session = await db.focusSessionDao.getActiveSession();
      expect(session, isNull,
          reason: 'closeDay should close the open session');

      final closed = await (db.select(db.focusSessions)
            ..where((s) => s.id.equals(sessionId)))
          .getSingle();
      expect(closed.endedAt, isNotNull);
    });

    test('closeDay tolerates running with no active session', () async {
      // No session opened; closeDay should still complete without throwing
      // (e.g. user opens settings -> "Start Evening Shutdown" before planning).
      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.closeDay();
      // No assertion — the absence of an exception is the contract.
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

    test('returnToNext records "leave" disposition in memory',
        () async {
      await _insertTodo(db, id: 't1');
      await _openSessionWith(db, ['t1']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      notifier.returnToNext('t1');

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
      notifier.returnToNext('t2');
      await notifier.closeDay();

      final rolloverIds =
          await db.focusSessionDao.getLastClosedSessionRolloverTaskIds();
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
      notifier.returnToNext('t1');
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
          .watchActiveSessionTasks()
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

    test(
        'unfinishedSelectedTodayProvider surfaces an off-Plan engaged Outcome '
        'and closeDay persists its disposition (issue #418)', () async {
      await _insertTodo(db, id: 'plan1'); // Plan member
      await _insertTodo(db, id: 'off1'); // off-Plan engaged
      final sessionId = await _openSessionWith(db, ['plan1']);
      // Off-Plan engagement: a TimeLog against the session, no Plan row.
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('tl-off1'),
            userId: const Value(_uid),
            taskId: const Value('off1'),
            startedAt: Value(DateTime.now().toUtc().toIso8601String()),
            focusSessionId: Value(sessionId),
          ));

      final sub = container.listen<AsyncValue<List<Todo>>>(
          unfinishedSelectedTodayProvider, (_, _) {});
      final surfaced = await container
          .read(unfinishedSelectedTodayProvider.future)
          .timeout(const Duration(seconds: 5));
      expect(surfaced.map((t) => t.id), containsAll(['plan1', 'off1']),
          reason: 'the off-Plan engaged Outcome must appear in Review.');

      // Disposition the off-Plan Outcome and close the ritual.
      container.read(eveningShutdownProvider.notifier).rolloverTask('off1');
      container.read(eveningShutdownProvider.notifier).returnToNext('plan1');
      sub.close();
      await container.read(eveningShutdownProvider.notifier).closeDay();

      // The off-Plan rollover is durably stored and pre-selects next time.
      final rollover =
          await db.focusSessionDao.getLastClosedSessionRolloverTaskIds();
      expect(rollover, contains('off1'));
    });
  });

  // ---------------------------------------------------------------------------
  // Unfinished snapshot navigation
  // ---------------------------------------------------------------------------

  group('Unfinished snapshot navigation', () {
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

    test('loadUnfinishedSnapshot populates state with only unfinished tasks',
        () async {
      await _insertTodo(db,
          id: 'done1',
          doneAt: DateTime.now().toUtc().toIso8601String());
      await _insertTodo(db, id: 'open1');
      await _insertTodo(db, id: 'open2');
      await _openSessionWith(db, ['done1', 'open1', 'open2']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.loadUnfinishedSnapshot();

      final state = container.read(eveningShutdownProvider);
      expect(state.unfinishedNav.items, isNotNull);
      expect(state.unfinishedNav.items!.map((t) => t.id),
          containsAll(['open1', 'open2']));
      expect(state.unfinishedNav.items!.map((t) => t.id),
          isNot(contains('done1')));
    });

    test('loadUnfinishedSnapshot is idempotent', () async {
      await _insertTodo(db, id: 't1');
      await _openSessionWith(db, ['t1']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.loadUnfinishedSnapshot();
      final firstSnapshot =
          container.read(eveningShutdownProvider).unfinishedNav.items;

      // Mark the in-session task done in the DB directly — snapshot must not change.
      final doneAt = DateTime.now().toUtc().toIso8601String();
      await (db.update(db.todos)..where((t) => t.id.equals('t1')))
          .write(TodosCompanion(doneAt: Value(doneAt)));
      await notifier.loadUnfinishedSnapshot(); // should be a no-op

      final secondSnapshot =
          container.read(eveningShutdownProvider).unfinishedNav.items;
      expect(identical(firstSnapshot, secondSnapshot), isTrue,
          reason: 'second call must not replace the snapshot object');
    });

    test('rolloverTask records disposition and advances index', () async {
      await _insertTodo(db, id: 't1');
      await _insertTodo(db, id: 't2');
      await _openSessionWith(db, ['t1', 't2']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.loadUnfinishedSnapshot();

      final snapshot =
          container.read(eveningShutdownProvider).unfinishedNav.items!;
      final firstId = snapshot[0].id;

      notifier.rolloverTask(firstId);

      final state = container.read(eveningShutdownProvider);
      expect(state.dispositions[firstId], equals('rollover'));
      expect(state.unfinishedNav.index, equals(1));
    });

    test('returnToNext records disposition and advances index', () async {
      await _insertTodo(db, id: 't1');
      await _insertTodo(db, id: 't2');
      await _openSessionWith(db, ['t1', 't2']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.loadUnfinishedSnapshot();

      final snapshot =
          container.read(eveningShutdownProvider).unfinishedNav.items!;
      final firstId = snapshot[0].id;

      notifier.returnToNext(firstId);

      final state = container.read(eveningShutdownProvider);
      expect(state.dispositions[firstId], equals('leave'));
      expect(state.unfinishedNav.index, equals(1));
    });

    test('deferTask records disposition and advances index', () async {
      await _insertTodo(db, id: 't1');
      await _insertTodo(db, id: 't2');
      await _openSessionWith(db, ['t1', 't2']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.loadUnfinishedSnapshot();

      final snapshot =
          container.read(eveningShutdownProvider).unfinishedNav.items!;
      final firstId = snapshot[0].id;

      notifier.deferTask(firstId);

      final state = container.read(eveningShutdownProvider);
      expect(state.dispositions[firstId], equals('maybe'));
      expect(state.unfinishedNav.index, equals(1));
    });

    test('resolving the last unfinished item auto-advances the step',
        () async {
      await _insertTodo(db, id: 't1');
      await _openSessionWith(db, ['t1']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.loadUnfinishedSnapshot();

      // Drive into the unfinished step (where the user actually resolves
      // tasks) so the assertion exercises the real terminal transition
      // (1 → 2 / CloseDay), not the 0 → 1 transition.
      notifier.goToStep(1);
      expect(container.read(eveningShutdownProvider).currentStep, equals(1));

      notifier.rolloverTask('t1'); // index would become 1 >= length 1 → advanceStep

      final state = container.read(eveningShutdownProvider);
      expect(state.currentStep, equals(2),
          reason: 'final disposition should advance off step 1');
    });

    test(
        'previousUnfinishedTask is pure navigation: disposition is preserved',
        () async {
      await _insertTodo(db, id: 't1');
      await _insertTodo(db, id: 't2');
      await _openSessionWith(db, ['t1', 't2']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.loadUnfinishedSnapshot();

      final snapshot =
          container.read(eveningShutdownProvider).unfinishedNav.items!;
      final firstId = snapshot[0].id;

      notifier.rolloverTask(firstId); // index → 1, disposition set
      expect(container.read(eveningShutdownProvider).unfinishedNav.index, equals(1));

      notifier.previousUnfinishedTask(); // index → 0, disposition preserved

      final state = container.read(eveningShutdownProvider);
      expect(state.unfinishedNav.index, equals(0));
      expect(state.dispositions[firstId], equals('rollover'),
          reason:
              'Back must not clear dispositions; the previously-selected '
              'affordance reads them on revisit.');
    });

    test('re-tapping a different disposition replaces the prior one', () async {
      await _insertTodo(db, id: 't1');
      await _openSessionWith(db, ['t1']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.loadUnfinishedSnapshot();

      final id =
          container.read(eveningShutdownProvider).unfinishedNav.items!.first.id;

      notifier.rolloverTask(id);
      expect(container.read(eveningShutdownProvider).dispositions[id],
          equals('rollover'));

      // Snapshot only had one item, so rolloverTask called advanceStep.
      // Drive back to the resolution UI for re-tap by going back to step 1.
      notifier.goToStep(1);
      notifier.previousUnfinishedTask(); // pure nav — no-op at index 0
      notifier.deferTask(id);

      expect(container.read(eveningShutdownProvider).dispositions[id],
          equals('maybe'));
    });

    test('previousUnfinishedTask is clamped at 0', () async {
      await _insertTodo(db, id: 't1');
      await _openSessionWith(db, ['t1']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.loadUnfinishedSnapshot();

      expect(container.read(eveningShutdownProvider).unfinishedNav.index, equals(0));

      notifier.previousUnfinishedTask(); // already at 0

      expect(container.read(eveningShutdownProvider).unfinishedNav.index, equals(0));
    });

    test('step is complete when all snapshot items have been resolved',
        () async {
      await _insertTodo(db, id: 't1');
      await _insertTodo(db, id: 't2');
      await _openSessionWith(db, ['t1', 't2']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.loadUnfinishedSnapshot();
      notifier.goToStep(1); // simulate user being on the unfinished step

      final snapshot =
          container.read(eveningShutdownProvider).unfinishedNav.items!;
      notifier.rolloverTask(snapshot[0].id); // index → 1
      notifier.deferTask(snapshot[1].id);    // index would be 2 >= 2 → advanceStep

      final state = container.read(eveningShutdownProvider);
      expect(state.currentStep, equals(2),
          reason: 'step advances off Resolve Unfinished onto CloseDay');
    });

    test('closeDay commits all accumulated dispositions after snapshot use',
        () async {
      await _insertTodo(db, id: 't1');
      await _insertTodo(db, id: 't2');
      await _openSessionWith(db, ['t1', 't2']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.loadUnfinishedSnapshot();

      final snapshot =
          container.read(eveningShutdownProvider).unfinishedNav.items!;
      notifier.rolloverTask(snapshot[0].id);
      notifier.deferTask(snapshot[1].id); // auto-advances step

      await notifier.closeDay();

      final rolloverIds =
          await db.focusSessionDao.getLastClosedSessionRolloverTaskIds();
      expect(rolloverIds, contains(snapshot[0].id));

      final deferred = await (db.select(db.todos)
            ..where((t) => t.id.equals(snapshot[1].id)))
          .getSingle();
      expect(deferred.intent, equals('maybe'));
    });

    test('snapshot does not drift when DB changes mid-session', () async {
      await _insertTodo(db, id: 't1');
      await _insertTodo(db, id: 't2');
      await _openSessionWith(db, ['t1', 't2']);

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.loadUnfinishedSnapshot();

      final snapshotBefore =
          container.read(eveningShutdownProvider).unfinishedNav.items!;
      expect(snapshotBefore.length, equals(2));

      // Mark t1 done in DB directly (simulates background update).
      final doneAt = DateTime.now().toUtc().toIso8601String();
      await (db.update(db.todos)..where((t) => t.id.equals('t1')))
          .write(TodosCompanion(doneAt: Value(doneAt)));

      final snapshotAfter =
          container.read(eveningShutdownProvider).unfinishedNav.items!;
      expect(snapshotAfter.length, equals(2),
          reason: 'snapshot must not drift after DB changes');
      expect(snapshotAfter.map((t) => t.id), containsAll(['t1', 't2']));
    });
  });
}
