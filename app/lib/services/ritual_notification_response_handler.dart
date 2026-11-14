import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/ritual.dart';
import '../providers/nudge_action_outbox.dart';
import 'due_date_notifications.dart' show outcomeIdFromNotificationPayload;
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
        final outcomeId = outcomeIdFromNotificationPayload(response.payload);
        final ritual = ritualIdFromNotificationPayload(response.payload);
        navigate(outcomeId != null
            ? '/task/$outcomeId'
            : ritual != null
                ? ritualNotificationRoute(ritual)
                : '/inbox');
      }
    }
    return;
  }

  final ritual = ritualAction.ritual;
  final payload = parseRitualNotificationPayload(response.payload);
  final tappedAt = now();
  if (ritualAction.kind == RitualNotificationActionKind.snooze) {
    // The duration travels in the payload: this may be a background isolate
    // with no Riverpod container, and a notification delivered by an older
    // build carries none, so fall back to an hour.
    final snoozeMinutes = payload?.snoozeMinutes ?? 60;
    final fireAt = tappedAt.add(Duration(minutes: snoozeMinutes));
    final tappedEdge = payload?.edge;
    await recordRitualNotificationAction(
      ritual: ritual,
      kind: ritualAction.kind,
      at: tappedAt,
      snoozeMinutes: snoozeMinutes,
    );
    final pendingAlarms = await service.pendingRitualNotifications();
    // The payload records when a higher-priority Ritual's Nudge holds the
    // Notification surface, judged from Nudge facts when the alarm was
    // planned. Nothing the OS holds is consulted: that Ritual's notification
    // may be later in the day, or already delivered. Past what the payload
    // covers nothing is known, so no expiry alarm is armed; the next replan
    // restores the reminder.
    final mayNotify = payload?.mayNotifyAt(fireAt);
    if (mayNotify != false) {
      await service.scheduleRitualNotification(
        id: ritualSnoozeNotificationId(ritual),
        ritual: ritual,
        fireAt: fireAt,
        payload: tappedEdge == null
            ? 'nudge:${ritual.keyPrefix}'
            : ritualNotificationPayload(
                ritual,
                edge: tappedEdge,
                snoozeMinutes: snoozeMinutes,
                fireAt: fireAt,
                coveredUntil: payload!.coveredUntil,
                outranked: payload.outranked,
              ),
      );
    } else {
      // No replacement: an earlier Snooze alarm would ring inside this
      // Snooze's window, so it goes too.
      await service.cancelReminder(ritualSnoozeNotificationId(ritual));
    }
    // Snooze hides the Ritual until [fireAt]: an alarm already planned inside
    // that window would still ring, including an overdue one the OS has not
    // delivered yet. Later alarms stay.
    for (final pending in pendingAlarms) {
      final other = parseRitualNotificationPayload(pending.payload);
      final otherFireAt = other?.fireAt;
      if (other != null &&
          other.ritual == ritual &&
          otherFireAt != null &&
          !otherFireAt.isAfter(fireAt) &&
          pending.id != ritualSnoozeNotificationId(ritual)) {
        await service.cancelReminder(pending.id);
      }
    }
    return;
  }

  await recordRitualNotificationAction(
    ritual: ritual,
    kind: ritualAction.kind,
    at: tappedAt,
    snoozeMinutes: 60,
  );
  // Skip dismisses the Nudge's current firing, so every alarm of that firing
  // goes — Weekly Review's one firing spans several daily alarms — and any
  // pending snooze. Later firings keep their alarms.
  await service.cancelReminder(ritualSnoozeNotificationId(ritual));
  final skippedEdge = payload?.edge;
  if (skippedEdge == null) return;
  for (final pending in await service.pendingRitualNotifications()) {
    final other = parseRitualNotificationPayload(pending.payload);
    final otherEdge = other?.edge;
    if (other != null &&
        other.ritual == ritual &&
        otherEdge != null &&
        otherEdge.isAtSameMomentAs(skippedEdge)) {
      await service.cancelReminder(pending.id);
    }
  }
}
