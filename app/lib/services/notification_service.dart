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

import '../models/ritual.dart';

// Stable notification IDs.
const _kFocusSessionPlanningNotificationId = 0;
const _kFocusSessionPlanningSnoozeNotificationId = 1;
const _kSprintEndNotificationId = 2;
const _kBreakEndNotificationId = 3;
const _kShutdownNotificationId = 4;
const _kShutdownSnoozeNotificationId = 5;
const _kPeriodicReviewNotificationId = 6;
const _kPeriodicReviewSnoozeNotificationId = 7;

// Action identifiers sent back via onDidReceiveNotificationResponse.
const kNotificationActionOpen = 'open';
const kNotificationActionSnooze = 'snooze_default';
const kNotificationActionSkip = 'skip_today';
const kShutdownNotificationActionOpen = 'shutdown_open';
const kShutdownNotificationActionSnooze = 'shutdown_snooze';
const kShutdownNotificationActionSkip = 'shutdown_skip_today';
const kPeriodicReviewActionOpen = 'periodic_review_open';
const kPeriodicReviewActionSnooze = 'periodic_review_snooze';
const kPeriodicReviewActionSkip = 'periodic_review_skip_today';

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
        DarwinNotificationCategory(
          'periodic_review',
          actions: [
            DarwinNotificationAction.plain(
                kPeriodicReviewActionOpen, 'Start Review'),
            DarwinNotificationAction.plain(
                kPeriodicReviewActionSnooze, 'Snooze'),
            DarwinNotificationAction.plain(
                kPeriodicReviewActionSkip, 'Skip today'),
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
  // Ritual notifications — unified surface for every Ritual's Nudge.
  // The per-Ritual notification IDs, channel IDs, titles, action IDs, and
  // iOS category identifiers live in [_ritualConfigs]; adding a fourth
  // Ritual is one entry in that matrix, not five new methods.
  // ---------------------------------------------------------------------------

  /// Schedules (or re-schedules) [ritual]'s recurring daily reminder at [time].
  /// Uses [DateTimeComponents.time] so the OS reschedules it automatically
  /// each day without any app interaction.
  Future<void> scheduleRitualReminder(RitualId ritual, TimeOfDay time) async {
    final cfg = _ritualConfigs[ritual]!;
    await _plugin.zonedSchedule(
      id: cfg.recurringId,
      title: cfg.title,
      body: cfg.body,
      scheduledDate: _nextInstanceOf(time),
      notificationDetails: _ritualNotificationDetails(cfg),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  /// Schedules a one-off snooze fire [minutes] from now. Leaves the recurring
  /// daily schedule untouched so tomorrow's reminder still fires.
  Future<void> snoozeRitualReminder(RitualId ritual, int minutes) async {
    final cfg = _ritualConfigs[ritual]!;
    await _plugin.cancel(id: cfg.snoozeId);
    final fireAt = tz.TZDateTime.now(tz.local).add(Duration(minutes: minutes));
    await _plugin.zonedSchedule(
      id: cfg.snoozeId,
      title: cfg.title,
      body: cfg.body,
      scheduledDate: fireAt,
      notificationDetails: _ritualNotificationDetails(cfg),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  /// Cancels both the recurring daily reminder and any pending snooze for
  /// [ritual]. Use when notifications are fully disabled by the user.
  Future<void> cancelRitualReminder(RitualId ritual) async {
    final cfg = _ritualConfigs[ritual]!;
    await _plugin.cancel(id: cfg.recurringId);
    await _plugin.cancel(id: cfg.snoozeId);
  }

  /// Cancels only the recurring daily reminder, leaving any pending snooze
  /// intact. Use when notifications are temporarily suppressed but the
  /// user-requested one-off snooze should still fire.
  Future<void> cancelRecurringRitualReminder(RitualId ritual) async {
    await _plugin.cancel(id: _ritualConfigs[ritual]!.recurringId);
  }

  /// Cancels only the pending snooze (the "Skip today" notification action).
  /// The recurring daily schedule still fires tomorrow.
  Future<void> skipTodayRitualReminder(RitualId ritual) async {
    await _plugin.cancel(id: _ritualConfigs[ritual]!.snoozeId);
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

  NotificationDetails _ritualNotificationDetails(
      _RitualNotificationConfig cfg) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        cfg.androidChannelId,
        cfg.androidChannelName,
        channelDescription: cfg.androidChannelDescription,
        importance: cfg.androidImportance,
        priority: cfg.androidPriority,
        actions: [
          AndroidNotificationAction(cfg.openAction, cfg.openLabel),
          AndroidNotificationAction(cfg.snoozeAction, 'Snooze'),
          AndroidNotificationAction(cfg.skipAction, 'Skip today'),
        ],
      ),
      iOS: DarwinNotificationDetails(categoryIdentifier: cfg.iOSCategoryId),
    );
  }
}

class _RitualNotificationConfig {
  const _RitualNotificationConfig({
    required this.recurringId,
    required this.snoozeId,
    required this.title,
    required this.body,
    required this.androidChannelId,
    required this.androidChannelName,
    required this.androidChannelDescription,
    required this.androidImportance,
    required this.androidPriority,
    required this.iOSCategoryId,
    required this.openAction,
    required this.snoozeAction,
    required this.skipAction,
    required this.openLabel,
  });

  final int recurringId;
  final int snoozeId;
  final String title;
  final String body;
  final String androidChannelId;
  final String androidChannelName;
  final String androidChannelDescription;
  final Importance androidImportance;
  final Priority androidPriority;
  final String iOSCategoryId;
  final String openAction;
  final String snoozeAction;
  final String skipAction;
  final String openLabel;
}

const _ritualConfigs = <RitualId, _RitualNotificationConfig>{
  RitualId.dailyPlanning: _RitualNotificationConfig(
    recurringId: _kFocusSessionPlanningNotificationId,
    snoozeId: _kFocusSessionPlanningSnoozeNotificationId,
    title: 'Time to plan your day',
    body: 'Tap to open your Daily Planning Ritual.',
    androidChannelId: 'daily_planning',
    androidChannelName: 'Daily Planning',
    androidChannelDescription: 'Daily planning ritual reminder',
    androidImportance: Importance.high,
    androidPriority: Priority.high,
    iOSCategoryId: 'daily_planning',
    openAction: kNotificationActionOpen,
    snoozeAction: kNotificationActionSnooze,
    skipAction: kNotificationActionSkip,
    openLabel: 'Open',
  ),
  RitualId.eveningShutdown: _RitualNotificationConfig(
    recurringId: _kShutdownNotificationId,
    snoozeId: _kShutdownSnoozeNotificationId,
    title: 'Time to close out the day',
    body: 'Review your completed work and roll over unfinished tasks.',
    androidChannelId: 'evening_shutdown',
    androidChannelName: 'Evening Shutdown',
    androidChannelDescription: 'Evening shutdown ritual reminder',
    androidImportance: Importance.high,
    androidPriority: Priority.high,
    iOSCategoryId: 'evening_shutdown',
    openAction: kShutdownNotificationActionOpen,
    snoozeAction: kShutdownNotificationActionSnooze,
    skipAction: kShutdownNotificationActionSkip,
    openLabel: 'Open',
  ),
  RitualId.weeklyReview: _RitualNotificationConfig(
    recurringId: _kPeriodicReviewNotificationId,
    snoozeId: _kPeriodicReviewSnoozeNotificationId,
    title: 'Time for your Weekly Review',
    body: 'Clear the backlog and set your focus for the week.',
    androidChannelId: 'periodic_review',
    androidChannelName: 'Weekly Review Reminder',
    androidChannelDescription: 'Weekly review ceremony reminder',
    androidImportance: Importance.defaultImportance,
    androidPriority: Priority.defaultPriority,
    iOSCategoryId: 'periodic_review',
    openAction: kPeriodicReviewActionOpen,
    snoozeAction: kPeriodicReviewActionSnooze,
    skipAction: kPeriodicReviewActionSkip,
    openLabel: 'Start Review',
  ),
};

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService.instance;
});
