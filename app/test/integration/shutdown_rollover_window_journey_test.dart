/// Journey: Evening Shutdown's Roll Over says when the Outcome's time window
/// does not open on the day it rolls over to (GitHub #1099).
///
/// Real shutdown screen, real in-memory database, a fixed Monday clock. Rolling
/// over works exactly as before; only a line on the choice is new.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/time_context_provider.dart';
import 'package:jeeves/providers/time_window_provider.dart';
import 'package:jeeves/screens/planning/focus_session_planning_screen.dart';
import 'package:jeeves/screens/shutdown/shutdown_ritual_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import '../helpers/settle.dart';
import '../test_helpers.dart';

const _notTomorrow = 'Its time window does not open tomorrow';
const _notBeforeShutdown = 'Its time window does not open before Evening Shutdown';

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

  // 2026-11-23 is a Monday.
  final monday = DateTime(2026, 11, 23, 20);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    final now = DateTime.now();
    await db.into(db.todos).insert(
          TodosCompanion(
            id: const Value('passport'),
            title: const Value('Renew passport'),
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
  });

  tearDown(() async {
    router.dispose();
    container.dispose();
    await db.close();
  });

  Future<void> giveWindow(WidgetTester tester, int weekday) async {
    await tester.runAsync(() async {
      final windowId = await db.timeWindowDao.createTimeWindow(
        name: 'Office hours',
        hours: {weekday: (startMinute: 16 * 60, endMinute: 20 * 60)},
        userId: 'local',
      );
      final action = await db.actionDao.getCurrentAction('passport');
      await db.actionDao.setTimeWindow(action!.id, windowId);
    });
  }

  Future<void> giveTimeContext(WidgetTester tester, int weekday) async {
    await tester.runAsync(() async {
      final action = await db.actionDao.getCurrentAction('passport');
      await db.actionDao
          .setTimeContext(action!.id, TimeContext.create(days: {weekday})!);
    });
  }

  Future<void> pumpApp(WidgetTester tester, String initialLocation,
      {DateTime? clock}) async {
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => clock ?? monday),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
      focusSessionPlanningProvider.overrideWith(() => _StubPlanningNotifier()),
      focusSessionPlanningIntroCountsProvider
          .overrideWith((ref) async => (inboxCount: 0, reviewCount: 0)),
    ]);
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

  Future<void> tapCloseDay(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 1700));
    await tester.pump();
    await tester.tap(find.text('Close Day'));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
    }
  }

  Future<void> expectRolledOver(WidgetTester tester) async {
    final rolledOver = await tester.runAsync(
      () => db.focusSessionDao.getLastClosedSessionRolloverTaskIds(),
    );
    expect(rolledOver, ['passport']);
  }

  Future<void> rollOverAndClose(WidgetTester tester) async {
    await tapText(tester, 'Roll Over to Tomorrow');
    await tapCloseDay(tester);
    await expectRolledOver(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    // Daily Planning's timers live as long as the container does.
    container
      ..invalidate(plannedDayTimeProvider)
      ..invalidate(timeWindowBoundaryTickProvider)
      ..invalidate(timeContextBoundaryTickProvider);
  }

  testWidgets('a window only on Wednesday: Roll Over says so and still rolls over',
      (tester) async {
    await giveWindow(tester, DateTime.wednesday);
    await pumpApp(tester, '/shutdown');
    await tapNextStep(tester);

    expect(find.text('Roll Over to Tomorrow'), findsOneWidget);
    expect(find.text(_notTomorrow), findsOneWidget);
    await rollOverAndClose(tester);
    await unmount(tester);
  });

  testWidgets('a window that opens tomorrow shows Roll Over as before',
      (tester) async {
    await giveWindow(tester, DateTime.tuesday);
    await pumpApp(tester, '/shutdown');
    await tapNextStep(tester);

    expect(find.text("Add to tomorrow's plan"), findsOneWidget);
    expect(find.text(_notTomorrow), findsNothing);
    await rollOverAndClose(tester);
    await unmount(tester);
  });

  testWidgets('an Outcome with no time shows Roll Over as before',
      (tester) async {
    await pumpApp(tester, '/shutdown');
    await tapNextStep(tester);

    expect(find.text(_notTomorrow), findsNothing);
    await rollOverAndClose(tester);
    await unmount(tester);
  });

  testWidgets('a Time context only on Wednesday says so too', (tester) async {
    await giveTimeContext(tester, DateTime.wednesday);
    await pumpApp(tester, '/shutdown');
    await tapNextStep(tester);

    expect(find.text(_notTomorrow), findsOneWidget);
    await rollOverAndClose(tester);
    await unmount(tester);
  });

  testWidgets(
      'launched by Daily Planning, the note speaks of the shutdown, not tomorrow',
      (tester) async {
    await giveWindow(tester, DateTime.wednesday);
    await pumpApp(tester, '/focus-session-planning',
        clock: DateTime(2026, 11, 23, 9));
    await tapText(tester, 'Begin Evening Shutdown');
    await tapNextStep(tester);

    expect(find.text('Roll Over'), findsOneWidget);
    expect(find.text(_notBeforeShutdown), findsOneWidget);
    expect(find.text(_notTomorrow), findsNothing);
    await unmount(tester);
  });
}
