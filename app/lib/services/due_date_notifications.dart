// Due-date notifications — one notification per due-dated Outcome, at 09:00
// local time on its due day.
//
// A due date is a calendar day (the pickers return local midnight), so the fire
// time is derived from it rather than read from it. Instead of hooking every
// write path that can touch a due date (edits, sync replay, import, delete),
// [DueDateNotificationReconciler] watches the set of Outcomes that qualify and
// makes the OS's scheduled notifications match it.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../database/gtd_database.dart' show Todo;
import '../providers/database_provider.dart';
import 'notification_ids.dart';
import 'notification_service.dart';

/// Local hour of the due day at which the notification fires.
const kDueDateNotificationHour = 9;

const kDueDateNotificationBody = 'Due today';

/// Payload prefix; the rest is the Outcome id. Distinct from `nudge:` (Rituals)
/// and `focus` (sprints).
const kDueDateNotificationPayloadPrefix = 'outcome:';

/// Android limits how many alarms one app may hold on some devices, and the
/// Ritual and sprint notifications need headroom, so only the nearest due days
/// are scheduled.
const kMaxScheduledDueDateNotifications = 50;

const _kIdRangeStart = 10000; // 0–7 rituals/sprint/break, 1001 focus.
const _kIdRangeEnd = 0x7FFFFFFF; // plugin ids are 32-bit signed.

/// Stable 32-bit notification id for [outcomeId] (FNV-1a over its UTF-8 bytes,
/// mapped into `[10000, 2^31-1)`). Not `String.hashCode`, which differs between
/// runs.
int dueDateNotificationId(String outcomeId) {
  final hash = fnv1a32(outcomeId);
  return _kIdRangeStart + hash % (_kIdRangeEnd - _kIdRangeStart);
}

/// 09:00 on the calendar day of [dueDate] as seen in [location].
tz.TZDateTime dueDateNotificationFireAt(DateTime dueDate, tz.Location location) {
  final day = tz.TZDateTime.from(dueDate, location);
  return tz.TZDateTime(
      location, day.year, day.month, day.day, kDueDateNotificationHour);
}

/// Separates the Outcome id from the requested fire instant in a payload.
const kDueDateNotificationFireAtSeparator = '@';

/// Payload for a notification whose payload starts with [prefix].
String outcomeNotificationPayload(String prefix, String outcomeId,
        {DateTime? fireAt}) =>
    fireAt == null
        ? '$prefix$outcomeId'
        : '$prefix$outcomeId'
            '$kDueDateNotificationFireAtSeparator'
            '${fireAt.millisecondsSinceEpoch}';

/// The fire instant (epoch milliseconds) recorded in a payload that starts with
/// [prefix], or null when it carries none.
int? outcomeNotificationFireAtMillis(String prefix, String? payload) {
  if (payload == null || !payload.startsWith(prefix)) return null;
  final at = payload.lastIndexOf(kDueDateNotificationFireAtSeparator);
  if (at < 0) return null;
  return int.tryParse(payload.substring(at + 1));
}

/// The Outcome id carried by a payload that starts with [prefix], or null.
String? outcomeNotificationOutcomeId(String prefix, String? payload) {
  if (payload == null || !payload.startsWith(prefix)) return null;
  var id = payload.substring(prefix.length);
  final at = id.indexOf(kDueDateNotificationFireAtSeparator);
  if (at >= 0) id = id.substring(0, at);
  return id.isEmpty ? null : id;
}

/// Payload for the notification of [outcomeId]. When [fireAt] is given it is
/// recorded (epoch milliseconds), so a pending alarm can later be told apart
/// from one scheduled for a different, since-changed due day.
String dueDateNotificationPayload(String outcomeId, {DateTime? fireAt}) =>
    outcomeNotificationPayload(kDueDateNotificationPayloadPrefix, outcomeId,
        fireAt: fireAt);

/// The fire instant (epoch milliseconds) recorded in a due-date payload, or
/// null when the payload carries none.
int? fireAtMillisFromNotificationPayload(String? payload) =>
    outcomeNotificationFireAtMillis(
        kDueDateNotificationPayloadPrefix, payload);

/// The Outcome id carried by a due-date notification payload, or null.
String? outcomeIdFromNotificationPayload(String? payload) =>
    outcomeNotificationOutcomeId(kDueDateNotificationPayloadPrefix, payload);

