import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/screens/planning/focus_session_planning_screen.dart';
import 'package:jeeves/screens/planning/steps/day_checkin_time_step.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/periodic_review_test_helpers.dart';
import '../helpers/settle.dart';
import '../test_helpers.dart';

/// Journey: the Time step of Daily Planning opens pre-filled with the
/// available time of the previous session, across process restarts (#825).
const _focusKey = Key('focus_route');

/// A live drift `watch()` under widget fake time hangs the run
/// (docs/TESTING.md), so the open-session stream is stubbed to "none open".
ProviderContainer newContainer(GtdDatabase db) => ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider
            .overrideWithValue(StubPeriodicReviewNotificationService()),
        activeSessionProvider.overrideWith((_) => Stream.value(null)),
      ],
    );

void main() {
  setUpAll(configureSqliteForTests);
  late Directory storeDirectory;
  late File storeFile;
  late GtdDatabase db;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storeDirectory = await Directory.systemTemp.createTemp('planning-time-');
    storeFile = File('${storeDirectory.path}/planning.sqlite');
    db = GtdDatabase(NativeDatabase(storeFile));
    container = newContainer(db);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await storeDirectory.delete(recursive: true);
  });

  Future<void> restart(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      // Let in-flight snapshot loads finish before the container goes away.
      await pumpEventQueue();
      container.dispose();
      await db.close();
      db = GtdDatabase(NativeDatabase(storeFile));
      container = newContainer(db);
    });
  }

  /// Mounts the real Daily Planning screen (its mount callback runs the
  /// pre-fill; nothing here invokes it) and walks to the Time step.
  Future<void> openTimeStep(WidgetTester tester) async {
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const FocusSessionPlanningScreen()),
      GoRoute(
          path: '/focus', builder: (_, _) => const SizedBox(key: _focusKey)),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    container.read(focusSessionPlanningProvider.notifier).goToStep(4);
    await settleWithRealAsync(tester);
  }

  String fieldText(WidgetTester tester, int index) => tester
      .widget<TextField>(find.byType(TextField).at(index))
      .controller!
      .text;

  /// Types the time, then taps the real Start Day button on the last step.
  Future<void> planAndStart(
      WidgetTester tester, int hours, int minutes) async {
    await tester.enterText(find.byType(TextField).at(0), '$hours');
    await tester.enterText(find.byType(TextField).at(1), '$minutes');
    await tester.pump();
    container.read(focusSessionPlanningProvider.notifier).goToStep(6);
    await settleWithRealAsync(tester);
    await tester.tap(find.text('Start Day'));
    await settleWithRealAsync(tester);
    expect(find.byKey(_focusKey), findsOneWidget);
    await tester.runAsync(() async {
      final session = await db.focusSessionDao.getActiveSession();
      await db.focusSessionDao.closeSession(sessionId: session!.id);
    });
  }

  testWidgets('time step follows the previous session across restarts',
      (tester) async {
    await openTimeStep(tester);
    expect(fieldText(tester, 0), '8');
    expect(fieldText(tester, 1), '0');

    await planAndStart(tester, 5, 30);
    await restart(tester);
    await openTimeStep(tester);
    expect(fieldText(tester, 0), '5');
    expect(fieldText(tester, 1), '30');

    await planAndStart(tester, 6, 0);
    await restart(tester);
    await openTimeStep(tester);
    expect(fieldText(tester, 0), '6');
    expect(fieldText(tester, 1), '0');

    // An edit with no session started does not change the default.
    await tester.enterText(find.byType(TextField).at(0), '2');
    await tester.pump();
    await restart(tester);
    await openTimeStep(tester);
    expect(fieldText(tester, 0), '6');
  });

  testWidgets('clearing hours before the pre-fill lands keeps the cleared field',
      (tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: DayCheckinTimeStep())),
    ));
    await tester.enterText(find.byType(TextField).at(0), '');
    await tester.pump();
    // The pre-fill value becomes readable only now: it lands late.
    await tester.runAsync(() async {
      await db.userPreferencesDao
          .set('local', kLastSessionAvailableMinutesKey, '330');
      await container
          .read(focusSessionPlanningProvider.notifier)
          .ensureAvailableTimePreload();
    });
    await settleWithRealAsync(tester);
    expect(fieldText(tester, 0), '');
    expect(container.read(focusSessionPlanningProvider).availableMinutes, 480);
  });
}
