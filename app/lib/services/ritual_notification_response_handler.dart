import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ritual.dart';
import '../providers/nudge_action_outbox.dart';
import 'notification_service.dart';

/// Handles a tap on a notification or one of its action buttons (foreground and
/// background). `main.dart` registers this as the plugin callback.
///
/// Open and a body tap route to the Ritual's wizard through [navigate]. Skip
/// and Snooze do their immediate OS work on [service] (cancel / re-arm the
/// one-off alarm) and record what the user did, and when, in the Nudge action
/// outbox. The main isolate applies the outbox to the Nudge's dismiss / snooze
/// state — this function may run in a background isolate with no Riverpod
/// container and no database.
///
/// [service] and [navigate] are the OS-plugin and router boundaries; tests
/// substitute them, production passes the real ones.
Future<void> handleRitualNotificationResponse(
  NotificationResponse response, {
  required NotificationService service,
  required void Function(String route) navigate,
  DateTime Function() now = DateTime.now,
}) async {
  final actionId = response.actionId;
  final ritualAction = ritualNotificationActionFor(actionId);

  if (ritualAction == null ||
      ritualAction.kind == RitualNotificationActionKind.open) {
    // Null actionId means the notification body was tapped. Route by
    // payload — focus/sprint carries 'focus', Ritual notifications carry
    // `nudge:<keyPrefix>` and resolve to the matching wizard route. A
    // body tap on an unknown payload falls back to inbox.
    if (ritualAction != null) {
      navigate(ritualNotificationRoute(ritualAction.ritual));
    } else if (actionId == null) {
      if (response.payload == 'focus') {
        navigate('/focus/active');
      } else {
        final ritual = ritualIdFromNotificationPayload(response.payload);
        navigate(
            ritual != null ? ritualNotificationRoute(ritual) : '/inbox');
      }
    }
    return;
  }

  final ritual = ritualAction.ritual;
  final snoozeMinutes =
      ritualAction.kind == RitualNotificationActionKind.snooze &&
              ritual == RitualId.dailyPlanning
          // Read snooze duration directly from SharedPreferences; Riverpod is
          // not available in background-isolate notification callbacks.
          ? await _readDefaultSnoozeDuration()
          : 60;
  await recordRitualNotificationAction(
    ritual: ritual,
    kind: ritualAction.kind,
    at: now(),
    snoozeMinutes: snoozeMinutes,
  );
  if (ritualAction.kind == RitualNotificationActionKind.snooze) {
    await service.snoozeRitualReminder(ritual, snoozeMinutes);
  } else {
    await service.skipTodayRitualReminder(ritual);
  }
}

Future<int> _readDefaultSnoozeDuration() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs
          .getInt('focus_session_planning_settings_default_snooze_duration') ??
      60;
}
