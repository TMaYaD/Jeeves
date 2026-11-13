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
import 'package:jeeves/screens/shutdown/shutdown_ritual_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import '../helpers/settle.dart';
import '../test_helpers.dart';

void main() {
  setUpAll(configureSqliteForTests);
  late GtdDatabase db;
  late ProviderContainer container;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    final now = DateTime.now();
    await db
        .into(db.todos)
        .insert(
          TodosCompanion(
            id: const Value('passport'),
            title: const Value('Renew passport'),
            notes: const Value('Bring the original documents'),
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
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider.overrideWithValue(
          StubNotificationService(),
        ),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  testWidgets('shutdown shows context before deferring an Outcome', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/shutdown',
      routes: [
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
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await settleWithRealAsync(tester);
    container.read(eveningShutdownProvider.notifier).goToStep(1);
    await settleWithRealAsync(tester);
    expect(find.text('Renew passport'), findsOneWidget);
    expect(find.text('Call the passport office'), findsOneWidget);
    expect(find.text('Bring the original documents'), findsOneWidget);
    // The Done button above makes the card taller than the test surface;
    // centre the target so the footer does not cover it.
    await tester.ensureVisible(find.text('Defer until a later day'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, -120));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Defer until a later day'));
    await settleWithRealAsync(tester);
    expect(
      container.read(eveningShutdownProvider).dispositions['passport'],
      'maybe',
    );
    await tester.runAsync(
      () => container.read(eveningShutdownProvider.notifier).closeDay(),
    );
    final outcome = await tester.runAsync(() => db.todoDao.getTodo('passport'));
    expect(outcome!.intent, 'maybe');
    expect(outcome.notes, 'Bring the original documents');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
