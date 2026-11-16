// Follow-up notifications — one notification per Waiting For Outcome whose
// follow-up date has arrived, at 09:00 local time on that date.
//
// A follow-up date is the `from` date of the TimeContext on the Outcome's
// current Action; nothing else stores it. This is the "scheduled reminder" of
// the follow-up story, delivered through the same reconciler as due-date
// notifications ([OutcomeNotificationReconciler]) as a second
// [OutcomeNotificationKind]. It is neither a Nudge nor the reserved Reminder
// (CONTEXT.md).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../database/gtd_database.dart' show Todo;
import '../models/time_context.dart';
import '../providers/database_provider.dart';
import 'due_date_notifications.dart';
import 'notification_service.dart';

/// Local hour of the follow-up date at which the notification fires.
const kFollowUpNotificationHour = 9;

const kFollowUpNotificationBody = 'Follow up today';

/// Payload prefix; the rest is the Outcome id. Distinct from the due-date
/// `outcome:` prefix, so each reconciler recognises only its own.
const kFollowUpNotificationPayloadPrefix = 'followup:';

/// Stable notification id for the follow-up of [outcomeId]. Hashed over a
/// prefixed string, so it differs from the same Outcome's due-date id.
int followUpNotificationId(String outcomeId) =>
    dueDateNotificationId('$kFollowUpNotificationPayloadPrefix$outcomeId');

/// 09:00 on the calendar day [fromDate] (its year, month and day as written)
/// in [location].
tz.TZDateTime followUpNotificationFireAt(
        DateTime fromDate, tz.Location location) =>
    tz.TZDateTime(location, fromDate.year, fromDate.month, fromDate.day,
        kFollowUpNotificationHour);

String followUpNotificationPayload(String outcomeId, {DateTime? fireAt}) =>
    outcomeNotificationPayload(kFollowUpNotificationPayloadPrefix, outcomeId,
        fireAt: fireAt);

/// The Outcome id carried by a follow-up notification payload, or null.
String? followUpOutcomeIdFromNotificationPayload(String? payload) =>
    outcomeNotificationOutcomeId(kFollowUpNotificationPayloadPrefix, payload);

/// The fire instant (epoch milliseconds) recorded in a follow-up payload.
int? followUpFireAtMillisFromNotificationPayload(String? payload) =>
    outcomeNotificationFireAtMillis(
        kFollowUpNotificationPayloadPrefix, payload);

final followUpNotificationKind = OutcomeNotificationKind(
  body: kFollowUpNotificationBody,
  idFor: followUpNotificationId,
  fireAtOn: followUpNotificationFireAt,
  payloadFor: followUpNotificationPayload,
  schedule: (service,
          {required id,
          required title,
          required body,
          required scheduledAt,
          payload}) =>
      service.scheduleFollowUpNotification(
          id: id,
          title: title,
          body: body,
          scheduledAt: scheduledAt,
          payload: payload),
  onDevice: (service) => service.followUpNotificationsOnDevice(),
);

/// The follow-ups that should be notified: open Waiting For Outcomes
/// ([waitingForOutcomes]: open, Intent Next, at least one Person) whose current
/// Action's TimeContext has a `from` date ([currentTimeContexts], keyed by
/// Outcome id). Emits once both inputs have emitted, then on every change.
Stream<List<OutcomeNotificationCandidate>> followUpNotificationCandidates({
  required Stream<List<Todo>> waitingForOutcomes,
  required Stream<Map<String, TimeContext>> currentTimeContexts,
}) {
  late final StreamController<List<OutcomeNotificationCandidate>> controller;
  StreamSubscription<List<Todo>>? outcomesSub;
  StreamSubscription<Map<String, TimeContext>>? contextsSub;
  List<Todo>? latestOutcomes;
  Map<String, TimeContext>? latestContexts;

  void emit() {
    final outcomes = latestOutcomes;
    final contexts = latestContexts;
    if (outcomes == null || contexts == null) return;
    controller.add([
      for (final outcome in outcomes)
        if (contexts[outcome.id]?.fromDate != null)
          OutcomeNotificationCandidate(
            outcomeId: outcome.id,
            title: outcome.title,
            day: contexts[outcome.id]!.fromDate!,
          ),
    ]);
  }

  controller = StreamController<List<OutcomeNotificationCandidate>>(
    onListen: () {
      outcomesSub = waitingForOutcomes.listen((value) {
        latestOutcomes = value;
        emit();
      }, onError: controller.addError);
      contextsSub = currentTimeContexts.listen((value) {
        latestContexts = value;
        emit();
      }, onError: controller.addError);
    },
    onCancel: () async {
      await outcomesSub?.cancel();
      await contextsSub?.cancel();
    },
  );
  return controller.stream;
}

/// Null on web, where the notification stack is not initialised.
final followUpNotificationReconcilerProvider =
    Provider<OutcomeNotificationReconciler?>((ref) {
  if (kIsWeb) return null;
  final db = ref.watch(databaseProvider);
  final reconciler = OutcomeNotificationReconciler(
    notifications: ref.watch(notificationServiceProvider),
    kind: followUpNotificationKind,
    candidates: followUpNotificationCandidates(
      waitingForOutcomes: db.todoDao.watchPersonTagged(),
      currentTimeContexts: db.actionDao.watchCurrentTimeContexts(),
    ),
  )..start();
  ref.onDispose(reconciler.dispose);
  return reconciler;
});
