/// Adding an Outcome to Today's Plan during the day (issue #700).
///
/// Everything runs through the real Now screen and the real "Add to Today's
/// Plan" screen over a real in-memory store; only the database, the clock and
/// the notification service are overridden. The session opens at a fixed
/// instant with the default 480 available minutes, so "time left" is exact.
library;

import 'package:jeeves/widgets/outcome_row.dart';
import 'package:jeeves/providers/day_timeline_provider.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/add_to_plan/add_to_plan_screen.dart';
import 'package:jeeves/screens/focus_screen.dart';
import 'package:jeeves/screens/shutdown/steps/settled_review_step.dart';
import 'package:jeeves/screens/shutdown/steps/unfinished_tasks_step.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/widgets/added_during_the_day_tag.dart';

import '../helpers/settle.dart';
import '../test_helpers.dart';

const _userId = 'local';
final _sessionStart = DateTime.utc(2026, 11, 16, 8, 0);

Future<void> _insertOutcome(GtdDatabase db, String id,
    {int? estimate, String intent = 'next'}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        intent: Value(intent),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
        timeEstimate: Value(estimate),
      ));
  await seedCurrentAction(db,
      outcomeId: id, text: 'work on $id', userId: _userId);
  // The estimate an Outcome shows is its current Action's.
  if (estimate != null) {
    await db.customStatement(
        'UPDATE actions SET time_estimate = ? WHERE outcome_id = ?',
        [estimate, id]);
  }
}

/// A Plan row's title on Now. The same title also names the Outcome's tile on
/// the day timeline, so a bare `find.text` would find two.
Finder _nowRowTitle(String title) => find.descendant(
    of: find.byType(OutcomeRow), matching: find.text(title));

Widget _app(GtdDatabase db, {required DateTime now}) {
  final router = GoRouter(
    initialLocation: '/focus',
    routes: [
      GoRoute(path: '/focus', builder: (_, _) => const FocusScreen()),
      GoRoute(
          path: '/add-to-plan', builder: (_, _) => const AddToPlanScreen()),
      GoRoute(
        path: '/focus-session-planning',
        builder: (_, _) => const Scaffold(body: Text('planning')),
      ),
      GoRoute(
        path: '/inbox',
        builder: (_, _) => const Scaffold(body: Text('inbox-route')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      nowTimelineExtrasProvider.overrideWithValue(const NowTimelineExtras()),
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

Future<void> _openAddScreen(WidgetTester tester, GtdDatabase db,
    {required DateTime now}) async {
  await tester.pumpWidget(_app(db, now: now));
  await settleWithRealAsync(tester);
  final context = tester.element(find.byType(FocusScreen));
  GoRouter.of(context).push('/add-to-plan');
  await settleWithRealAsync(tester);
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late String sessionId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    await _insertOutcome(db, 'morning', estimate: 60);
    await _insertOutcome(db, 'later', estimate: 30);
    sessionId = await db.focusSessionDao
        .openSession(userId: _userId, taskIds: ['morning'], now: _sessionStart);
  });
  tearDown(() async => db.close());

  testWidgets('adding within the time left shows no warning and marks the row',
      (tester) async {
    await _openAddScreen(tester, db, now: _sessionStart);

    await tester.tap(find.byKey(const ValueKey('add_to_plan_row_later')));
    await tester.pump();
    expect(find.byKey(const Key('add_to_plan_warning')), findsNothing);
    expect(find.text('Add'), findsOneWidget);

    await tester.tap(find.byKey(const Key('add_to_plan_confirm')));
    await settleWithRealAsync(tester);

    // Back on Now: both Outcomes are on the Plan, only the added one is marked.
    expect(_nowRowTitle('Outcome morning'), findsOneWidget);
    expect(_nowRowTitle('Outcome later'), findsOneWidget);
    expect(find.byType(AddedDuringTheDayTag), findsOneWidget);
    expect(find.text(AddedDuringTheDayTag.label), findsOneWidget);

    await _dispose(tester);
  });

  testWidgets('over the time left it warns with both figures and still adds',
      (tester) async {
    // 6 hours into the 8-hour day: 120 minutes remain; 60 planned + 30 fits,
    // so make the candidate large.
    await db.customStatement(
        "UPDATE todos SET time_estimate = 90 WHERE id = 'later'");
    await db.customStatement(
        "UPDATE actions SET time_estimate = 90 WHERE outcome_id = 'later'");
    final lateInDay = _sessionStart.add(const Duration(hours: 6));
    await _openAddScreen(tester, db, now: lateInDay);

    await tester.tap(find.byKey(const ValueKey('add_to_plan_row_later')));
    await tester.pump();
    final warning = find.byKey(const Key('add_to_plan_warning'));
    expect(warning, findsOneWidget);
    expect(
      tester.widget<Text>(warning).data,
      contains('Estimates total 2h 30m; 2h remain.'),
    );
    expect(find.text('Add anyway'), findsOneWidget);

    await tester.tap(find.byKey(const Key('add_to_plan_confirm')));
    await settleWithRealAsync(tester);

    expect(_nowRowTitle('Outcome later'), findsOneWidget);
    expect(find.byType(AddedDuringTheDayTag), findsOneWidget);

    await _dispose(tester);
  });

  testWidgets('Evening Shutdown marks the added Outcome and not a morning one',
      (tester) async {
    await db.focusSessionDao.addOutcomeToPlan(
        sessionId: sessionId, taskId: 'later', now: _sessionStart);

    // Unfinished card: the morning Outcome is done, so the added one is up.
    await db.todoDao.markDone('morning');
    var host = ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(
          home: Scaffold(body: UnfinishedTasksStep())),
    );
    await tester.pumpWidget(host);
    await settleWithRealAsync(tester);
    expect(find.text('Outcome later'), findsWidgets);
    expect(find.byType(AddedDuringTheDayTag), findsOneWidget);
    await _dispose(tester);

    // Settled rows: both done, only the added one carries the mark.
    await db.todoDao.markDone('later');
    host = ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: Scaffold(body: SettledReviewStep())),
    );
    await tester.pumpWidget(host);
    await settleWithRealAsync(tester);
    expect(find.text('Outcome morning'), findsOneWidget);
    expect(find.text('Outcome later'), findsOneWidget);
    expect(find.byType(AddedDuringTheDayTag), findsOneWidget);
    await _dispose(tester);
  });

  test('engaging an off-Plan Outcome leaves the Plan unchanged', () async {
    await db.focusSessionDao
        .setCurrentTask(sessionId: sessionId, taskId: 'later');
    await db.focusSessionDao.setCurrentTask(sessionId: sessionId, taskId: null);

    final rows = await db.select(db.focusSessionTasks).get();
    expect(rows.map((r) => r.taskId), ['morning']);
    expect(rows.single.addedDuringExecutionAt, isNull);
    expect(
        await db.focusSessionDao
            .watchActiveSessionAddedDuringExecutionTaskIds()
            .first,
        isEmpty);
  });
}
