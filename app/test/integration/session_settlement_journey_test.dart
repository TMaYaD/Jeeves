/// The **Settled** journey (#693, #694), end to end over a real store.
///
/// A user works a Focus session, finishes a task's current Action, and gives it
/// a verdict other than "achieved". From that moment the task is handled *for
/// this session*: it strikes off on the Now screen, it is not offered as the
/// next task up, Evening Shutdown does not ask about it again, and it appears
/// in the day's summary under the verdict it was given.
///
/// Every write here goes through the production seams the re-clarify sheet
/// itself commits — `ClarificationService.completeCurrentAction` for the Done,
/// `clarifyToOutcome` for the verdict — so the journey is evidence about the
/// real flow rather than about a fixture. The blank-save group goes one level
/// further and taps the sheet itself, because there the behaviour under test
/// lives in the widget (ADR-0049's title-as-action fallback) rather than on the
/// service. Per docs/TESTING.md the store is staged in `setUp`, never inside a
/// `testWidgets` body.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/daos/focus_session_dao.dart'
    show SessionSettlement;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show RoutingKind;
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/evening_shutdown_provider.dart'
    show eveningShutdownProvider, sessionSettlementGroupsProvider;
import 'package:jeeves/screens/active_focus_screen.dart' show focusNextTask;
import 'package:jeeves/screens/focus_screen.dart';
import 'package:jeeves/services/clarification_service.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/widgets/reclarify_prompt_sheet.dart';

import '../helpers/settle.dart';
import '../test_helpers.dart';

const _userId = 'local';