/// What the OS holds for one kind of Outcome notification. `pending` are still
/// scheduled; `delivered` already fired and sit in the tray;
/// `pendingFireAtMillis` maps a pending id to the instant recorded in its
/// payload.
typedef OutcomeNotificationsOnDevice = ({
  Set<int> pending,
  Map<int, int> pendingFireAtMillis,
  Set<int> delivered
});

/// One kind of per-Outcome notification (due date, follow-up). A reconciler
/// handles exactly one kind and, through [onDevice], sees and cancels only that
/// kind's notifications — the two kinds share neither ids, payload prefix nor
/// Android channel.
class OutcomeNotificationKind {
  const OutcomeNotificationKind({
    required this.body,
    required this.idFor,
    required this.fireAtOn,
    required this.payloadFor,
    required this.schedule,
    required this.onDevice,
  });

  /// Fixed notification text under the Outcome title.
  final String body;

  /// Stable notification id for an Outcome id.
  final int Function(String outcomeId) idFor;

  /// The instant the notification fires on the calendar day [day].
  final tz.TZDateTime Function(DateTime day, tz.Location location) fireAtOn;

  final String Function(String outcomeId, {DateTime? fireAt}) payloadFor;

  final Future<void> Function(
    NotificationService service, {
    required int id,
    required String title,
    required String body,
    required DateTime scheduledAt,
    String? payload,
  }) schedule;

  final Future<OutcomeNotificationsOnDevice> Function(
      NotificationService service) onDevice;
}

/// The due-date kind: `Due today` at 09:00 on the due day.
final dueDateNotificationKind = OutcomeNotificationKind(
  body: kDueDateNotificationBody,
  idFor: dueDateNotificationId,
  fireAtOn: dueDateNotificationFireAt,
  payloadFor: dueDateNotificationPayload,
  schedule: (service,
          {required id,
          required title,
          required body,
          required scheduledAt,
          payload}) =>
      service.scheduleReminder(
          id: id,
          title: title,
          body: body,
          scheduledAt: scheduledAt,
          payload: payload),
  onDevice: (service) => service.dueDateNotificationsOnDevice(),
);

/// An Outcome that should have a notification, on calendar day [day].
class OutcomeNotificationCandidate {
  const OutcomeNotificationCandidate({
    required this.outcomeId,
    required this.title,
    required this.day,
  });

  final String outcomeId;
  final String title;
  final DateTime day;
}

class PlannedDueDateNotification {
  const PlannedDueDateNotification({
    required this.id,
    required this.outcomeId,
    required this.title,
    required this.fireAt,
  });

  final int id;
  final String outcomeId;
  final String title;
  final tz.TZDateTime fireAt;

  bool sameAs(PlannedDueDateNotification other) =>
      title == other.title && fireAt.isAtSameMomentAs(other.fireAt);
}

class DueDateNotificationPlan {
  const DueDateNotificationPlan({
    required this.toSchedule,
    required this.keepIds,
    required this.passedFireTimes,
  });

  /// Notifications that should be pending, soonest first.
  final List<PlannedDueDateNotification> toSchedule;

  /// Ids that must not be cancelled: everything in [toSchedule] plus Outcomes
  /// whose 09:00 has already passed (their notification was delivered; it
  /// leaves the tray only when the Outcome stops qualifying).
  final Set<int> keepIds;

  /// (notification id, fire instant in epoch milliseconds) for each Outcome
  /// whose 09:00 has already passed. A pending alarm matching one of these is
  /// unchanged and still awaiting delivery, so it must not be cancelled.
  final Set<(int, int)> passedFireTimes;
}

/// Decides what should be pending for [outcomes] — Outcomes that are due-dated
/// and neither done nor trashed — at [now] in [location].
DueDateNotificationPlan planDueDateNotifications(
  List<Todo> outcomes, {
  required tz.Location location,
  required DateTime now,
  int maxScheduled = kMaxScheduledDueDateNotifications,
}) =>
    planOutcomeNotifications(
      _dueDateCandidates(outcomes),
      kind: dueDateNotificationKind,
      location: location,
      now: now,
      maxScheduled: maxScheduled,
    );

