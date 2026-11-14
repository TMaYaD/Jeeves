/// Journey: a session opened with an empty Plan can be closed straight from
/// the NOW page (issue #877). With the Settings "Start Evening Shutdown"
/// entry gone, the NOW callout is the only direct way to end such a session.
///
/// Real FocusScreen, real in-memory database. Only the notification service
/// is stubbed.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/focus_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import '../helpers/settle.dart';
import '../test_helpers.dart';

void main() {
  setUpAll(configureSqliteForTests);
  late GtdDatabase db;
  late ProviderContainer container;
  late GoRouter router;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    await db.focusSessionDao.openSession(userId: 'local', taskIds: []);
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
  });

  tearDown(() async {
    router.dispose();
    container.dispose();
    await db.close();
  });

  testWidgets('empty-Plan session: End Session closes it and lands on /inbox',
      (tester) async {
    router = GoRouter(
      initialLocation: '/focus',
      routes: [
        GoRoute(path: '/focus', builder: (_, _) => const FocusScreen()),
        GoRoute(
          path: '/inbox',
          builder: (_, _) => const Scaffold(body: Text('Inbox')),
        ),
      ],
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await settleWithRealAsync(tester);

    expect(find.text('End Session'), findsOneWidget);
    expect(find.text('Plan the Day'), findsNothing);

    await tester.tap(find.text('End Session'));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
    }

    final active =
        await tester.runAsync(() => db.focusSessionDao.getActiveSession());
    expect(active, isNull);
    expect(router.state.uri.path, '/inbox');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
