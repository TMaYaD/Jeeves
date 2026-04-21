// Notification service — local and push notifications.
//
// - Local notifications: flutter_local_notifications (time-based reminders)
// - Push notifications: Firebase Cloud Messaging (cross-platform)
//
// Platform-specific deep OS integration (Siri, Android App Actions) is
// handled via platform channels in android/ and ios/.

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

// Stable notification IDs.
const _kPlanningNotificationId = 0;

// Action identifiers sent back via onDidReceiveNotificationResponse.
const kNotificationActionOpen = 'open';
const kNotificationActionSnooze = 'snooze_default';
const kNotificationActionSkip = 'skip_today';

class NotificationService {
  NotificationService._();

  /// Creates a bare instance with no plugin initialised — for use in tests
  /// where platform channels are not available.
  @visibleForTesting
  NotificationService.forTesting();

  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();

  static Future<void> initialize({
    void Function(NotificationResponse)? onNotificationResponse,
  }) async {
    tz_data.initializeTimeZones();
    // flutter_timezone 5.x returns TimezoneInfo; .identifier gives the IANA string.
    final tzInfo = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(tzInfo.identifier));

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iOS = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await instance._plugin.initialize(
      settings: const InitializationSettings(android: android, iOS: iOS),
      onDidReceiveNotificationResponse: onNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: onNotificationResponse,
    );
  }

  Future<bool> requestPermissions() async {
    final android = instance._plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission() ?? false;
    return granted;
  }

  // ---------------------------------------------------------------------------
  // Task reminders (generic, used by future reminder feature)
  // ---------------------------------------------------------------------------

  Future<void> scheduleReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledAt,
  }) async {
    final scheduled = tz.TZDateTime.from(scheduledAt, tz.local);
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: scheduled,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'task_reminders',
          'Task Reminders',
          channelDescription: 'Reminders for scheduled tasks',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  // ---------------------------------------------------------------------------
  // Daily planning notification
  // ---------------------------------------------------------------------------

  /// Schedules (or re-schedules) the daily planning notification to fire at
  /// [time] every day. Uses [DateTimeComponents.time] so the OS reschedules it
  /// automatically each day without any app interaction.
  Future<void> schedulePlanningReminder({required TimeOfDay time}) async {
    await _plugin.zonedSchedule(
      id: _kPlanningNotificationId,
      title: 'Time to plan your day',
      body: 'Tap to open your Daily Planning Ritual.',
      scheduledDate: _nextInstanceOf(time),
      notificationDetails: _planningNotificationDetails(),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  /// Cancels the recurring daily notification and schedules a one-off fire
  /// [minutes] from now.
  Future<void> snoozePlanningReminder(int minutes) async {
    await cancelPlanningReminder();
    final fireAt = tz.TZDateTime.now(tz.local).add(Duration(minutes: minutes));
    // No matchDateTimeComponents — fires once only.
    await _plugin.zonedSchedule(
      id: _kPlanningNotificationId,
      title: 'Time to plan your day',
      body: 'Tap to open your Daily Planning Ritual.',
      scheduledDate: fireAt,
      notificationDetails: _planningNotificationDetails(),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  Future<void> cancelPlanningReminder() async {
    await _plugin.cancel(id: _kPlanningNotificationId);
  }

  Future<void> cancelReminder(int id) async {
    await _plugin.cancel(id: id);
  }

  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }

  // ---------------------------------------------------------------------------
  // Cold-start launch detection
  // ---------------------------------------------------------------------------

  Future<NotificationAppLaunchDetails?> getLaunchDetails() =>
      _plugin.getNotificationAppLaunchDetails();

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  tz.TZDateTime _nextInstanceOf(TimeOfDay time) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(
        tz.local, now.year, now.month, now.day, time.hour, time.minute);
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }

  NotificationDetails _planningNotificationDetails() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        'daily_planning',
        'Daily Planning',
        channelDescription: 'Daily planning ritual reminder',
        importance: Importance.high,
        priority: Priority.high,
        actions: [
          AndroidNotificationAction(kNotificationActionOpen, 'Open'),
          AndroidNotificationAction(kNotificationActionSnooze, 'Snooze'),
          AndroidNotificationAction(kNotificationActionSkip, 'Skip today'),
        ],
      ),
      iOS: DarwinNotificationDetails(
        categoryIdentifier: 'daily_planning',
      ),
    );
  }
}

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService.instance;
});
