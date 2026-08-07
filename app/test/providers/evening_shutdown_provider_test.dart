/// Tests for [EveningShutdownNotifier] and the stream providers that drive
/// the shutdown ritual UI. Exercises the rewired surface that sits on top of
/// [FocusSessionDao] (post-#185).
library;

import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/evening_shutdown_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart'
    show activeSessionSettlementsProvider;
import 'package:jeeves/services/notification_service.dart';
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
        notificationServiceProvider
            .overrideWithValue(StubNotificationService()),
        eveningShutdownProvider.overrideWith(() => _StubShutdownNotifier()),
      ],
    );

/// As [_container], but with the Settlement stream under the test's control so
/// it can hold the map back while the review-surface stream emits.
ProviderContainer _containerWithSettlements(
  GtdDatabase db,
  Stream<Map<String, SessionSettlement>> settlements,
) =>
    ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider
            .overrideWithValue(StubNotificationService()),
        eveningShutdownProvider.overrideWith(() => _StubShutdownNotifier()),
        activeSessionSettlementsProvider.overrideWith((_) => settlements),
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

final _settledAt = DateTime.utc(2026, 5, 1, 10);

/// Stages the two facts that make [taskId] **Settled** under arm (b): an Action
/// of the Outcome completed inside [sessionId] (evidenced by a
/// session-attributed TimeLog naming it), and a re-clarification stamp at or
/// after that completion.
Future<void> _settleInSession(
  GtdDatabase db, {
  required String sessionId,
  required String taskId,
}) async {
  await db.into(db.actions).insert(ActionsCompanion(
        id: Value('act-$taskId'),
        outcomeId: Value(taskId),
        userId: const Value(_uid),
        actionText: const Value('the finished move'),
        role: const Value('done'),
        doneAt: Value(_settledAt),
        createdAt: Value(_settledAt.subtract(const Duration(hours: 1))),
      ));
  await db.into(db.timeLogs).insert(TimeLogsCompanion(
        id: Value('tl-act-$taskId'),
        userId: const Value(_uid),
        taskId: Value(taskId),
        actionId: Value('act-$taskId'),
        startedAt: Value(
            _settledAt.subtract(const Duration(minutes: 25)).toIso8601String()),
        endedAt: Value(_settledAt.toIso8601String()),
        focusSessionId: Value(sessionId),
      ));
  await (db.update(db.todos)..where((t) => t.id.equals(taskId))).write(
    TodosCompanion(
      lastClarifiedAt: Value(_settledAt.add(const Duration(seconds: 5))),
    ),
  );
}

/// Gives [taskId] a current Action, so it buckets as `next`.
Future<void> _seedNextMove(GtdDatabase db, String taskId) =>
    db.into(db.actions).insert(ActionsCompanion(
          id: Value('cur-$taskId'),
          outcomeId: Value(taskId),
          userId: const Value(_uid),
          actionText: const Value('the next move'),
          role: const Value('current'),
          createdAt: Value(_settledAt.add(const Duration(minutes: 1))),
        ));

