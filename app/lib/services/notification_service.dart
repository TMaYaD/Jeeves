// Notification service — local and push notifications.
//
// - Local notifications: flutter_local_notifications (time-based reminders)
// - Push notifications: Firebase Cloud Messaging (cross-platform)
//
// Platform-specific deep OS integration (Siri, Android App Actions) is
// handled via platform channels in android/ and ios/.

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _kFocusId = 1001;

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iOS = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await instance._plugin.initialize(
      settings: const InitializationSettings(android: android, iOS: iOS),
    );
  }

  Future<bool> requestPermissions() async {
    final android = instance._plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission() ?? false;
    return granted;
  }

  Future<void> scheduleReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledAt,
  }) async {
    // TODO: implement using zonedSchedule with TZDateTime
    // await _plugin.zonedSchedule(...)
  }

  Future<void> cancelReminder(int id) async {
    await _plugin.cancel(id: id);
  }

  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }

  /// Shows (or updates) a persistent notification indicating an active focus
  /// session. Safe to call repeatedly — re-showing the same [_kFocusId]
  /// replaces the previous notification on Android.
  Future<void> showFocusNotification({
    required String title,
    required Duration elapsed,
  }) async {
    final h = elapsed.inHours;
    final m = (elapsed.inMinutes % 60).toString().padLeft(2, '0');
    final s = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    final elapsedStr = h > 0 ? '$h:$m:$s' : '$m:$s';

    const android = AndroidNotificationDetails(
      'focus_mode',
      'Focus Mode',
      channelDescription: 'Active focus session indicator',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showWhen: false,
    );
    const iOS = DarwinNotificationDetails();

    await _plugin.show(
      id: _kFocusId,
      title: 'In Focus: $title',
      body: 'Elapsed: $elapsedStr',
      notificationDetails: const NotificationDetails(android: android, iOS: iOS),
    );
  }

  /// Cancels the active focus session notification.
  Future<void> cancelFocusNotification() async {
    await _plugin.cancel(id: _kFocusId);
  }
}

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService.instance;
});
