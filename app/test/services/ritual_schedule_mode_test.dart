import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/services/notification_service.dart';

void main() {
  test('Ritual reminders are exact only when the OS already permits it', () {
    expect(ritualAndroidScheduleMode(canExact: true),
        AndroidScheduleMode.exactAllowWhileIdle);
    expect(ritualAndroidScheduleMode(canExact: false),
        AndroidScheduleMode.inexactAllowWhileIdle);
  });
}
