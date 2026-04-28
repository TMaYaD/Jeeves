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
const _kFocusSessionPlanningNotificationId = 0;
const _kFocusSessionPlanningSnoozeNotificationId = 1;
const _kSprintEndNotificationId = 2;
const _kBreakEndNotificationId = 3;
const _kShutdownNotificationId = 4;
const _kShutdownSnoozeNotificationId = 5;

// Action identifiers sent back via onDidReceiveNotificationResponse.
const kNotificationActionOpen = 'open';
const kNotificationActionSnooze = 'snooze_default';
const kNotificationActionSkip = 'skip_today';
const kShutdownNotificationActionOpen = 'shutdown_open';
const kShutdownNotificationActionSnooze = 'shutdown_snooze';
const kShutdownNotificationActionSkip = 'shutdown_skip_today';

const _kFocusId = 1001;

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
    final iOS = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: [
        DarwinNotificationCategory(
          'daily_planning',
          actions: [
            DarwinNotificationAction.plain(kNotificationActionOpen, 'Open'),
            DarwinNotificationAction.plain(kNotificationActionSnooze, 'Snooze'),
            DarwinNotificationAction.plain(
                kNotificationActionSkip, 'Skip today'),
          ],
        ),
        DarwinNotificationCategory(
          'evening_shutdown',
          actions: [
            DarwinNotificationAction.plain(
                kShutdownNotificationActionOpen, 'Open'),
            DarwinNotificationAction.plain(
                kShutdownNotificationActionSnooze, 'Snooze'),
            DarwinNotificationAction.plain(
                kShutdownNotificationActionSkip, 'Skip today'),
          ],
        ),
      ],
    );
    await instance._plugin.initialize(
      settings: InitializationSettings(android: android, iOS: iOS),
      onDidReceiveNotificationResponse: onNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: onNotificationResponse,
    );
  }

  Future<bool> requestPermissions() async {
    final android = instance._plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    final iOS = instance._plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
    final macOS = instance._plugin
        .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin>();
    final androidGranted = await android?.requestNotificationsPermission() ?? false;
    final iosGranted = await iOS?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        ) ??
        false;
    final macOSGranted = await macOS?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        ) ??
        false;
    return androidGranted || iosGranted || macOSGranted;
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
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  // ---------------------------------------------------------------------------
  // Daily planning notification
  // ---------------------------------------------------------------------------

  /// Schedules (or re-schedules) the daily planning notification to fire at
  /// [time] every day. Uses [DateTimeComponents.time] so the OS reschedules it
  /// automatically each day without any app interaction.
  Future<void> scheduleFocusSessionPlanningReminder({required TimeOfDay time}) async {
    await _plugin.zonedSchedule(
      id: _kFocusSessionPlanningNotificationId,
      title: 'Time to plan your day',
      body: 'Tap to open your Daily Planning Ritual.',
      scheduledDate: _nextInstanceOf(time),
      notificationDetails: _planningNotificationDetails(),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  /// Schedules a one-off snooze notification [minutes] from now. Leaves the
  /// recurring daily schedule untouched so tomorrow's reminder still fires.
  Future<void> snoozeFocusSessionPlanningReminder(int minutes) async {
    await _plugin.cancel(id: _kFocusSessionPlanningSnoozeNotificationId);
    final fireAt = tz.TZDateTime.now(tz.local).add(Duration(minutes: minutes));
    // No matchDateTimeComponents — fires once only.
    await _plugin.zonedSchedule(
      id: _kFocusSessionPlanningSnoozeNotificationId,
      title: 'Time to plan your day',
      body: 'Tap to open your Daily Planning Ritual.',
      scheduledDate: fireAt,
      notificationDetails: _planningNotificationDetails(),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  /// Cancels both the recurring daily reminder and any pending snooze.
  /// Use when notifications are fully disabled by the user.
  Future<void> cancelFocusSessionPlanningReminder() async {
    await _plugin.cancel(id: _kFocusSessionPlanningNotificationId);
    await _plugin.cancel(id: _kFocusSessionPlanningSnoozeNotificationId);
  }

  /// Cancels only the recurring daily reminder, leaving any pending snooze
  /// intact. Use when notifications are temporarily suppressed (skip/snooze).
  Future<void> cancelRecurringFocusSessionPlanningReminder() async {
    await _plugin.cancel(id: _kFocusSessionPlanningNotificationId);
  }

  // ---------------------------------------------------------------------------
  // Evening shutdown notification
  // ---------------------------------------------------------------------------

  /// Schedules (or re-schedules) the daily evening shutdown notification to
  /// fire at [time] every day.
  Future<void> scheduleShutdownReminder({required TimeOfDay time}) async {
    await _plugin.zonedSchedule(
      id: _kShutdownNotificationId,
      title: 'Time to close out the day',
      body: 'Review your completed work and roll over unfinished tasks.',
      scheduledDate: _nextInstanceOf(time),
      notificationDetails: _shutdownNotificationDetails(),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  /// Schedules a one-off snooze shutdown notification [minutes] from now.
  Future<void> snoozeShutdownReminder(int minutes) async {
    await _plugin.cancel(id: _kShutdownSnoozeNotificationId);
    final fireAt = tz.TZDateTime.now(tz.local).add(Duration(minutes: minutes));
    await _plugin.zonedSchedule(
      id: _kShutdownSnoozeNotificationId,
      title: 'Time to close out the day',
      body: 'Review your completed work and roll over unfinished tasks.',
      scheduledDate: fireAt,
      notificationDetails: _shutdownNotificationDetails(),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  /// Permanently disables the shutdown reminder — cancels both the recurring
  /// daily schedule and any pending snooze. Use when the user turns off
  /// shutdown notifications in Settings.
  Future<void> cancelShutdownReminder() async {
    await _plugin.cancel(id: _kShutdownNotificationId);
    await _plugin.cancel(id: _kShutdownSnoozeNotificationId);
  }

  /// Suppresses today's shutdown reminder without removing the recurring daily
  /// schedule. Use for the "Skip today" notification action so tomorrow's
  /// reminder still fires automatically.
  Future<void> skipTodayShutdownReminder() async {
    await _plugin.cancel(id: _kShutdownSnoozeNotificationId);
  }

  Future<void> cancelReminder(int id) async {
    await _plugin.cancel(id: id);
  }

  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }

  // ---------------------------------------------------------------------------
  // Sprint timer notifications
  // ---------------------------------------------------------------------------

  /// Schedules a one-off notification at [endTime] for the end of a focus sprint.
  Future<void> scheduleSprintEndNotification({
    required DateTime endTime,
    required String taskTitle,
  }) async {
    await _plugin.cancel(id: _kSprintEndNotificationId);
    final scheduled = tz.TZDateTime.from(endTime, tz.local);
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final canExact = await android?.canScheduleExactNotifications() ?? false;
    await _plugin.zonedSchedule(
      id: _kSprintEndNotificationId,
      title: 'Sprint complete!',
      body: 'Time\'s up on "$taskTitle". Mark it done or keep going.',
      payload: 'focus',
      scheduledDate: scheduled,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'sprint_timer',
          'Sprint Timer',
          channelDescription: 'Pomodoro sprint start/end alerts',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentSound: true,
        ),
      ),
      androidScheduleMode: canExact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  /// Schedules a one-off notification at [endTime] for the end of a break.
  Future<void> scheduleBreakEndNotification({
    required DateTime endTime,
  }) async {
    await _plugin.cancel(id: _kBreakEndNotificationId);
    final scheduled = tz.TZDateTime.from(endTime, tz.local);
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final canExact = await android?.canScheduleExactNotifications() ?? false;
    await _plugin.zonedSchedule(
      id: _kBreakEndNotificationId,
      title: 'Break over — back to it!',
      body: 'Your 3-minute break has ended. Start the next sprint.',
      payload: 'focus',
      scheduledDate: scheduled,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'sprint_timer',
          'Sprint Timer',
          channelDescription: 'Pomodoro sprint start/end alerts',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentSound: true,
        ),
      ),
      androidScheduleMode: canExact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  /// Cancels both sprint-related notifications.
  Future<void> cancelSprintNotifications() async {
    await _plugin.cancel(id: _kSprintEndNotificationId);
    await _plugin.cancel(id: _kBreakEndNotificationId);
  }

  // ---------------------------------------------------------------------------
  // Focus session notification
  // ---------------------------------------------------------------------------

  /// Shows (or updates) a persistent notification indicating an active focus
  /// session. Safe to call repeatedly — re-showing the same [_kFocusId]
  /// replaces the previous notification on Android.
  Future<void> showFocusNotification({
    required String title,
    required String body,
  }) async {
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
      title: title,
      body: body,
      payload: 'focus',
      notificationDetails: const NotificationDetails(android: android, iOS: iOS),
    );
  }

  /// Cancels the active focus session notification.
  Future<void> cancelFocusNotification() async {
    await _plugin.cancel(id: _kFocusId);
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

  NotificationDetails _shutdownNotificationDetails() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        'evening_shutdown',
        'Evening Shutdown',
        channelDescription: 'Evening shutdown ritual reminder',
        importance: Importance.high,
        priority: Priority.high,
        actions: [
          AndroidNotificationAction(kShutdownNotificationActionOpen, 'Open'),
          AndroidNotificationAction(kShutdownNotificationActionSnooze, 'Snooze'),
          AndroidNotificationAction(
              kShutdownNotificationActionSkip, 'Skip today'),
        ],
      ),
      iOS: DarwinNotificationDetails(
        categoryIdentifier: 'evening_shutdown',
      ),
    );
  }
}

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService.instance;
});