Future<void> _insertOutcome(
  GtdDatabase db, {
  required String id,
  required String title,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        clarified: const Value(true),
        intent: const Value('next'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  await seedCurrentAction(db,
      outcomeId: id, text: 'work on $title', userId: _userId);
}

/// Renders the real Now screen over [db] — no provider is stubbed except the
/// database itself, so the Settlement signal is read live from the store.
Widget _nowScreen(GtdDatabase db) {
  final router = GoRouter(
    initialLocation: '/focus',
    routes: [
      GoRoute(path: '/focus', builder: (_, _) => const FocusScreen()),
      GoRoute(
        path: '/focus-session-planning',
        builder: (_, _) => const Scaffold(body: Text('planning')),
      ),
      GoRoute(
        path: '/focus/active',
        builder: (_, _) => const Scaffold(body: Text('active')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  group('a task resolved to "more work later" is Settled for the session', () {
    late GtdDatabase db;
    late ClarificationService clarification;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = GtdDatabase(NativeDatabase.memory());
      clarification = DaoClarificationService(db);

      await _insertOutcome(db, id: 'resolved', title: 'Draft the proposal');
      await _insertOutcome(db, id: 'untouched', title: 'Book the venue');
      final sessionId = await db.focusSessionDao
          .openSession(userId: _userId, taskIds: ['resolved', 'untouched']);

      // Engage it: a session-attributed TimeLog against its current Action.
      await db.focusSessionDao
          .setCurrentTask(sessionId: sessionId, taskId: 'resolved');
      // Focus "Done" — completes the *Action*, stamps nothing on the Outcome.
      await clarification.completeCurrentAction('resolved');
      // …then the verdict the re-clarify sheet takes: "More to do…".
      await clarification.clarifyToOutcome(
        'resolved',
        to: RoutingKind.nextAction,
        actionText: 'send it to Trixy for review',
        userId: _userId,
      );
    });

    tearDown(() async => db.close());

    test('the store reports it Settled as next, and the other task not at all',
        () async {
      expect(
        await db.focusSessionDao.getActiveSessionSettlements(),
        {'resolved': SessionSettlement.next},
      );
    });

    test('its Outcome is not achieved — Settlement is not Completion',
        () async {
      final row = await db.todoDao.getTodo('resolved');
      expect(row?.doneAt, isNull);
    });

    test('it still sits on its normal GTD List outside the session (AC5)',
        () async {
      final next = await db.todoDao.watchNext().first;
      expect(next.map((t) => t.id), contains('resolved'));
    });

    test('it is not offered as the next task up (AC2)', () async {
      final tasks = await db.focusSessionDao.getReviewSurface(
        (await db.focusSessionDao.getActiveSession())!.id,
      );
      final settlements =
          await db.focusSessionDao.getActiveSessionSettlements();
      expect(
        focusNextTask(
          sessionTasks: tasks,
          completedTodoId: 'resolved',
          settlements: settlements,
        )?.id,
        'untouched',
      );
    });

    testWidgets('it is struck off on the Now screen, with no Start (AC1)',
        (tester) async {
      await tester.pumpWidget(_nowScreen(db));
      await settleWithRealAsync(tester);

      final struck = tester.widget<Text>(find.text('Draft the proposal'));
      expect(struck.style?.decoration, TextDecoration.lineThrough);
      final live = tester.widget<Text>(find.text('Book the venue'));
      expect(live.style?.decoration, isNot(TextDecoration.lineThrough));
      expect(find.text('Start'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    test('Evening Shutdown does not ask about it again (#694 AC4)', () async {
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider
            .overrideWithValue(StubNotificationService()),
      ]);
      addTearDown(container.dispose);

      await container
          .read(eveningShutdownProvider.notifier)
          .loadUnfinishedSnapshot();
      final snapshot =
          container.read(eveningShutdownProvider).unfinishedNav.items!;
      expect(snapshot.map((t) => t.id), ['untouched'],
          reason: 'the disposition step only presents unhandled work');
    });

    test('it appears in the day\'s summary under the re-planned group '
        '(#694 AC3)', () async {
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider
            .overrideWithValue(StubNotificationService()),
      ]);
      addTearDown(container.dispose);

      final sub = container.listen(sessionSettlementGroupsProvider, (_, _) {});
      final groups = await container
          .read(sessionSettlementGroupsProvider.future)
          .timeout(const Duration(seconds: 5));
      sub.close();

      expect(groups.keys, [SessionSettlement.next]);
      expect(groups[SessionSettlement.next]!.map((t) => t.id), ['resolved']);
    });

    test('and it carries over: Close Day mints the implicit rollover', () async {
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider
            .overrideWithValue(StubNotificationService()),
      ]);
      addTearDown(container.dispose);

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.loadUnfinishedSnapshot();
      notifier.returnToNext('untouched');
      await notifier.closeDay();

      final rollover =
          await db.focusSessionDao.getLastClosedSessionRolloverTaskIds();
      expect(rollover, contains('resolved'),
          reason: '"more work later" is exactly what tomorrow expects to see');
      expect(rollover, isNot(contains('untouched')));
    });
  });

  group('a blank "More to do" save settles it just the same', () {
    late GtdDatabase db;
    late ClarificationService clarification;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = GtdDatabase(NativeDatabase.memory());
      clarification = DaoClarificationService(db);

      await _insertOutcome(db, id: 'blank', title: 'Chase the invoice');
      final sessionId = await db.focusSessionDao
          .openSession(userId: _userId, taskIds: ['blank']);
      await db.focusSessionDao
          .setCurrentTask(sessionId: sessionId, taskId: 'blank');
      await clarification.completeCurrentAction('blank');
    });

    tearDown(() async => db.close());

    testWidgets('the row settles as next even though the dialog was saved '
        'empty (#691)', (tester) async {
      // The one case in this file driven through the sheet rather than the
      // service seam: what settles the row is the *title-as-action fallback*
      // ADR-0049 put inside `ProcessToHandlers._nextWithDialog`, so composing
      // its writes by hand here would assert nothing about the flow. The user
      // knows there is more to do and cannot name it; the Outcome's own title
      // stands in, `applyRouting` stamps `last_clarified_at` at or after the
      // Action completion, and arm (b) of Settled is satisfied.
      await _saveMoreToDoBlank(tester, db, (await db.todoDao.getTodo('blank'))!);

      expect(
        await db.focusSessionDao.getActiveSessionSettlements(),
        {'blank': SessionSettlement.next},
      );
    });
  });
}

/// Floats the real re-clarify sheet over [db], answers "More to do…", and
/// saves the next-action dialog without typing anything — the exact taps the
/// Focus screen's Done button leads to.
Future<void> _saveMoreToDoBlank(
  WidgetTester tester,
  GtdDatabase db,
  Todo todo,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => ReclarifyPromptSheet.show(context, todo),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('More to do…'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}
