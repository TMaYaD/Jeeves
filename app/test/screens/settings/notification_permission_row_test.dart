import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/notification_permission_provider.dart';
import 'package:jeeves/screens/settings/settings_screen.dart';
import 'package:jeeves/services/notification_service.dart';

import '../../test_helpers.dart';

Future<ProviderContainer> _pump(
    WidgetTester tester, RecordingNotificationService svc) async {
  final container = ProviderContainer(
    overrides: [notificationServiceProvider.overrideWithValue(svc)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: NotificationPermissionDeniedRow()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  const rowKey = Key('notification_permission_denied_row');

  testWidgets('granted permission shows no row', (tester) async {
    await _pump(tester, RecordingNotificationService());
    expect(find.byKey(rowKey), findsNothing);
  });

  testWidgets('denied permission shows the row; Allow asks the OS again',
      (tester) async {
    final svc = RecordingNotificationService()..notificationsAllowed = false;
    await _pump(tester, svc);
    expect(find.byKey(rowKey), findsOneWidget);

    await tester.tap(find.byKey(const Key('notification_permission_request_button')));
    await tester.pumpAndSettle();
    expect(svc.permissionRequests, 1);
  });

  testWidgets('permission granted in system settings clears the row on resume',
      (tester) async {
    final svc = RecordingNotificationService()..notificationsAllowed = false;
    final container = await _pump(tester, svc);
    expect(find.byKey(rowKey), findsOneWidget);

    svc.notificationsAllowed = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(container.read(notificationPermissionProvider), isTrue);
    expect(find.byKey(rowKey), findsNothing);
  });

  group('wiring in the Settings screen', () {
    setUpAll(configureSqliteForTests);

    Future<void> pumpSettings(
        WidgetTester tester, RecordingNotificationService svc) async {
      SharedPreferences.setMockInitialValues({});
      final db = GtdDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(overrides: [
        nudgeBoundaryTickProvider.overrideWithValue(0),
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider.overrideWithValue(svc),
      ]);
      addTearDown(container.dispose);
      await container.read(syncedPreferencesProvider.future);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsScreen()),
      ));
      await tester.pumpAndSettle();
    }

    for (final toggle in [
      'planning_notification_toggle',
      'periodic_review_notification_toggle',
      'shutdown_notification_toggle',
    ]) {
      testWidgets('$toggle: denied permission shows a row only while the '
          'reminder is on', (tester) async {
        final svc = RecordingNotificationService()..notificationsAllowed = false;
        await pumpSettings(tester, svc);
        final switchFinder = find.byKey(Key(toggle));
        await tester.scrollUntilVisible(switchFinder, 200);
        await tester.pumpAndSettle();
        final rowsWhenOn = find.byKey(rowKey).evaluate().length;
        expect(rowsWhenOn, greaterThan(0));

        await tester.tap(switchFinder);
        await tester.pumpAndSettle();
        expect(find.byKey(rowKey).evaluate().length, rowsWhenOn - 1,
            reason: 'switching this reminder off removes its row only');
      });
    }
  });
}
