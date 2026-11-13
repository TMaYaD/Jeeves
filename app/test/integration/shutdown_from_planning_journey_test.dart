/// Journey: Evening Shutdown launched by Daily Planning ends without the
/// closing animation and continues straight into planning (#821); an ordinary
/// same-day shutdown keeps the moon-rise ending.
///
/// Real `/shutdown` route over a real in-memory database; only the database
/// and the notification service are overridden. The store is staged in
/// `setUp`, per docs/TESTING.md.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/planning/focus_session_planning_screen.dart';
import 'package:jeeves/screens/shutdown/shutdown_ritual_screen.dart';
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

const _userId = 'local';

/// Bounded stand-in for `pumpAndSettle`: with a staged open session the
/// ritual's live drift watch-streams keep a timer pending, so settling would
/// spin until the 10-minute default (docs/TESTING.md). Drain real async and
/// pump a fixed number of frames instead.
Future<void> _pumpFrames(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _insertOutcome(GtdDatabase db, String id,
    {bool completed = false}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Task $id'),
        userId: const Value(_userId),
        doneAt: Value(completed ? now.toIso8601String() : null),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
}

/// Skips the rollover preload and the inbox-snapshot DB work so the real
/// planning wizard does not start Drift reads that never settle under
/// fake-async (same stub as planning_blocked_start_gate_test.dart).
class _StubPlanningNotifier extends FocusSessionPlanningNotifier {
  @override
  FocusSessionPlanningState build() => const FocusSessionPlanningState();

  @override
  Future<void> loadInboxSnapshot() async {}
}

(Widget, ProviderContainer, GoRouter) _app(GtdDatabase db,
    {required String initialLocation}) {
  final container = ProviderContainer(overrides: [
    databaseProvider.overrideWithValue(db),
    notificationServiceProvider.overrideWithValue(StubNotificationService()),
    focusSessionPlanningProvider.overrideWith(() => _StubPlanningNotifier()),
    focusSessionPlanningIntroCountsProvider
        .overrideWith((ref) async => (inboxCount: 0, reviewCount: 0)),
  ]);
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/shutdown',
        builder: (_, _) => const ShutdownRitualScreen(),
      ),
      GoRoute(
        path: '/focus-session-planning',
        builder: (_, _) => const FocusSessionPlanningScreen(),
      ),
    ],
  );
  return (
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
    container,
    router,
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  Future<void> stage({required bool completed}) async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    await _insertOutcome(db, 't1', completed: completed);
    await db.focusSessionDao.openSession(userId: _userId, taskIds: ['t1']);
  }

  Future<void> expectCommitted(WidgetTester tester,
      {required bool rolledOver}) async {
    final active = await tester.runAsync(db.focusSessionDao.getActiveSession);
    expect(active, isNull, reason: 'Close Day still closes the session');
    final rollover = await tester
        .runAsync(db.focusSessionDao.getLastClosedSessionRolloverTaskIds);
    if (rolledOver) {
      expect(rollover, contains('t1'),
          reason: 'the unfinished Outcome is still rolled over');
    } else {
      expect(rollover, isNot(contains('t1')));
    }
    final ended = await tester.runAsync(() => (db.select(db.focusSessions)
          ..where((s) => s.endedAt.isNotNull()))
        .get());
    expect(ended, hasLength(1), reason: 'the staged session has ended_at');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('shutdown_ritual_completed_date'), planningToday(),
        reason: 'the completion date is stored');
  }

  /// Disposing the container cancels the live drift streams, which schedules
  /// a zero-duration timer; it must fire inside the test body or the binding
  /// reports a pending timer.
  Future<void> disposeContainer(
      WidgetTester tester, ProviderContainer container) async {
    container.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
  }

  void expectNoClosingAnimation() {
    expect(find.byIcon(Icons.nightlight_round), findsNothing);
    expect(find.text('Close Day'), findsNothing);
    expect(find.text('Review Your Day'), findsNothing,
        reason: 'the Review step must not flash through the reset');
  }

  Future<void> runForgottenShutdown(
    WidgetTester tester, {
    required bool unfinished,
  }) async {
    final (widget, container, router) =
        _app(db, initialLocation: '/focus-session-planning');

    await tester.pumpWidget(widget);
    await _pumpFrames(tester);
    // Daily Planning blocks on the still-open session; enter through its
    // real interstitial rather than setting the intent by hand.
    expect(find.text('Close your current session first'), findsOneWidget);
    await tester.tap(find.text('Begin Evening Shutdown'));
    await _pumpFrames(tester);
    expect(find.text('Review Your Day'), findsOneWidget);

    await tester.tap(find.text('Next step'));
    await _pumpFrames(tester);
    if (unfinished) {
      await tester.tap(find.text('Roll Over'));
    }
    // Only a few frames: no waiting out the 1.6 s entrance.
    await tester.pump();
    expectNoClosingAnimation();
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      expectNoClosingAnimation();
    }

    expect(router.routeInformationProvider.value.uri.path,
        '/focus-session-planning');
    expect(container.read(shutdownThenPlanProvider), isFalse);
    await expectCommitted(tester, rolledOver: unfinished);
    await unmount(tester);
    await disposeContainer(tester, container);
  }

  group('forgotten shutdown with an unfinished Outcome', () {
    setUp(() => stage(completed: false));
    tearDown(() async => db.close());

    testWidgets(
        'launched by Daily Planning: no moon, phrase or Close Day button; '
        'commits and lands in planning',
        (tester) => runForgottenShutdown(tester, unfinished: true));

    testWidgets(
        'same day: moon and Close Day button, tap does not open planning',
        (tester) async {
      final (widget, container, router) =
          _app(db, initialLocation: '/shutdown');

      await tester.pumpWidget(widget);
      await _pumpFrames(tester);
      await tester.tap(find.text('Next step'));
      await _pumpFrames(tester);
      await tester.tap(find.text('Roll Over to Tomorrow'));
      await tester.runAsync(() => pumpEventQueue());
      // First frame mounts the step (its ticker starts there), then wait out
      // the 1.6 s entrance.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1700));
      await tester.pump();

      expect(find.byIcon(Icons.nightlight_round), findsWidgets);
      await tester.tap(find.text('Close Day'));
      for (var i = 0; i < 6; i++) {
        await tester.pump();
        await tester.runAsync(() => pumpEventQueue());
      }
      expect(router.routeInformationProvider.value.uri.path, '/shutdown');
      await expectCommitted(tester, rolledOver: true);

      // Unmount before the fade-out ends so the real closeApp() is not called.
      await unmount(tester);
      await disposeContainer(tester, container);
    });

    testWidgets('abandoned sequenced shutdown does not leak the intent',
        (tester) async {
      final (widget, container, _) =
          _app(db, initialLocation: '/focus-session-planning');

      await tester.pumpWidget(widget);
      await _pumpFrames(tester);
      await tester.tap(find.text('Begin Evening Shutdown'));
      await _pumpFrames(tester);
      expect(container.read(shutdownThenPlanProvider), isTrue);
      await unmount(tester);

      expect(container.read(shutdownThenPlanProvider), isFalse);
      await disposeContainer(tester, container);
    });
  });

  group('forgotten shutdown with every Outcome completed', () {
    setUp(() => stage(completed: true));
    tearDown(() async => db.close());

    testWidgets('goes straight from Review to planning without animation',
        (tester) => runForgottenShutdown(tester, unfinished: false));
  });
}
