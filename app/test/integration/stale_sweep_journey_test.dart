/// The **Stale sweep** journey (#107), end to end over a real store.
///
/// An Outcome the user keeps passing over — skipped in Daily Planning, left
/// untouched on a Plan, its due date pushed later, or left unclarified after its
/// Action finished — becomes **Stale** after enough FocusSessions, and the next
/// Daily Planning asks the user to move it to Someday/Maybe or Trash it. Every
/// write goes through the production seams (`openSession`, `closeSession`,
/// `TodoDao.rescheduleTask`, the sweep notifier). Per docs/TESTING.md the store
/// is staged in plain `test`s, outside any FakeAsync zone.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/stale_sweep_provider.dart';

import '../test_helpers.dart';

const _userId = 'local';

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;
  // Sessions all start after "now" so the Action completions staged below
  // (stamped with the real clock) fall before them.
  final firstSessionAt = DateTime.now().toUtc().add(const Duration(days: 1));
  var sessionCount = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
    ]);
    sessionCount = 0;
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> insertOutcome(
    String id, {
    DateTime? dueDate,
    bool withAction = true,
  }) async {
    final now = DateTime.now();
    await db.into(db.todos).insert(TodosCompanion(
          id: Value(id),
          title: Value('Outcome $id'),
          clarified: const Value(true),
          intent: const Value('next'),
          userId: const Value(_userId),
          dueDate: Value(dueDate),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
    if (withAction) {
      await seedCurrentAction(db,
          outcomeId: id, text: 'work on $id', userId: _userId);
    }
  }

  DateTime nextSessionTime() =>
      firstSessionAt.add(Duration(hours: 2 * sessionCount++));

  /// One FocusSession: opens with [plan] (skipping [skipped]), runs [during]
  /// while it is open, then closes.
  Future<void> runSession({
    List<String> plan = const [],
    Set<String> skipped = const {},
    Future<void> Function(DateTime sessionStart)? during,
  }) async {
    final start = nextSessionTime();
    final sessionId = await db.focusSessionDao.openSession(
      userId: _userId,
      taskIds: plan,
      skippedTaskIds: skipped,
      now: start,
    );
    await during?.call(start);
    await db.focusSessionDao.closeSession(
      sessionId: sessionId,
      now: start.add(const Duration(hours: 1)),
    );
  }

  Future<Set<String>> staleIds([int threshold = 3]) async =>
      (await db.focusSessionDao.getStaleOutcomes(threshold))
          .map((s) => s.outcome.id)
          .toSet();

  test('skipped, left untouched, and rescheduled — three sessions make it '
      'Stale, and Move to Someday/Maybe clears it and logs the decision',
      () async {
    await insertOutcome('a', dueDate: DateTime.utc(2030, 1, 1));

    await runSession(skipped: {'a'});
    expect(await staleIds(), isEmpty, reason: 'one pass-over is not Stale');

    await runSession(plan: ['a']);
    expect(await staleIds(), isEmpty);

    await runSession(plan: ['a'], during: (start) async {
      await db.todoDao.rescheduleTask(
        'a',
        DateTime.utc(2030, 2, 1),
        now: start.add(const Duration(minutes: 5)),
      );
    });
    expect(await staleIds(), {'a'});

    final shown = container.read(staleOutcomesProvider.future);
    expect((await shown).single.passedOverSessionCount, 3);

    await container.read(staleSweepProvider).moveToSomedayMaybe('a');

    final todo = await (db.select(db.todos)..where((t) => t.id.equals('a')))
        .getSingle();
    expect(todo.intent, 'maybe');
    expect(await staleIds(), isEmpty);
    final log = await db.select(db.outcomeSweepDecisions).get();
    expect(log.single.taskId, 'a');
    expect(log.single.decision, 'maybe');
    expect(await container.read(staleOutcomesProvider.future), isEmpty);
  });

  test('Trash routes the Outcome to Trash and logs it', () async {
    await insertOutcome('t');
    for (var i = 0; i < 3; i++) {
      await runSession(skipped: {'t'});
    }
    expect(await staleIds(), {'t'});

    await container.read(staleSweepProvider).trash('t');

    final todo = await (db.select(db.todos)..where((t) => t.id.equals('t')))
        .getSingle();
    expect(todo.intent, 'trash');
    expect((await db.select(db.outcomeSweepDecisions).get()).single.decision,
        'trash');
  });

  test('left unclarified after its Action finished counts; re-clarifying '
      'stops the count', () async {
    await insertOutcome('c');
    await insertOutcome('d');
    await db.actionDao.completeCurrentAction('c');
    await db.actionDao.completeCurrentAction('d');

    await runSession();
    await runSession();
    // "Still relevant" on d after the second Planning.
    await db.todoDao.stampLastClarifiedAt('d',
        now: firstSessionAt.add(const Duration(days: 1)));
    await runSession();

    expect(await staleIds(), {'c'},
        reason: 'c was left unclarified through three Plannings; d was not');
  });

  test('engaging with an Outcome resets its count', () async {
    await insertOutcome('b');
    await runSession(skipped: {'b'});
    await runSession(skipped: {'b'});
    // A stint on b after the second pass-over.
    final stintAt = firstSessionAt.add(const Duration(days: 1));
    await db.into(db.timeLogs).insert(TimeLogsCompanion(
          id: const Value('log-b'),
          userId: const Value(_userId),
          taskId: const Value('b'),
          startedAt: Value(stintAt.toIso8601String()),
          endedAt: Value(
              stintAt.add(const Duration(minutes: 20)).toIso8601String()),
        ));
    sessionCount = 24; // later than the stint
    await runSession(skipped: {'b'});

    expect(await staleIds(), isEmpty,
        reason: 'only one pass-over since the stint');
  });

  test('the threshold setting changes what is Stale', () async {
    await insertOutcome('s');
    await runSession(skipped: {'s'});
    await runSession(skipped: {'s'});

    expect(await staleIds(3), isEmpty);
    expect(await staleIds(2), {'s'});
  });

  for (final choice in ['Someday/Maybe', 'Trash']) {
    test('sweeping a rolled-over Stale Outcome ($choice) takes it off the '
        'draft Plan, even when a rollover preload is in flight', () async {
      await insertOutcome('r');
      await runSession(skipped: {'r'});
      await runSession(plan: ['r']);
      late String lastSessionId;
      await runSession(plan: ['r'], during: (_) async {
        lastSessionId = (await db.focusSessionDao.getActiveSession())!.id;
        await db.focusSessionDao.setTaskDisposition(
          sessionId: lastSessionId,
          taskId: 'r',
          disposition: 'rollover',
        );
      });
      expect(await staleIds(), {'r'});

      final planning = container.read(focusSessionPlanningProvider.notifier);
      await planning.ensureRolloverPreload();
      expect(container.read(focusSessionPlanningProvider).pendingSelectedTaskIds,
          contains('r'),
          reason: 'the rollover default pre-selects it');

      final inFlight = planning.ensureRolloverPreload();
      final sweep = container.read(staleSweepProvider);
      choice == 'Trash'
          ? await sweep.trash('r')
          : await sweep.moveToSomedayMaybe('r');
      await inFlight;
      await planning.ensureRolloverPreload();

      expect(container.read(focusSessionPlanningProvider).pendingSelectedTaskIds,
          isNot(contains('r')),
          reason: 'startDay commits pendingSelectedTaskIds as the Plan');
    });
  }
}
