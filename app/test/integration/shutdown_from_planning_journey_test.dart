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
import 'package:jeeves/screens/shutdown/shutdown_ritual_screen.dart';
import 'package:jeeves/services/notification_service.dart';

import '../helpers/settle.dart';
import '../test_helpers.dart';

const _userId = 'local';

Future<void> _insertOutcome(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Task $id'),
        clarified: const Value(true),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
}

(Widget, ProviderContainer) _app(GtdDatabase db) {
  final container = ProviderContainer(overrides: [
    databaseProvider.overrideWithValue(db),
    notificationServiceProvider.overrideWithValue(StubNotificationService()),
  ]);
  final router = GoRouter(
    initialLocation: '/shutdown',
    routes: [
      GoRoute(
        path: '/shutdown',
        builder: (_, _) => const ShutdownRitualScreen(),
      ),
      GoRoute(
        path: '/focus-session-planning',
        builder: (_, _) => const Scaffold(body: Text('planning')),
      ),
    ],
  );
  return (
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
    container,
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late String sessionId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    await _insertOutcome(db, 't1');
    sessionId =
        await db.focusSessionDao.openSession(userId: _userId, taskIds: ['t1']);
  });
  tearDown(() async => db.close());

  Future<void> expectSessionClosed(WidgetTester tester) async {
    final active = await tester.runAsync(db.focusSessionDao.getActiveSession);
    expect(active, isNull, reason: 'Close Day still closes the session');
    final rollover = await tester
        .runAsync(db.focusSessionDao.getLastClosedSessionRolloverTaskIds);
    expect(rollover, contains('t1'),
        reason: 'the unfinished Outcome is still rolled over');
    expect(sessionId, isNotEmpty);
  }

  testWidgets(
      'launched by Daily Planning: no moon, phrase or Close Day button; '
      'commits and lands in planning', (tester) async {
    final (widget, container) = _app(db);
    addTearDown(container.dispose);
    container.read(shutdownThenPlanProvider.notifier).set(true);

    await tester.pumpWidget(widget);
    await settleWithRealAsync(tester);
    expect(find.text('Review Your Day'), findsOneWidget);

    await tester.tap(find.text('Next step'));
    await settleWithRealAsync(tester);
    await tester.tap(find.text('Roll Over to Tomorrow'));
    // Only a few frames: no waiting out the 1.6 s entrance.
    await tester.pump();
    expect(find.byIcon(Icons.nightlight_round), findsNothing);
    expect(find.text('Close Day'), findsNothing);
    await tester.runAsync(() => pumpEventQueue());
    for (var i = 0; i < 8; i++) {
      await tester.pump();
      expect(find.byIcon(Icons.nightlight_round), findsNothing);
      expect(find.text('Close Day'), findsNothing);
      expect(find.text('Review Your Day'), findsNothing,
          reason: 'the Review step must not flash through the reset');
      await tester.runAsync(() => pumpEventQueue());
    }

    expect(find.text('planning'), findsOneWidget);
    expect(container.read(shutdownThenPlanProvider), isFalse);
    await expectSessionClosed(tester);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('shutdown_ritual_completed_date'), isNotNull);
  });

  testWidgets('same day: moon and Close Day button, tap does not open planning',
      (tester) async {
    final (widget, container) = _app(db);
    addTearDown(container.dispose);

    await tester.pumpWidget(widget);
    await settleWithRealAsync(tester);
    await tester.tap(find.text('Next step'));
    await settleWithRealAsync(tester);
    await tester.tap(find.text('Roll Over to Tomorrow'));
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 1700));
    await tester.pump();

    expect(find.byIcon(Icons.nightlight_round), findsWidgets);
    await tester.tap(find.text('Close Day'));
    for (var i = 0; i < 6; i++) {
      await tester.pump();
      await tester.runAsync(() => pumpEventQueue());
    }
    expect(find.text('planning'), findsNothing);
    await expectSessionClosed(tester);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('shutdown_ritual_completed_date'), isNotNull);

    // Unmount before the fade-out ends so the real closeApp() is not called.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('abandoned sequenced shutdown does not leak the intent',
      (tester) async {
    final (widget, container) = _app(db);
    addTearDown(container.dispose);
    container.read(shutdownThenPlanProvider.notifier).set(true);

    await tester.pumpWidget(widget);
    await settleWithRealAsync(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();

    expect(container.read(shutdownThenPlanProvider), isFalse);
  });
}
