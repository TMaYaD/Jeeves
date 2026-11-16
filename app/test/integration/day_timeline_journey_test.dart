import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/nudge_provider.dart';
import 'package:jeeves/providers/system_trust_provider.dart';
import 'package:jeeves/screens/planning/focus_session_planning_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/widgets/nudge_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/periodic_review_test_helpers.dart';
import '../helpers/settle.dart';
import '../test_helpers.dart';

/// The day timeline with no calendar, end to end: Today's Plan is drawn as
/// tiles on the planning completion screen, a time the user sets is fixed, and
/// Start Day writes it to the Plan entry — the only thing of the layout that is
/// stored.
///
/// The harness is the one `planning_start_day_lands_in_session_journey_test.dart`
/// documents: the real planning route over a real database, the open-session
/// stream bridged out of the fake clock, one frame after each real-async turn.
const _focusKey = Key('focus_route');

void main() {
  setUpAll(configureSqliteForTests);

  Future<void> withPlanningRoute(
    WidgetTester tester, {
    required Future<void> Function(
            GtdDatabase db,
            ProviderContainer container,
            Future<void> Function() turn)
        body,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final db = GtdDatabase(NativeDatabase.memory());
    final openSessions = StreamController<FocusSession?>();
    StreamSubscription<FocusSession?>? bridge;
    await tester.runAsync(() async {
      bridge = db.focusSessionDao.watchActiveSession().listen(openSessions.add);
      await db.todoDao.insertOutcome(
          id: 'report', title: 'Write the report', userId: 'local', timeEstimate: 30);
      await db.todoDao.insertOutcome(
          id: 'email', title: 'Answer email', userId: 'local', timeEstimate: 15);
    });
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider
          .overrideWithValue(StubPeriodicReviewNotificationService()),
      activeSessionProvider.overrideWith((_) => openSessions.stream),
      focusSessionPlanningIntroCountsProvider
          .overrideWith((ref) async => (inboxCount: 0, reviewCount: 0)),
      inboxTooFullProvider.overrideWith((ref) => false),
      nudgeQueueProvider.overrideWith((ref) => const <RitualId>[]),
      nudgeBannerEnabledProvider.overrideWith((ref, r) => false),
    ]);
    final router = GoRouter(initialLocation: '/focus-session-planning', routes: [
      GoRoute(
          path: '/focus-session-planning',
          builder: (_, _) => const FocusSessionPlanningScreen()),
      GoRoute(
          path: '/focus', builder: (_, _) => const SizedBox(key: _focusKey)),
    ]);

    Future<void> turn() async {
      await tester.runAsync(() => pumpEventQueue(times: 1));
      await tester.pump();
    }

    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      await body(db, container, turn);
    } finally {
      for (var i = 0; i < 60; i++) {
        await turn();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        container.dispose();
        await pumpEventQueue();
        await bridge?.cancel();
        unawaited(openSessions.close());
        await db.close();
      });
      router.dispose();
    }
  }

  Future<void> reachCompletionScreen(
      WidgetTester tester, ProviderContainer container) async {
    final planning = container.read(focusSessionPlanningProvider.notifier);
    planning.selectTasks(['report', 'email']);
    planning.setAvailableTime(240);
    planning.goToStep(6);
    await settleWithRealAsync(tester);
  }

  testWidgets('with no calendar, the Plan is drawn as tiles and nothing errors',
      (tester) async {
    await withPlanningRoute(tester, body: (db, container, turn) async {
      await reachCompletionScreen(tester, container);

      expect(find.byKey(const Key('day_timeline')), findsOneWidget);
      expect(find.byKey(const Key('day_timeline_tile_report_1')),
          findsOneWidget);
      expect(find.byKey(const Key('day_timeline_tile_email_1')),
          findsOneWidget);
      expect(find.textContaining('Error'), findsNothing);
      expect(find.textContaining('placeholder'), findsNothing);
      expect(find.byKey(const Key('day_timeline_tray')), findsNothing);
    });
  });

  testWidgets(
      'a time the user sets is fixed, and Start Day writes it to the Plan entry',
      (tester) async {
    await withPlanningRoute(tester, body: (db, container, turn) async {
      await reachCompletionScreen(tester, container);

      await tester.tap(find.byKey(const Key('day_timeline_tile_report_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('set_time_later')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('set_time_confirm')));
      await tester.tap(find.byKey(const Key('set_time_confirm')));
      await tester.pumpAndSettle();

      final pinned = container
          .read(focusSessionPlanningProvider)
          .pinnedStartByTaskId['report'];
      expect(pinned, isNotNull);
      expect(container
          .read(focusSessionPlanningProvider)
          .pinnedStartByTaskId
          .containsKey('email'), isFalse);

      await tester.ensureVisible(find.text('Start Day'));
      await tester.tap(find.text('Start Day'));
      for (var i = 0; i < 300; i++) {
        await turn();
        if (find.byKey(_focusKey).evaluate().isNotEmpty) break;
      }
      expect(find.byKey(_focusKey), findsOneWidget);

      final rows = (await tester
          .runAsync(() => db.select(db.focusSessionTasks).get()))!;
      final byTask = {for (final row in rows) row.taskId: row};
      expect(byTask['report']!.pinnedStartAt?.toUtc(), pinned!.toUtc());
      expect(byTask['email']!.pinnedStartAt, isNull);
    });
  });
}