List<OutcomeNotificationCandidate> _dueDateCandidates(List<Todo> outcomes) => [
      for (final outcome in outcomes)
        if (outcome.dueDate != null)
          OutcomeNotificationCandidate(
            outcomeId: outcome.id,
            title: outcome.title,
            day: outcome.dueDate!,
          ),
    ];

/// [planDueDateNotifications] for any [kind]: what should be pending for
/// [candidates] at [now] in [location].
DueDateNotificationPlan planOutcomeNotifications(
  List<OutcomeNotificationCandidate> candidates, {
  required OutcomeNotificationKind kind,
  required tz.Location location,
  required DateTime now,
  int maxScheduled = kMaxScheduledDueDateNotifications,
}) {
  final keepIds = <int>{};
  final passedFireTimes = <(int, int)>{};
  final futureById = <int, PlannedDueDateNotification>{};
  for (final candidate in candidates) {
    final planned = PlannedDueDateNotification(
      id: kind.idFor(candidate.outcomeId),
      outcomeId: candidate.outcomeId,
      title: candidate.title,
      fireAt: kind.fireAtOn(candidate.day, location),
    );
    if (!planned.fireAt.isAfter(now)) {
      keepIds.add(planned.id);
      passedFireTimes.add((planned.id, planned.fireAt.millisecondsSinceEpoch));
      continue;
    }
    // Id collision: keep the earlier fire time (then the smaller Outcome id)
    // so the choice is the same on every device and every run.
    final existing = futureById[planned.id];
    if (existing == null ||
        planned.fireAt.isBefore(existing.fireAt) ||
        (planned.fireAt.isAtSameMomentAs(existing.fireAt) &&
            planned.outcomeId.compareTo(existing.outcomeId) < 0)) {
      futureById[planned.id] = planned;
    }
  }
  final sorted = futureById.values.toList()
    ..sort((a, b) {
      final byTime = a.fireAt.compareTo(b.fireAt);
      return byTime != 0 ? byTime : a.outcomeId.compareTo(b.outcomeId);
    });
  final toSchedule = sorted.take(maxScheduled).toList();
  keepIds.addAll(toSchedule.map((p) => p.id));
  return DueDateNotificationPlan(
    toSchedule: toSchedule,
    keepIds: keepIds,
    passedFireTimes: passedFireTimes,
  );
}

/// Keeps the OS's scheduled notifications of one [OutcomeNotificationKind]
/// equal to the Outcomes emitted by [candidates]. Runs reconciliations one at
/// a time.
class OutcomeNotificationReconciler {
  OutcomeNotificationReconciler({
    required this.notifications,
    required this.kind,
    required this.candidates,
    tz.Location Function()? location,
    DateTime Function()? now,
  })  : _location = location ?? (() => tz.local),
        _now = now ?? DateTime.now;

  final NotificationService notifications;
  final OutcomeNotificationKind kind;
  final Stream<List<OutcomeNotificationCandidate>> candidates;
  final tz.Location Function() _location;
  final DateTime Function() _now;

  final _scheduledById = <int, PlannedDueDateNotification>{};
  List<OutcomeNotificationCandidate> _latestOutcomes = const [];
  bool _rescheduleAll = false;
  Future<void> _queue = Future.value();
  StreamSubscription<List<OutcomeNotificationCandidate>>? _subscription;
  AppLifecycleListener? _lifecycleListener;

  /// Starts listening. [listenToLifecycle] registers the timezone re-check on
  /// app resume; it needs a bound widgets binding.
  void start({bool listenToLifecycle = true}) {
    _subscription = candidates.listen((latest) {
      _latestOutcomes = latest;
      _enqueue(() => _reconcile());
    });
    if (listenToLifecycle) {
      _lifecycleListener = AppLifecycleListener(onResume: onResumed);
    }
  }

  /// Re-reads the device timezone; if it changed, every notification is
  /// re-scheduled to 09:00 on its due day in the new zone.
  Future<void> onResumed() => _enqueue(() async {
        final changed = await notifications.refreshLocalTimezone();
        _rescheduleAll = changed;
        await _reconcile();
      });

  /// Completes once every reconciliation queued so far has finished.
  Future<void> settled() => _queue;

  void dispose() {
    _subscription?.cancel();
    _lifecycleListener?.dispose();
  }

