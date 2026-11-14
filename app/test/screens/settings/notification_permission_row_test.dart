import 'package:flutter/material.dart';
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
}