/// Gives [taskId] a person Tag and no current Action, so it buckets as
/// `waitingFor`.
Future<void> _delegate(GtdDatabase db, String taskId) async {
  await db.into(db.tags).insert(
        const TagsCompanion(
          id: Value('tag-person'),
          name: Value('Trixy'),
          type: Value('person'),
          userId: Value(_uid),
        ),
        mode: InsertMode.insertOrReplace,
      );
  await db.into(db.todoTags).insert(TodoTagsCompanion(
        id: Value('tt-$taskId'),
        todoId: Value(taskId),
        tagId: const Value('tag-person'),
        userId: const Value(_uid),
      ));
}

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

    // Disposition recording (rollover/leave/maybe) is covered by the
    // "Unfinished snapshot navigation" group below, which asserts both the
    // recorded disposition and the index advance for each of the three verbs.

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

    test(
        'sessionSettlementGroupsProvider groups the day\'s Settled Outcomes '
        'and omits the empty buckets', () async {
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
      final sub = container.listen(sessionSettlementGroupsProvider, (_, _) {});
      final groups = await container
          .read(sessionSettlementGroupsProvider.future)
          .timeout(const Duration(seconds: 5));
      sub.close();
      expect(groups.keys, equals([SessionSettlement.done]),
          reason: 'only the completed group has members');
      expect(groups[SessionSettlement.done]!.map((t) => t.id), ['t_done']);
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
  // Settlement consumption (#694)
  // ---------------------------------------------------------------------------

  group('Evening Shutdown consumes the Settlement signal', () {
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

    /// A session where one Outcome settled into each bucket, plus one the user
    /// never touched.
    Future<String> stageOneOfEach() async {
      await _insertTodo(db,
          id: 'done1', doneAt: DateTime.now().toUtc().toIso8601String());
      await _insertTodo(db, id: 'next1');
      await _insertTodo(db, id: 'wait1');
      await _insertTodo(db, id: 'some1', intent: 'maybe');
      await _insertTodo(db, id: 'open1');
      final sessionId = await _openSessionWith(
          db, ['done1', 'next1', 'wait1', 'some1', 'open1']);

      await _settleInSession(db, sessionId: sessionId, taskId: 'next1');
      await _seedNextMove(db, 'next1');
      await _settleInSession(db, sessionId: sessionId, taskId: 'wait1');
      await _delegate(db, 'wait1');
      await _settleInSession(db, sessionId: sessionId, taskId: 'some1');
      return sessionId;
    }

    test('the summary groups every Settled Outcome, in render order (AC1–AC3)',
        () async {
      await stageOneOfEach();

      final sub = container.listen(sessionSettlementGroupsProvider, (_, _) {});
      final groups = await container
          .read(sessionSettlementGroupsProvider.future)
          .timeout(const Duration(seconds: 5));
      sub.close();

      expect(groups.keys, orderedEquals(sessionSettlementRenderOrder));
      expect(groups[SessionSettlement.done]!.map((t) => t.id), ['done1']);
      expect(groups[SessionSettlement.next]!.map((t) => t.id), ['next1']);
      expect(groups[SessionSettlement.waitingFor]!.map((t) => t.id), ['wait1']);
      expect(groups[SessionSettlement.someday]!.map((t) => t.id), ['some1']);
      expect(
        groups.values.expand((g) => g).map((t) => t.id),
        isNot(contains('open1')),
        reason: 'an untouched Outcome settled nothing',
      );
    });

    test(
        'neither consumer reads a not-yet-emitted settlement map as '
        '"nothing Settled"', () async {
      await stageOneOfEach();

      // A settlement stream this test controls, so the review-surface stream
      // can emit first — the ordering the two independent Drift watches make
      // reachable in the app.
      final settlements =
          StreamController<Map<String, SessionSettlement>>.broadcast();
      addTearDown(settlements.close);
      final gated = _containerWithSettlements(db, settlements.stream);
      addTearDown(gated.dispose);

      final groupsSub = gated.listen(sessionSettlementGroupsProvider, (_, _) {});
      final unfinishedSub = gated.listen<AsyncValue<List<Todo>>>(
          unfinishedSelectedTodayProvider, (_, _) {});
      // The review surface is ready and would emit; only the settlement map
      // is outstanding.
      await db.focusSessionDao
          .watchActiveSessionReviewSurface()
          .first
          .timeout(const Duration(seconds: 5));
      await pumpEventQueue();

      expect(
        gated.read(sessionSettlementGroupsProvider).hasValue,
        isFalse,
        reason: 'an empty-groups AsyncData renders "nothing resolved today" '
            'over a day that resolved four things',
      );
      expect(
        gated.read(unfinishedSelectedTodayProvider).hasValue,
        isFalse,
        reason: 'a first emission here counts every Settled Outcome as '
            'unfinished work',
      );

      settlements.add(await db.focusSessionDao.getActiveSessionSettlements());

      final groups = await gated
          .read(sessionSettlementGroupsProvider.future)
          .timeout(const Duration(seconds: 5));
      expect(groups.keys, orderedEquals(sessionSettlementRenderOrder));
      final unfinished = await gated
          .read(unfinishedSelectedTodayProvider.future)
          .timeout(const Duration(seconds: 5));
      expect(unfinished.map((t) => t.id), ['open1']);

      groupsSub.close();
      unfinishedSub.close();
    });

    test('the disposition step only presents unhandled work (AC4/AC5)',
        () async {
      await stageOneOfEach();

      final sub = container.listen<AsyncValue<List<Todo>>>(
          unfinishedSelectedTodayProvider, (_, _) {});
      final unfinished = await container
          .read(unfinishedSelectedTodayProvider.future)
          .timeout(const Duration(seconds: 5));
      sub.close();

      expect(unfinished.map((t) => t.id), ['open1']);
    });

    test('loadUnfinishedSnapshot — the list the step actually iterates — '
        'excludes Settled Outcomes', () async {
      await stageOneOfEach();

      await container
          .read(eveningShutdownProvider.notifier)
          .loadUnfinishedSnapshot();

      expect(
        container
            .read(eveningShutdownProvider)
            .unfinishedNav
            .items!
            .map((t) => t.id),
        ['open1'],
      );
    });

    test(
        'closeDay mints the implicit Dispositions: next → rollover, '
        'waitingFor / someday → leave', () async {
      final sessionId = await stageOneOfEach();

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.loadUnfinishedSnapshot();
      notifier.returnToNext('open1');
      await notifier.closeDay();

      final rollover =
          await db.focusSessionDao.getLastClosedSessionRolloverTaskIds();
      expect(rollover, ['next1'],
          reason: '"more work later" is what tomorrow expects to see');

      final planRows = await (db.select(db.focusSessionTasks)
            ..where((fst) => fst.focusSessionId.equals(sessionId)))
          .get();
      final byTask = {for (final r in planRows) r.taskId: r.disposition};
      expect(byTask['next1'], 'rollover');
      expect(byTask['wait1'], 'leave');
      expect(byTask['some1'], 'leave');
    });

    test(
        'a done-Settled Outcome gets no Disposition in either home — '
        'reviewAndCloseSession leaves that filter to its caller', () async {
      final sessionId = await stageOneOfEach();

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.loadUnfinishedSnapshot();
      notifier.returnToNext('open1');
      await notifier.closeDay();

      final planRow = await (db.select(db.focusSessionTasks)
            ..where((fst) =>
                fst.focusSessionId.equals(sessionId) &
                fst.taskId.equals('done1')))
          .getSingle();
      expect(planRow.disposition, isNull,
          reason: 'Completed Outcomes need no Disposition (CONTEXT.md)');

      final offPlan = await (db.select(db.focusSessionDispositions)
            ..where((d) => d.taskId.equals('done1')))
          .get();
      expect(offPlan, isEmpty);
    });

    test(
        'a someday-Settled Outcome takes `leave`, not `maybe` — its Intent was '
        'already set by the verdict and must not be re-stamped at close time',
        () async {
      await _insertTodo(db, id: 'some1', intent: 'maybe');
      final sessionId = await _openSessionWith(db, ['some1']);
      await _settleInSession(db, sessionId: sessionId, taskId: 'some1');
      final stampBefore = (await db.todoDao.getTodo('some1'))!.lastClarifiedAt;

      await container.read(eveningShutdownProvider.notifier).closeDay();

      final after = await db.todoDao.getTodo('some1');
      expect(after!.intent, 'maybe');
      expect(after.lastClarifiedAt, stampBefore,
          reason: 'the stamp belongs to the moment the user decided');
    });

    test('an off-Plan Settled Outcome lands its Disposition in the second '
        'home (ADR-0016) and still rolls over', () async {
      await _insertTodo(db, id: 'plan1');
      await _insertTodo(db, id: 'off1');
      final sessionId = await _openSessionWith(db, ['plan1']);
      await _settleInSession(db, sessionId: sessionId, taskId: 'off1');
      await _seedNextMove(db, 'off1');

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.loadUnfinishedSnapshot();
      notifier.returnToNext('plan1');
      await notifier.closeDay();

      final offPlan = await (db.select(db.focusSessionDispositions)
            ..where((d) => d.taskId.equals('off1')))
          .getSingle();
      expect(offPlan.disposition, 'rollover');
      expect(offPlan.focusSessionId, sessionId);
      expect(
        await db.focusSessionDao.getLastClosedSessionRolloverTaskIds(),
        contains('off1'),
      );
    });

    test('an explicit tap beats the implied Disposition', () async {
      await _insertTodo(db, id: 'next1');
      final sessionId = await _openSessionWith(db, ['next1']);
      await _settleInSession(db, sessionId: sessionId, taskId: 'next1');
      await _seedNextMove(db, 'next1');

      // The user reaches it anyway (it settled after the snapshot froze) and
      // chooses Someday. Their choice must win.
      final notifier = container.read(eveningShutdownProvider.notifier);
      notifier.deferTask('next1');
      await notifier.closeDay();

      expect(await db.focusSessionDao.getLastClosedSessionRolloverTaskIds(),
          isEmpty);
      final row = await db.todoDao.getTodo('next1');
      expect(row!.intent, 'maybe');
    });

    test('a second closeDay writes nothing — there is no open session left',
        () async {
      await _insertTodo(db, id: 'next1');
      final sessionId = await _openSessionWith(db, ['next1']);
      await _settleInSession(db, sessionId: sessionId, taskId: 'next1');
      await _seedNextMove(db, 'next1');

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.closeDay();
      final after = await db.select(db.focusSessionTasks).get();

      await notifier.closeDay();
      expect(await db.select(db.focusSessionTasks).get(), equals(after));
      expect(await db.select(db.focusSessionDispositions).get(), isEmpty);
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
