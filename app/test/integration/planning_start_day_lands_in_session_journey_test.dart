import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/models/ritual.dart';
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

/// Row 19: with no session left open from an earlier day, tapping Start Day lands in the
/// session just planned. The "Close your current session first" page must never
/// show, not even for a frame, although the open-session stream now carries the
/// session this very performance opened.
///
/// The screen's open-session stream is the real database's, bridged out of the
/// fake clock (a live Drift `watch()` inside widget fake time hangs the run, see
/// docs/TESTING.md). A frame is pumped after every single real-async turn, so a
/// redraw can land between the session opening and Start Day navigating.
///
/// Start Day's transaction continues on fake-zone microtasks, which only a pump
/// flushes: the test therefore drains it before closing the database, even
/// when an expectation has already failed, or `db.close()` would wait forever.
const _focusKey = Key('focus_route');
const _interstitial = 'Close your current session first';

void main() {
  setUpAll(configureSqliteForTests);

  /// Mounts the real planning route (reached from [initialLocation]) over a
  /// real database, runs [body], then tears everything down with the shared
  /// test budget: the Start Day transaction is drained first, so closing the
  /// database cannot wait on it.
  Future<void> withHarness(
    WidgetTester tester, {
    required String initialLocation,
    required Future<void> Function(
            GoRouter router, Future<void> Function() turn)
        body,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final db = GtdDatabase(NativeDatabase.memory());
    final openSessions = StreamController<FocusSession?>();
    StreamSubscription<FocusSession?>? bridge;
    await tester.runAsync(() async {
      bridge = db.focusSessionDao.watchActiveSession().listen(openSessions.add);
    });
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider
          .overrideWithValue(StubPeriodicReviewNotificationService()),
      activeSessionProvider.overrideWith((_) => openSessions.stream),
      // The draft resets to the intro step, whose counts are a live Drift read.
      focusSessionPlanningIntroCountsProvider
          .overrideWith((ref) async => (inboxCount: 0, reviewCount: 0)),
      // The Now screen's banner shows Daily Planning; what puts it there is
      // pinned by the banner row tests.
      inboxTooFullProvider.overrideWith((ref) => false),
      nudgeQueueProvider
          .overrideWith((ref) => const <RitualId>[RitualId.dailyPlanning]),
      nudgeBannerEnabledProvider.overrideWith((ref, r) => true),
    ]);
    final router = GoRouter(initialLocation: initialLocation, routes: [
      GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: NudgeBanner())),
      GoRoute(
          path: '/focus-session-planning',
          builder: (_, _) => const FocusSessionPlanningScreen()),
      GoRoute(
          path: '/focus', builder: (_, _) => const SizedBox(key: _focusKey)),
    ]);

    /// One real-async turn, then one frame.
    Future<void> turn() async {
      await tester.runAsync(() => pumpEventQueue(times: 1));
      await tester.pump();
    }

    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      await body(router, turn);
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

  /// Taps Start Day on the last step and checks every frame until the Now
  /// route shows: the interstitial must never appear.
  Future<void> startDayAndLand(
      WidgetTester tester, Future<void> Function() turn) async {
    await tester.tap(find.text('Start Day'));
    for (var i = 0; i < 300; i++) {
      await turn();
      expect(find.text(_interstitial), findsNothing,
          reason: 'frame after real-async turn $i');
      if (find.byKey(_focusKey).evaluate().isNotEmpty) break;
    }
    expect(find.byKey(_focusKey), findsOneWidget);
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

  testWidgets('row 19: banner, Daily Planning, Start Day lands in the new '
      'session, with no "session is open" page in any frame', (tester) async {
    await withHarness(tester, initialLocation: '/', body: (router, turn) async {
      expect(find.byKey(const Key('planning_banner_visible')), findsOneWidget);
      await tester.tap(find.byKey(const Key('planning_banner_visible')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      containerOf(tester)
          .read(focusSessionPlanningProvider.notifier)
          .goToStep(6);
      await settleWithRealAsync(tester);
      expect(find.text('Start Day'), findsOneWidget);
      await startDayAndLand(tester, turn);
    });
  });

  testWidgets('row 19 (frame by frame): Start Day on the planning route',
      (tester) async {
    await withHarness(tester,
        initialLocation: '/focus-session-planning',
        body: (router, turn) async {
      containerOf(tester)
          .read(focusSessionPlanningProvider.notifier)
          .goToStep(6);
      await settleWithRealAsync(tester);
      expect(find.text('Start Day'), findsOneWidget);
      await startDayAndLand(tester, turn);
    });
  });

  testWidgets('re-entering planning after Start Day, while that '
      'session is open, meets the Shutdown-first page', (tester) async {
    await withHarness(tester,
        initialLocation: '/focus-session-planning',
        body: (router, turn) async {
      containerOf(tester)
          .read(focusSessionPlanningProvider.notifier)
          .goToStep(6);
      await settleWithRealAsync(tester);
      await startDayAndLand(tester, turn);

      router.go('/focus-session-planning');
      for (var i = 0; i < 20; i++) {
        await turn();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text(_interstitial, skipOffstage: false), findsOneWidget,
          reason: 'on screen: ${tester.widgetList<Text>(find.byType(Text, skipOffstage: false)).map((t) => t.data).toList()}, '
              'planning route mounted: ${find.byType(FocusSessionPlanningScreen).evaluate().isNotEmpty}, '
              'started session id: ${containerOf(tester).read(focusSessionPlanningProvider).startedSessionId}');
    });
  });
}
