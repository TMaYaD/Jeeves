/// Journey (#107): an Outcome that FocusSessions keep passing over is decided
/// in the Weekly Review's "Decide Bypassed Outcomes" step, over a real store.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/bypassed_outcomes_provider.dart';
import 'package:jeeves/providers/periodic_review_provider.dart';

import '../helpers/periodic_review_test_helpers.dart';
import '../test_helpers.dart';

const _userId = 'local';
final _start = DateTime.utc(2030, 1, 10, 9);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    container = createPeriodicReviewTestContainer(db);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  PeriodicReviewNotifier review() =>
      container.read(periodicReviewProvider.notifier);
  PeriodicReviewState state() => container.read(periodicReviewProvider);

  Future<void> outcome(String id) async {
    await db.todoDao.insertOutcome(
      id: id,
      title: 'Outcome $id',
      userId: _userId,
      now: _start,
    );
    await seedCurrentAction(db,
        outcomeId: id, text: 'work on $id', userId: _userId);
  }

  /// Three Daily Plannings that each skip every id in [skipped].
  Future<void> passOver(Set<String> skipped) async {
    for (var i = 0; i < 3; i++) {
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: [],
        skippedTaskIds: skipped,
        now: _start.add(Duration(hours: 2 * i + 1)),
      );
      await db.focusSessionDao.closeSession(
          sessionId: sessionId, now: _start.add(Duration(hours: 2 * i + 2)));
    }
  }

  Future<void> toBypassedStep() async {
    await review().startSession();
    await review().goToStep(PeriodicReviewNotifier.kStepInbox);
    await review().advanceStep();
  }

  group('a session holding a Bypassed Outcome', () {
    setUp(() async {
      await outcome('a');
      await outcome('b');
      await outcome('plain');
      await passOver({'a', 'b'});
    });

    test('shows the Bypassed step after Process Inbox, and only there',
        () async {
      await review().loadAllSnapshots();
      await toBypassedStep();

      expect(state().currentStep, PeriodicReviewNotifier.kStepBypassed);
      expect(state().bypassedNav.items!.map((t) => t.id).toSet(), {'a', 'b'});
      expect(state().bypassedPassCounts['a'], 3);
      expect(state().nextNav.items!.map((t) => t.id), ['plain'],
          reason: 'a Bypassed Outcome is not also a Next item');
    });

    test('Someday/Maybe and Trash route the Outcome, log it and reset the '
        'count', () async {
      await review().loadAllSnapshots();
      await toBypassedStep();
      final actions = container.read(bypassActionsProvider);

      await actions.moveToSomedayMaybe('a');
      review().advanceBypassed();
      await actions.trash('b');
      review().advanceBypassed();

      expect(state().bypassedNav.isComplete, isTrue);
      final a = await db.todoDao.getTodo('a');
      final b = await db.todoDao.getTodo('b');
      expect(a!.intent, 'maybe');
      expect(b!.intent, 'trash');
      final log = await db.focusSessionDao.watchBypassDecisions().first;
      expect({for (final d in log) d.taskId: d.decision},
          {'a': 'maybe', 'b': 'trash'});
      expect(await db.focusSessionDao.getBypassedOutcomes(3), isEmpty);
    });

    test('Back from Review Waiting For returns to the Bypassed step',
        () async {
      await review().loadAllSnapshots();
      await toBypassedStep();
      await review().advanceStep();
      expect(state().currentStep, PeriodicReviewNotifier.kStepWaitingFor);
      await review().previousStep();
      expect(state().currentStep, PeriodicReviewNotifier.kStepBypassed);
    });

    test('a short session ranks the Bypassed Outcomes with the rest and '
        'counts the ones that wait', () async {
      for (var i = 0; i < 20; i++) {
        await outcome('extra-$i');
      }
      await review().loadAllSnapshots();
      // A 15-minute session holds 7 items; both Bypassed Outcomes rank first.
      await review().startSession(budgetMinutes: 15);
      expect(state().bypassedNav.length, 2);
      expect(state().bypassedDeferredCount, 0);
    });

    test('a session too short for every Bypassed Outcome defers the rest',
        () async {
      await outcome('c');
      await outcome('d');
      await outcome('e');
      await outcome('f');
      await outcome('g');
      await outcome('h');
      await passOver({'c', 'd', 'e', 'f', 'g', 'h'});
      await review().loadAllSnapshots();
      // 8 Bypassed Outcomes; a 15-minute session holds 7 items.
      await review().startSession(budgetMinutes: 15);
      expect(state().bypassedNav.length, 7);
      expect(state().bypassedDeferredCount, 1);
      expect(state().nextNav.items!.map((t) => t.id), isNot(contains('c')),
          reason: 'a deferred Bypassed Outcome is not a Next item either');
    });
  });

  test('a session with no Bypassed Outcome skips the step', () async {
    await outcome('plain');
    await review().loadAllSnapshots();
    await review().startSession();
    await review().goToStep(PeriodicReviewNotifier.kStepInbox);
    await review().advanceStep();
    expect(state().currentStep, PeriodicReviewNotifier.kStepWaitingFor);
    await review().previousStep();
    expect(state().currentStep, PeriodicReviewNotifier.kStepInbox);
  });
}
