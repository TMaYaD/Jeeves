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
import 'package:jeeves/providers/evening_shutdown_provider.dart';
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

  Future<void> rollOverAndAssertStore(WidgetTester tester, String label) async {
    await tapText(tester, label);
    expect(
      container.read(eveningShutdownProvider).dispositions['passport'],
      'rollover',
    );
    await tester.runAsync(
      () => container.read(eveningShutdownProvider.notifier).closeDay(),
    );
    final rolledOver = await tester.runAsync(
      () => db.focusSessionDao.getLastClosedSessionRolloverTaskIds(),
    );
    expect(rolledOver, ['passport']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  testWidgets('forgotten shutdown launched by Daily Planning says "Roll Over"',
      (tester) async {
    await pumpApp(tester, '/focus-session-planning');
    expect(find.text('Close your current session first'), findsOneWidget);
    await tapText(tester, 'Begin Evening Shutdown');
    container.read(eveningShutdownProvider.notifier).goToStep(1);
    await settleWithRealAsync(tester);

    expect(find.text('Roll Over'), findsOneWidget);
    expect(find.text('Roll Over to Tomorrow'), findsNothing);
    expect(find.textContaining('tomorrow', findRichText: true), findsNothing);
    expect(find.textContaining('Tomorrow', findRichText: true), findsNothing);
    await rollOverAndAssertStore(tester, 'Roll Over');
  });

  testWidgets('same-day shutdown still says "Roll Over to Tomorrow"',
      (tester) async {
    await pumpApp(tester, '/shutdown');
    container.read(eveningShutdownProvider.notifier).goToStep(1);
    await settleWithRealAsync(tester);

    expect(find.text('Roll Over to Tomorrow'), findsOneWidget);
    expect(find.text("Add to tomorrow's plan"), findsOneWidget);
    await rollOverAndAssertStore(tester, 'Roll Over to Tomorrow');
  });

  testWidgets('abandoned sequenced shutdown does not change a later one',
      (tester) async {
    await pumpApp(tester, '/focus-session-planning');
    await tapText(tester, 'Begin Evening Shutdown');
    expect(container.read(shutdownThenPlanProvider), isTrue);

    // Leave the shutdown without finishing it.
    router.go('/focus');
    await settleWithRealAsync(tester);
    expect(find.text('Now'), findsOneWidget);
    expect(container.read(shutdownThenPlanProvider), isFalse);

    router.go('/shutdown');
    await settleWithRealAsync(tester);
    container.read(eveningShutdownProvider.notifier).goToStep(1);
    await settleWithRealAsync(tester);
    expect(find.text('Roll Over to Tomorrow'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
