/// Journey: every Outcome is done but a Habit is still open for the day, so
/// ending the session from Now shows only the habit step, then closes the
/// session (#405). Real Now screen and real ritual screen over a real in-memory
/// store; only the database and the notification service are overridden.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/day_timeline_provider.dart';
import 'package:jeeves/screens/focus_screen.dart';
import 'package:jeeves/screens/shutdown/shutdown_ritual_screen.dart';
import 'package:jeeves/services/clarification_service.dart';
import 'package:jeeves/services/notification_service.dart';

import '../helpers/settle.dart';
import '../test_helpers.dart';

const _userId = 'local';

Widget _app(GtdDatabase db) {
  final router = GoRouter(
    initialLocation: '/focus',
    routes: [
      GoRoute(path: '/focus', builder: (_, _) => const FocusScreen()),
      GoRoute(
        path: '/focus-session-planning',
        builder: (_, _) => const Scaffold(body: Text('planning')),
      ),
      GoRoute(
        path: '/shutdown',
        builder: (_, state) => ShutdownRitualScreen(
          habitsOnly: state.uri.queryParameters['habitsOnly'] == '1',
        ),
      ),
      GoRoute(
        path: '/inbox',
        builder: (_, _) => const Scaffold(body: Text('inbox-route')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
      nowTimelineExtrasProvider.overrideWithValue(const NowTimelineExtras()),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late String habitId;

  /// A session whose only Outcome is done, and a Habit due every day, with a
  /// Check-in already today when [habitDone].
  Future<void> stage({required bool habitDone}) async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    final now = DateTime.now();
    await db.into(db.todos).insert(TodosCompanion(
          id: const Value('plan'),
          title: const Value('Outcome plan'),
          intent: const Value('next'),
          userId: const Value(_userId),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
    await seedCurrentAction(db,
        outcomeId: 'plan', text: 'work on plan', userId: _userId);
    await db.focusSessionDao.openSession(userId: _userId, taskIds: ['plan']);
    await DaoClarificationService(db).completeOutcome('plan');
    habitId = await db.habitDao.createHabit(
      userId: _userId,
      title: 'Stretch',
      today: habitDayKey(now),
      now: now.toUtc(),
      firstCommitment:
          const HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay),
    );
    if (habitDone) {
      await db.habitDao.addCheckIn(
          habitId: habitId,
          userId: _userId,
          countsForDay: habitDayKey(now),
          now: now.toUtc());
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  Future<void> endSession(WidgetTester tester) async {
    await tester.pumpWidget(_app(db));
    await settleWithRealAsync(tester);
    await tester.ensureVisible(find.text('End Session'));
    await tester.tap(find.text('End Session'));
    await settleWithRealAsync(tester, rounds: 2);
  }

  group('all Outcomes done, a Habit open', () {
    setUp(() => stage(habitDone: false));
    tearDown(() async => db.close());

    testWidgets('shows only the habit step; Close the day closes the session '
        'and lands on the inbox (AC 4)', (tester) async {
      await endSession(tester);

      expect(find.text('Review Your Day'), findsNothing);
      expect(find.text('Resolve Unfinished'), findsNothing);
      expect(find.byKey(Key('shutdown_habit_row_$habitId')), findsOneWidget);
      // The session is still open while the habit step is up.
      expect(
          await tester.runAsync(() => db.focusSessionDao.getActiveSession()),
          isNotNull);

      await tester.tap(find.byKey(Key('shutdown_habit_toggle_$habitId')));
      await settleWithRealAsync(tester, rounds: 2);
      expect(find.text('Close the day'), findsOneWidget);
      await tester.tap(find.text('Close the day'));
      await settleWithRealAsync(tester, rounds: 2);

      expect(find.text('inbox-route'), findsOneWidget);
      expect(
          await tester.runAsync(() => db.focusSessionDao.getActiveSession()),
          isNull);
      final checkIns = await tester.runAsync(() => db.habitDao
          .checkInsFor(habitId, '2000-01-01', '2999-12-31'));
      expect(checkIns, hasLength(1));

      await unmount(tester);
    });

    testWidgets('Back returns to Now with the session still open',
        (tester) async {
      await endSession(tester);
      expect(find.byKey(Key('shutdown_habit_row_$habitId')), findsOneWidget);

      await tester.tap(find.byKey(const Key('shutdown_back')));
      await settleWithRealAsync(tester, rounds: 2);

      expect(find.text('End Session'), findsOneWidget);
      expect(
          await tester.runAsync(() => db.focusSessionDao.getActiveSession()),
          isNotNull);

      await unmount(tester);
    });
  });

  group('all Outcomes done, no Habit open', () {
    setUp(() => stage(habitDone: true));
    tearDown(() async => db.close());

    testWidgets('End Session closes directly, as before', (tester) async {
      await endSession(tester);

      expect(find.text('inbox-route'), findsOneWidget);
      expect(
          await tester.runAsync(() => db.focusSessionDao.getActiveSession()),
          isNull);

      await unmount(tester);
    });
  });
}