  Future<void> _enqueue(Future<void> Function() job) {
    _queue = _queue.then((_) => job()).catchError((Object e, StackTrace s) {
      debugPrint('Outcome notification reconcile failed: $e\n$s');
    });
    return _queue;
  }

  Future<void> _reconcile() async {
    // Ask the OS what is actually pending and delivered; never infer delivery
    // from the clock, since inexact alarms can fire minutes after 09:00.
    // Pending ids are NOT reduced by the delivered ids: one Outcome has one
    // notification id, so an old tray entry and a newer pending alarm can share
    // it. Each pending alarm is judged by the fire instant recorded in it.
    final onDevice = await kind.onDevice(notifications);
    final stillPending = onDevice.pending;
    // Plan only after the awaited device query: it can take long enough for
    // a 09:00 alarm to fire meanwhile. Planning earlier would call that alarm
    // still-future, cancel its fresh tray entry and re-schedule a passed time.
    final plan = planOutcomeNotifications(
      _latestOutcomes,
      kind: kind,
      location: _location(),
      now: _now(),
    );
    final desiredIds = plan.toSchedule.map((p) => p.id).toSet();
    // A pending alarm the plan no longer wants is obsolete (its due date
    // moved, or it fell outside the nearest 50) — unless it is unchanged and
    // merely late: its Outcome still qualifies, 09:00 has passed, and the
    // instant recorded in the alarm equals the one planned today. Android may
    // deliver such an alarm minutes after 09:00, so it must survive. The same
    // test covers an alarm that fired between the pending and tray queries: it
    // is seen in both, and its recorded instant still equals today's.
    for (final id in stillPending.difference(desiredIds)) {
      final recordedMillis = onDevice.pendingFireAtMillis[id];
      final unchangedAwaitingDelivery = recordedMillis != null &&
          plan.passedFireTimes.contains((id, recordedMillis));
      if (!unchangedAwaitingDelivery) await notifications.cancelReminder(id);
    }
    // A delivered notification stays in the tray while its Outcome is overdue
    // and open, and goes once the Outcome stops qualifying.
    for (final id in onDevice.delivered.difference(plan.keepIds)) {
      await notifications.cancelReminder(id);
    }
    // A tray entry whose Outcome now has a future alarm is from an earlier due
    // date ("Due today" no longer true). Remove it; cancelling also drops any
    // pending alarm under that id, so it is scheduled again below.
    final replacedIds = onDevice.delivered.intersection(desiredIds);
    for (final id in replacedIds) {
      await notifications.cancelReminder(id);
    }
    _scheduledById.removeWhere((id, _) => !desiredIds.contains(id));
    for (final planned in plan.toSchedule) {
      final previous = _scheduledById[planned.id];
      // Skip only when the OS still holds the alarm: it may have dropped it
      // (app data cleared by a task killer, channel deleted) while we ran.
      if (!_rescheduleAll &&
          previous != null &&
          previous.sameAs(planned) &&
          stillPending.contains(planned.id) &&
          !replacedIds.contains(planned.id)) {
        continue;
      }
      await kind.schedule(
        notifications,
        id: planned.id,
        title: planned.title,
        body: kind.body,
        scheduledAt: planned.fireAt,
        payload: kind.payloadFor(planned.outcomeId, fireAt: planned.fireAt),
      );
      _scheduledById[planned.id] = planned;
    }
    _rescheduleAll = false;
  }
}

/// The due-date reconciler: [outcomes] are the due-dated, open Outcomes.
class DueDateNotificationReconciler extends OutcomeNotificationReconciler {
  DueDateNotificationReconciler({
    required super.notifications,
    required Stream<List<Todo>> outcomes,
    super.location,
    super.now,
  }) : super(
          kind: dueDateNotificationKind,
          candidates: outcomes.map(_dueDateCandidates),
        );
}

/// Null on web, where the notification stack is not initialised.
final dueDateNotificationReconcilerProvider =
    Provider<DueDateNotificationReconciler?>((ref) {
  if (kIsWeb) return null;
  final reconciler = DueDateNotificationReconciler(
    notifications: ref.watch(notificationServiceProvider),
    outcomes: ref
        .watch(databaseProvider)
        .todoDao
        .watchDueDateNotificationCandidates(),
  )..start();
  ref.onDispose(reconciler.dispose);
  return reconciler;
});
