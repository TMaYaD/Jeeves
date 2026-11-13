/// Journey: the Roll Over option's copy depends on whether Evening Shutdown
/// was launched by Daily Planning's "Close your current session first"
/// screen (issue #820).
///
/// Real screens, real in-memory database. Only the notification service and
/// the planning wizard's own loaders are stubbed (a live Drift watch inside
/// the full planning wizard cannot settle under fake-async).
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
import '../helpers/settle.dart';
import '../test_helpers.dart';

class _StubPlanningNotifier extends FocusSessionPlanningNotifier {
  @override
  FocusSessionPlanningState build() => const FocusSessionPlanningState();

  @override
  Future<void> loadInboxSnapshot() async {}
}

void main() {
  setUpAll(configureSqliteForTests);
  late GtdDatabase db;
  late ProviderContainer container;
  late GoRouter router;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    final now = DateTime.now();
    await db.into(db.todos).insert(
          TodosCompanion(
            id: const Value('passport'),
            title: const Value('Renew passport'),
            clarified: const Value(true),
            intent: const Value('next'),
            userId: const Value('local'),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
    await seedCurrentAction(
      db,
      outcomeId: 'passport',
      text: 'Call the passport office',
      userId: 'local',
    );
    await db.focusSessionDao.openSession(
      userId: 'local',
      taskIds: ['passport'],
    );
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
      focusSessionPlanningProvider.overrideWith(() => _StubPlanningNotifier()),
      focusSessionPlanningIntroCountsProvider
          .overrideWith((ref) async => (inboxCount: 0, reviewCount: 0)),
    ]);
  });

  tearDown(() async {
    router.dispose();
    container.dispose();
    await db.close();
  });

  Future<void> pumpApp(WidgetTester tester, String initialLocation) async {
    router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: '/focus-session-planning',
          builder: (_, _) => const FocusSessionPlanningScreen(),
        ),
        GoRoute(
          path: '/shutdown',
          builder: (_, _) => const ShutdownRitualScreen(),
        ),
        GoRoute(
          path: '/focus',
          builder: (_, _) => const Scaffold(body: Text('Now')),
        ),
      ],
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await settleWithRealAsync(tester);
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.tap(find.text(text));
    await settleWithRealAsync(tester);
  }

  Future<void> tapNextStep(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('shutdown_next_step')));
    await settleWithRealAsync(tester);
  }

  /// Taps the real Close Day button once its entrance animation has revealed
  /// it, then lets the handler's awaits (closeDay, optional re-entry) finish.
  Future<void> tapCloseDay(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 1700));
    await tester.pump();
    await tester.tap(find.text('Close Day'));
    // Flush closeDay()'s awaits on the real event loop without letting the
    // 700ms exit fade finish: it would call the real closeApp() platform hook.
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
    }
  }

  Future<void> expectRolledOverAndSessionClosed(WidgetTester tester) async {
    final rolledOver = await tester.runAsync(
      () => db.focusSessionDao.getLastClosedSessionRolloverTaskIds(),
    );
    expect(rolledOver, ['passport']);
    final active =
        await tester.runAsync(() => db.focusSessionDao.getActiveSession());
    expect(active, isNull);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  testWidgets('forgotten shutdown launched by Daily Planning says "Roll Over"',
      (tester) async {
    await pumpApp(tester, '/focus-session-planning');
    expect(find.text('Close your current session first'), findsOneWidget);
    await tapText(tester, 'Begin Evening Shutdown');
    await tapNextStep(tester);

    expect(find.text('Roll Over'), findsOneWidget);
    expect(find.text('Add to your next plan'), findsOneWidget);
    expect(find.text('Roll Over to Tomorrow'), findsNothing);
    expect(find.textContaining('tomorrow', findRichText: true), findsNothing);
    expect(find.textContaining('Tomorrow', findRichText: true), findsNothing);

    // Resolving the last Outcome advances to Close Day on its own.
    // A shutdown launched by Daily Planning commits without a Close Day
    // step: flush the commit and the re-entry on the real event loop.
    await tapText(tester, 'Roll Over');
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
    }

    await expectRolledOverAndSessionClosed(tester);
    expect(container.read(shutdownThenPlanProvider), isFalse);
    expect(router.state.uri.path, '/focus-session-planning',
        reason: 'a sequenced shutdown completes back into Daily Planning');
    await unmount(tester);
  });

  testWidgets('same-day shutdown still says "Roll Over to Tomorrow"',
      (tester) async {
    await pumpApp(tester, '/shutdown');
    await tapNextStep(tester);

    expect(find.text('Roll Over to Tomorrow'), findsOneWidget);
    expect(find.text("Add to tomorrow's plan"), findsOneWidget);
    await tapText(tester, 'Roll Over to Tomorrow');
    await tapCloseDay(tester);

    await expectRolledOverAndSessionClosed(tester);
    expect(router.state.uri.path, '/shutdown',
        reason: 'an ordinary shutdown does not route into planning');
    await unmount(tester);
  });

  testWidgets('abandoned sequenced shutdown does not change a later one',
      (tester) async {
    await pumpApp(tester, '/focus-session-planning');
    await tapText(tester, 'Begin Evening Shutdown');
    expect(container.read(shutdownThenPlanProvider), isTrue);

    // System back on the Review step abandons the ceremony.
    await tester.binding.handlePopRoute();
    await settleWithRealAsync(tester);
    expect(find.text('Now'), findsOneWidget);
    expect(container.read(shutdownThenPlanProvider), isFalse);

    // An ordinary shutdown from the Now screen afterwards is a same-day one.
    router.go('/shutdown');
    await settleWithRealAsync(tester);
    await tapNextStep(tester);
    expect(find.text('Roll Over to Tomorrow'), findsOneWidget);
    expect(find.text("Add to tomorrow's plan"), findsOneWidget);
    await tapText(tester, 'Roll Over to Tomorrow');
    await tapCloseDay(tester);

    await expectRolledOverAndSessionClosed(tester);
    expect(router.state.uri.path, '/shutdown',
        reason: 'the abandoned intent must not route this shutdown to planning');
    await unmount(tester);
  });
}
