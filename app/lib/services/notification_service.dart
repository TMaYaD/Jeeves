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
import 'due_date_notifications.dart'
    show
        fireAtMillisFromNotificationPayload,
        outcomeIdFromNotificationPayload;

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
const _kDueDateChannelId = 'due_dates';

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
                kPeriodicReviewActionSkip, 'Skip this week'),
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
  // Due-date notifications. Named `scheduleReminder` for historical reasons;
  // "Reminder" in CONTEXT.md is a different, Action-level concept.
  // ---------------------------------------------------------------------------

  Future<void> scheduleReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledAt,
    String? payload,
  }) async {
    final scheduled = tz.TZDateTime.from(scheduledAt, tz.local);
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      payload: payload,
      scheduledDate: scheduled,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _kDueDateChannelId,
          'Due dates',
          channelDescription: 'Outcomes that are due today',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  /// Due-date notifications the OS holds, recognised by their payload:
  /// `pending` are still scheduled to fire; `delivered` already fired and sit
  /// in the tray. The queries are sequential, so an alarm that fires between
  /// them appears in both sets.
  /// `pendingFireAtMillis` maps a pending id to the fire instant recorded in
  /// its payload (absent for payloads that carry none).
  Future<
      ({
        Set<int> pending,
        Map<int, int> pendingFireAtMillis,
        Set<int> delivered
      })> dueDateNotificationsOnDevice() async {
    final pending = <int>{};
    final pendingFireAtMillis = <int, int>{};
    for (final request in await _plugin.pendingNotificationRequests()) {
      if (outcomeIdFromNotificationPayload(request.payload) != null) {
        pending.add(request.id);
        final millis = fireAtMillisFromNotificationPayload(request.payload);
        if (millis != null) pendingFireAtMillis[request.id] = millis;
      }
    }
    final delivered = <int>{};
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    for (final shown
        in await android?.getActiveNotifications() ?? const <ActiveNotification>[]) {
      final id = shown.id;
      // Android reports no payload for active notifications (iOS/macOS only),
      // so recognise ours by channel, or by payload where one is present.
      if (id != null &&
          (shown.channelId == _kDueDateChannelId ||
              outcomeIdFromNotificationPayload(shown.payload) != null)) {
        delivered.add(id);
      }
    }
    return (
      pending: pending,
      pendingFireAtMillis: pendingFireAtMillis,
      delivered: delivered
    );
  }

  /// Re-reads the device timezone into `tz.local`. Returns whether it changed.
  Future<bool> refreshLocalTimezone() async {
    final info = await FlutterTimezone.getLocalTimezone();
    if (info.identifier == tz.local.name) return false;
    tz.setLocalLocation(tz.getLocation(info.identifier));
    return true;
  }

  // ---------------------------------------------------------------------------
  // Ritual notifications — unified surface for every Ritual's Nudge.
  // The per-Ritual notification IDs, channel IDs, titles, action IDs, and
  // iOS category identifiers live in [_ritualConfigs]; adding a fourth
  // Ritual is one entry in that matrix, not five new methods.
  // ---------------------------------------------------------------------------

  /// Schedules one Ritual notification at [fireAt]. [id] decides what it
  /// replaces: scheduling again under the same id moves the alarm.
  Future<void> scheduleRitualNotification({
    required int id,
    required RitualId ritual,
    required DateTime fireAt,
    required String payload,
  }) async {
    final cfg = _ritualConfigs[ritual]!;
    await _plugin.zonedSchedule(
      id: id,
      title: cfg.title,
      body: cfg.body,
      payload: payload,
      scheduledDate: tz.TZDateTime.from(fireAt, tz.local),
      notificationDetails: _ritualNotificationDetails(cfg),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  /// Ritual notifications the OS still has scheduled: everything with a
  /// `nudge:` payload, plus the fixed ids earlier builds armed (which carry
  /// the same payload prefix, or none when scheduled before payloads existed).
  Future<List<({int id, String? payload})>> pendingRitualNotifications() async {
    return [
      for (final request in await _plugin.pendingNotificationRequests())
        if (_isRitualNotification(request.id, request.payload))
          (id: request.id, payload: request.payload),
    ];
  }

  /// Ritual notifications sitting in the tray. iOS reports the payload; Android
  /// reports none, so the Ritual is then recognised by its channel.
  Future<List<({int id, RitualId ritual})>> deliveredRitualNotifications() async {
    final delivered = <({int id, RitualId ritual})>[];
    for (final shown in await _plugin.getActiveNotifications()) {
      final id = shown.id;
      if (id == null) continue;
      RitualId? ritual = ritualIdFromNotificationPayload(shown.payload);
      if (ritual == null) {
        for (final entry in _ritualConfigs.entries) {
          if (entry.value.androidChannelId == shown.channelId) {
            ritual = entry.key;
          }
        }
      }
      if (ritual != null) delivered.add((id: id, ritual: ritual));
    }
    return delivered;
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
          AndroidNotificationAction(cfg.skipAction, cfg.skipLabel),
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
    this.skipLabel = 'Skip today',
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
  final String skipLabel;
}

/// Prefix on every Ritual notification's payload. Picked to be distinct from
/// the Pomodoro sprint notifications, which use payload `'focus'`.
const _kNudgePayloadPrefix = 'nudge:';

/// Ids earlier builds armed for the Rituals (recurring and snooze). The
/// scheduler owns them: it cancels any it did not plan.
const _kLegacyRitualNotificationIds = {0, 1, 4, 5, 6, 7};

bool _isRitualNotification(int id, String? payload) =>
    _kLegacyRitualNotificationIds.contains(id) ||
    isLegacyKeepAliveNotificationId(id) ||
    (payload?.startsWith(_kNudgePayloadPrefix) ?? false);

/// An earlier build of this scheduler armed one repeating alarm per Ritual
/// from here up. Nothing arms them now; the reconciler cancels any left over.
const _kLegacyKeepAliveIdBase = 500;

/// Whether [id] is one of those retired repeating alarms.
bool isLegacyKeepAliveNotificationId(int id) =>
    id >= _kLegacyKeepAliveIdBase &&
    id < _kLegacyKeepAliveIdBase + RitualId.values.length;

/// The id of [ritual]'s snooze alarm. One per Ritual: snoozing again moves it.
int ritualSnoozeNotificationId(RitualId ritual) =>
    _ritualConfigs[ritual]!.snoozeId;

/// The label of [ritual]'s Skip action button.
String ritualSkipActionLabel(RitualId ritual) =>
    _ritualConfigs[ritual]!.skipLabel;

/// What a Ritual notification's payload says. Format:
/// `nudge:<keyPrefix>|edge=<iso>|snooze=<minutes>|at=<epoch ms>` — `edge` is
/// the Nudge firing the notification belongs to (Skip cancels the other
/// pending alarms of the same firing), `snooze` is how long Snooze hides it,
/// `at` is the instant it was scheduled for. Notifications already in the tray
/// from older builds carry the bare `nudge:<keyPrefix>`; every field is then
/// null.
class RitualNotificationPayload {
  const RitualNotificationPayload({
    required this.ritual,
    this.edge,
    this.snoozeMinutes,
    this.fireAt,
  });

  final RitualId ritual;
  final DateTime? edge;
  final int? snoozeMinutes;
  final DateTime? fireAt;
}

String ritualNotificationPayload(
  RitualId ritual, {
  required DateTime edge,
  required int snoozeMinutes,
  required DateTime fireAt,
}) =>
    '$_kNudgePayloadPrefix${ritual.keyPrefix}'
    '|edge=${edge.toUtc().toIso8601String()}'
    '|snooze=$snoozeMinutes'
    '|at=${fireAt.millisecondsSinceEpoch}';

/// Parses either payload form. Null when [payload] is not a Ritual payload.
RitualNotificationPayload? parseRitualNotificationPayload(String? payload) {
  if (payload == null || !payload.startsWith(_kNudgePayloadPrefix)) return null;
  final parts = payload.substring(_kNudgePayloadPrefix.length).split('|');
  RitualId? ritual;
  for (final r in RitualId.values) {
    if (r.keyPrefix == parts.first) ritual = r;
  }
  if (ritual == null) return null;
  String? field(String name) {
    for (final part in parts.skip(1)) {
      if (part.startsWith('$name=')) return part.substring(name.length + 1);
    }
    return null;
  }

  final atMillis = int.tryParse(field('at') ?? '');
  return RitualNotificationPayload(
    ritual: ritual,
    edge: DateTime.tryParse(field('edge') ?? ''),
    snoozeMinutes: int.tryParse(field('snooze') ?? ''),
    fireAt: atMillis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(atMillis),
  );
}

/// Maps a notification payload back to its [RitualId] for body-tap routing
/// in the notification-action handler. Returns null when the payload is
/// absent or does not look like a Nudge payload (e.g. a sprint notification).
RitualId? ritualIdFromNotificationPayload(String? payload) =>
    parseRitualNotificationPayload(payload)?.ritual;

/// What a Ritual notification action button does.
enum RitualNotificationActionKind { open, snooze, skip }

/// Resolves a notification action ID to its Ritual and verb through the
/// per-Ritual config matrix. Returns null for an unknown ID, so a stale action
/// on an already-delivered notification is ignored rather than misrouted.
({RitualId ritual, RitualNotificationActionKind kind})?
    ritualNotificationActionFor(String? actionId) {
  if (actionId == null) return null;
  for (final entry in _ritualConfigs.entries) {
    final cfg = entry.value;
    if (actionId == cfg.openAction) {
      return (ritual: entry.key, kind: RitualNotificationActionKind.open);
    }
    if (actionId == cfg.snoozeAction) {
      return (ritual: entry.key, kind: RitualNotificationActionKind.snooze);
    }
    if (actionId == cfg.skipAction) {
      return (ritual: entry.key, kind: RitualNotificationActionKind.skip);
    }
  }
  return null;
}

/// Route to navigate to when the body of [ritual]'s notification is tapped.
/// Mirrors the per-Ritual wizard routes used by the in-app `NudgeBanner`.
String ritualNotificationRoute(RitualId ritual) => switch (ritual) {
      RitualId.dailyPlanning => '/focus-session-planning',
      RitualId.eveningShutdown => '/shutdown',
      RitualId.weeklyReview => '/periodic-review',
    };

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
    skipLabel: 'Skip this week',
  ),
};

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService.instance;
});
