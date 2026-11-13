/// Route-level coverage of the Weekly Review's "Decide Bypassed Outcomes" step
/// (#107): the real screen over a real store, driven by taps.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/bypassed_outcomes_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/periodic_review_provider.dart';
import 'package:jeeves/screens/periodic_review/periodic_review_screen.dart';

import '../../helpers/settle.dart';
import '../../test_helpers.dart';

const _userId = 'local';

/// Real actions whose first Trash write fails, as a full disk would.
class _FlakyTrashActions extends BypassActions {
  _FlakyTrashActions(super.ref);
  bool failNext = true;

  @override
  Future<bool> trash(String outcomeId) {
    if (failNext) {
      failNext = false;
      throw StateError('disk full');
    }
    return super.trash(outcomeId);
  }
}

final _start = DateTime.utc(2030, 1, 10, 9);

Future<void> _stage(GtdDatabase db, List<String> ids) async {
  for (final id in ids) {
    await db.todoDao.insertOutcome(
        id: id, title: 'Outcome $id', userId: _userId, now: _start);
    await seedCurrentAction(db,
        outcomeId: id, text: 'work on $id', userId: _userId);
  }
  for (var i = 0; i < 3; i++) {
    final sessionId = await db.focusSessionDao.openSession(
      userId: _userId,
      taskIds: [],
      skippedTaskIds: ids.toSet(),
      now: _start.add(Duration(hours: 2 * i + 1)),
    );
    await db.focusSessionDao.closeSession(
        sessionId: sessionId, now: _start.add(Duration(hours: 2 * i + 2)));
  }
}

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late GtdDatabase db;
  late ProviderContainer container;

  Future<void> mount(WidgetTester tester, List<String> bypassed,
      {int? budgetMinutes, bool flakyTrash = false}) async {
    db = GtdDatabase(NativeDatabase.memory());
    await tester.runAsync(() => _stage(db, bypassed));
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        if (flakyTrash)
          bypassActionsProvider
              .overrideWith((ref) => _FlakyTrashActions(ref)),
      ],
    );
    final router = GoRouter(
      initialLocation: '/periodic-review',
      routes: [
        GoRoute(
          path: '/focus',
          builder: (_, _) => const Scaffold(body: Text('execution home')),
        ),
        GoRoute(
          path: '/periodic-review',
          builder: (_, _) => const PeriodicReviewScreen(),
        ),
      ],
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await settleWithRealAsync(tester);
    final notifier = container.read(periodicReviewProvider.notifier);
    await tester.runAsync(() async {
      await notifier.startSession(budgetMinutes: budgetMinutes);
      await notifier.goToStep(PeriodicReviewNotifier.kStepInbox);
      await notifier.advanceStep();
    });
    await settleWithRealAsync(tester, rounds: 2);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      container.dispose();
      await db.close();
    });
  }

  PeriodicReviewState state() => container.read(periodicReviewProvider);

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await settleWithRealAsync(tester, rounds: 2);
  }

  testWidgets(
      'taps decide each Outcome once; Back-only footer until all are decided; '
      'Back never re-offers a decided Outcome', (tester) async {
    await mount(tester, ['a', 'b']);

    expect(state().currentStep, PeriodicReviewNotifier.kStepBypassed);
    expect(find.text('Decide Bypassed Outcomes'), findsWidgets);
    expect(find.textContaining('Step 2 of 5'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(find.text('Next step'), findsNothing,
        reason: 'no Skip and no Next step until every Outcome is decided');

    final first = state().bypassedNextUndecided!.id;
    await tapKey(tester, 'bypassed_trash');
    expect(state().bypassedDecidedIds, {first});
    expect(find.text('Next step'), findsNothing);
    final second = state().bypassedNextUndecided!.id;
    expect(second, isNot(first));
    expect(find.textContaining('1 / 2 decided'), findsOneWidget);

    // Back crosses to Process Inbox; coming forward again lands on the second.
    await tester.tap(find.text('Back'));
    await settleWithRealAsync(tester, rounds: 2);
    expect(state().currentStep, PeriodicReviewNotifier.kStepInbox);
    await tester.runAsync(() => container
        .read(periodicReviewProvider.notifier)
        .advanceStep());
    await settleWithRealAsync(tester, rounds: 2);
    expect(state().bypassedNextUndecided!.id, second);

    await tapKey(tester, 'bypassed_someday_maybe');
    expect(state().bypassedAllDecided, isTrue);
    expect(find.text('All Bypassed Outcomes decided'), findsOneWidget);
    expect(find.text('Next step'), findsOneWidget);

    final rows = await tester.runAsync(() async => {
          'first': (await db.todoDao.getTodo(first))!.intent,
          'second': (await db.todoDao.getTodo(second))!.intent,
          'log': (await db.focusSessionDao.watchBypassDecisions().first).length,
        });
    expect(rows, {'first': 'trash', 'second': 'maybe', 'log': 2});

    // Completion-line Back does not re-offer a decided Outcome either.
    await tester.tap(find.text('Back'));
    await settleWithRealAsync(tester, rounds: 2);
    expect(state().currentStep, PeriodicReviewNotifier.kStepInbox);
    await close(tester);
  });

  testWidgets(
      'a short session shows only the ranked Bypassed Outcomes and the '
      'completion line counts the rest', (tester) async {
    final ids = [for (var i = 0; i < 10; i++) 'o$i'];
    await mount(tester, ids, budgetMinutes: 15);

    final inSession = state().bypassedNav.length;
    final deferred = state().bypassedDeferredCount;
    expect(inSession, lessThan(ids.length));
    expect(inSession + deferred, ids.length);

    for (var i = 0; i < inSession; i++) {
      await tapKey(tester, i.isEven ? 'bypassed_trash' : 'bypassed_someday_maybe');
    }
    expect(state().bypassedAllDecided, isTrue);
    expect(find.text('All Bypassed Outcomes decided'), findsOneWidget);
    expect(find.textContaining('$deferred more wait for a longer session'),
        findsOneWidget);

    // Leave the step and come back in the same process: still complete, and
    // no decided Outcome is offered again.
    await tester.tap(find.text('Back'));
    await settleWithRealAsync(tester, rounds: 2);
    await tester.runAsync(() =>
        container.read(periodicReviewProvider.notifier).advanceStep());
    await settleWithRealAsync(tester, rounds: 2);
    expect(state().currentStep, PeriodicReviewNotifier.kStepBypassed);
    expect(state().bypassedAllDecided, isTrue);
    expect(find.byKey(const Key('bypassed_trash')), findsNothing);
    await close(tester);
  });

  testWidgets(
      'leaving the route mid-step and reopening it resumes at the undecided '
      'Outcome', (tester) async {
    await mount(tester, ['a', 'b']);
    final first = state().bypassedNextUndecided!.id;
    await tapKey(tester, 'bypassed_trash');
    final second = state().bypassedNextUndecided!.id;
    expect(second, isNot(first));

    // Leave the route: the screen unmounts, the container (the app process)
    // stays.
    await tester.pumpWidget(const SizedBox.shrink());
    expect(find.text('Decide Bypassed Outcomes'), findsNothing);

    // Reopen the route in the same process.
    final router = GoRouter(
      initialLocation: '/periodic-review',
      routes: [
        GoRoute(
          path: '/focus',
          builder: (_, _) => const Scaffold(body: Text('execution home')),
        ),
        GoRoute(
          path: '/periodic-review',
          builder: (_, _) => const PeriodicReviewScreen(),
        ),
      ],
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await settleWithRealAsync(tester, rounds: 2);

    expect(state().currentStep, PeriodicReviewNotifier.kStepBypassed);
    expect(state().bypassedNextUndecided!.id, second,
        reason: 'the undecided Outcome resumes');
    expect(state().bypassedDecidedIds, {first},
        reason: 'the decided Outcome is not offered again');
    expect(find.byKey(const Key('bypassed_trash')), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(find.text('Next step'), findsNothing,
        reason: 'footer stays Back-only until every Outcome is decided');
    expect(find.text('All Bypassed Outcomes decided'), findsNothing);

    final log = await tester.runAsync(
        () => db.focusSessionDao.watchBypassDecisions().first);
    expect(log, hasLength(1), reason: 'no duplicate decision is recorded');
    await close(tester);
  });

  testWidgets(
      'a failed decision write explains itself, keeps the Outcome undecided '
      'and Back-only, and a retry logs exactly once', (tester) async {
    await mount(tester, ['a', 'b'], flakyTrash: true);
    final first = state().bypassedNextUndecided!.id;

    await tapKey(tester, 'bypassed_trash');
    expect(find.text("Couldn't save that decision. Try again."), findsOneWidget);
    expect(state().bypassedDecidedIds, isEmpty);
    expect(state().bypassedNextUndecided!.id, first);
    expect(find.text('Next step'), findsNothing);
    expect(find.text('Back'), findsOneWidget);
    var log = await tester.runAsync(
        () => db.focusSessionDao.watchBypassDecisions().first);
    expect(log, isEmpty);

    await tapKey(tester, 'bypassed_trash');
    expect(state().bypassedDecidedIds, {first});
    log = await tester.runAsync(
        () => db.focusSessionDao.watchBypassDecisions().first);
    expect(log, hasLength(1));
    await close(tester);
  });

  testWidgets(
      'the snackbar Retry still works after Back unmounts the step, and logs '
      'exactly once', (tester) async {
    await mount(tester, ['a', 'b'], flakyTrash: true);
    final first = state().bypassedNextUndecided!.id;

    await tapKey(tester, 'bypassed_trash');
    expect(find.text("Couldn't save that decision. Try again."), findsOneWidget);

    // Back leaves the step; the snackbar outlives it. The snackbar covers the
    // footer's Back button, so navigate through the notifier, which is what
    // that button calls.
    await container.read(periodicReviewProvider.notifier).previousStep();
    await settleWithRealAsync(tester, rounds: 2);
    expect(state().currentStep, PeriodicReviewNotifier.kStepInbox);
    expect(find.byKey(const Key('bypassed_trash')), findsNothing);

    await tester.tap(find.text('Retry'));
    await settleWithRealAsync(tester, rounds: 2);
    expect(tester.takeException(), isNull);
    expect(state().bypassedDecidedIds, {first});
    final log = await tester.runAsync(
        () => db.focusSessionDao.watchBypassDecisions().first);
    expect(log, hasLength(1));
    await close(tester);
  });

  testWidgets(
      'deleting the only Bypassed Outcome mid-step moves to Waiting For, '
      'records no decision, and Back skips the vanished step', (tester) async {
    await mount(tester, ['a']);
    await tester.runAsync(() => db.todoDao.deleteOutcome('a'));

    await tapKey(tester, 'bypassed_trash');
    expect(state().bypassedDecidedIds, isEmpty);
    expect(state().currentStep, PeriodicReviewNotifier.kStepWaitingFor);
    expect(find.text('Decide Bypassed Outcomes'), findsNothing);
    expect(find.textContaining('of 4'), findsOneWidget);
    final log = await tester.runAsync(
        () => db.focusSessionDao.watchBypassDecisions().first);
    expect(log, isEmpty);

    await container.read(periodicReviewProvider.notifier).previousStep();
    expect(state().currentStep, PeriodicReviewNotifier.kStepInbox);
    await close(tester);
  });

  testWidgets('a session with no Bypassed Outcome shows four steps',
      (tester) async {
    await mount(tester, []);
    expect(state().currentStep, PeriodicReviewNotifier.kStepWaitingFor);
    expect(find.textContaining('of 4'), findsOneWidget);
    await close(tester);
  });
}
