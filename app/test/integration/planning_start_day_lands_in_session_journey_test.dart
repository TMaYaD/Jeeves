import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/planning/focus_session_planning_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/periodic_review_test_helpers.dart';
import '../helpers/settle.dart';
import '../test_helpers.dart';

/// Row 19: with no carried-over session, tapping Start Day lands in the
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

void main() {
  setUpAll(configureSqliteForTests);

  testWidgets('row 19: Start Day lands in the new session, with no '
      '"session is open" page in any frame', (tester) async {
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
    ]);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const FocusSessionPlanningScreen()),
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
      container.read(focusSessionPlanningProvider.notifier).goToStep(6);
      await settleWithRealAsync(tester);
      expect(find.text('Start Day'), findsOneWidget);

      await tester.tap(find.text('Start Day'));
      for (var i = 0; i < 300; i++) {
        await turn();
        expect(find.text('Close your current session first'), findsNothing,
            reason: 'frame after real-async turn $i');
        if (find.byKey(_focusKey).evaluate().isNotEmpty) break;
      }
      expect(find.byKey(_focusKey), findsOneWidget);
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
        await db.close().timeout(const Duration(seconds: 10), onTimeout: () {});
      });
      router.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
