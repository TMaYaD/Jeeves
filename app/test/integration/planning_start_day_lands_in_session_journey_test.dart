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
/// The open-session stream is the real database's, bridged out of the fake
/// clock (a live Drift `watch()` inside widget fake time hangs the run, see
/// docs/TESTING.md), and a frame is pumped after every single real-async turn
/// so a redraw can land between the session opening and Start Day navigating.
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
      bridge = db.focusSessionDao.watchActiveSession().listen(
            openSessions.add,
          );
    });
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider
          .overrideWithValue(StubPeriodicReviewNotificationService()),
      activeSessionProvider.overrideWith((_) => openSessions.stream),
    ]);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const FocusSessionPlanningScreen()),
      GoRoute(
          path: '/focus', builder: (_, _) => const SizedBox(key: _focusKey)),
    ]);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      container.read(focusSessionPlanningProvider.notifier).goToStep(6);
      await settleWithRealAsync(tester);
      expect(find.text('Start Day'), findsOneWidget);

      await tester.tap(find.text('Start Day'));
      for (var turn = 0; turn < 200; turn++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(find.text('Close your current session first'), findsNothing,
            reason: 'frame after real-async turn $turn');
        if (find.byKey(_focusKey).evaluate().isNotEmpty) break;
      }
      expect(find.byKey(_focusKey), findsOneWidget);
      final session = await tester.runAsync(db.focusSessionDao.getActiveSession);
      expect(session, isNotNull, reason: 'the session was opened');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      // The container's stream listener lives in the fake-async zone, so
      // awaiting the controller's close here would never complete: drop the
      // listener first and let the close finish on its own.
      container.dispose();
      await tester.runAsync(() async {
        await bridge?.cancel();
        unawaited(openSessions.close());
        await db.close();
      });
      router.dispose();
    }
  });
}
