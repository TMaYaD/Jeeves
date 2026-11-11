// Due-date notifications — one notification per due-dated Outcome, at 09:00
// local time on its due day.
//
// A due date is a calendar day (the pickers return local midnight), so the fire
// time is derived from it rather than read from it. Instead of hooking every
// write path that can touch a due date (edits, sync replay, import, delete),
// [DueDateNotificationReconciler] watches the set of Outcomes that qualify and
// makes the OS's scheduled notifications match it.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../database/gtd_database.dart' show Todo;
import '../providers/database_provider.dart';
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
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(outcomeId)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return _kIdRangeStart + hash % (_kIdRangeEnd - _kIdRangeStart);
}

/// 09:00 on the calendar day of [dueDate] as seen in [location].
tz.TZDateTime dueDateNotificationFireAt(DateTime dueDate, tz.Location location) {
  final day = tz.TZDateTime.from(dueDate, location);
  return tz.TZDateTime(
      location, day.year, day.month, day.day, kDueDateNotificationHour);
}

String dueDateNotificationPayload(String outcomeId) =>
    '$kDueDateNotificationPayloadPrefix$outcomeId';

/// The Outcome id carried by a due-date notification payload, or null.
String? outcomeIdFromNotificationPayload(String? payload) {
  if (payload == null ||
      !payload.startsWith(kDueDateNotificationPayloadPrefix)) {
    return null;
  }
  final id = payload.substring(kDueDateNotificationPayloadPrefix.length);
  return id.isEmpty ? null : id;
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
  const DueDateNotificationPlan({required this.toSchedule, required this.keepIds});

  /// Notifications that should be pending, soonest first.
  final List<PlannedDueDateNotification> toSchedule;

  /// Ids that must not be cancelled: everything in [toSchedule] plus Outcomes
  /// whose 09:00 has already passed (their notification was delivered; it
  /// leaves the tray only when the Outcome stops qualifying).
  final Set<int> keepIds;
}

/// Decides what should be pending for [outcomes] — Outcomes that are due-dated
/// and neither done nor trashed — at [now] in [location].
DueDateNotificationPlan planDueDateNotifications(
  List<Todo> outcomes, {
  required tz.Location location,
  required DateTime now,
  int maxScheduled = kMaxScheduledDueDateNotifications,
}) {
  final keepIds = <int>{};
  final futureById = <int, PlannedDueDateNotification>{};
  for (final outcome in outcomes) {
    final dueDate = outcome.dueDate;
    if (dueDate == null) continue;
    final planned = PlannedDueDateNotification(
      id: dueDateNotificationId(outcome.id),
      outcomeId: outcome.id,
      title: outcome.title,
      fireAt: dueDateNotificationFireAt(dueDate, location),
    );
    if (!planned.fireAt.isAfter(now)) {
      keepIds.add(planned.id);
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
  return DueDateNotificationPlan(toSchedule: toSchedule, keepIds: keepIds);
}

/// Keeps the OS's scheduled due-date notifications equal to the Outcomes
/// emitted by [outcomes]. Runs reconciliations one at a time.
class DueDateNotificationReconciler {
  DueDateNotificationReconciler({
    required this.notifications,
    required this.outcomes,
    tz.Location Function()? location,
    DateTime Function()? now,
  })  : _location = location ?? (() => tz.local),
        _now = now ?? DateTime.now;

  final NotificationService notifications;
  final Stream<List<Todo>> outcomes;
  final tz.Location Function() _location;
  final DateTime Function() _now;

  final _scheduledById = <int, PlannedDueDateNotification>{};
  final _trackedIds = <int>{};
  List<Todo> _latestOutcomes = const [];
  bool _seededFromOs = false;
  Future<void> _queue = Future.value();
  StreamSubscription<List<Todo>>? _subscription;
  AppLifecycleListener? _lifecycleListener;

  /// Starts listening. [listenToLifecycle] registers the timezone re-check on
  /// app resume; it needs a bound widgets binding.
  void start({bool listenToLifecycle = true}) {
    _subscription = outcomes.listen((latest) {
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
        if (changed) _scheduledById.clear();
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
      debugPrint('Due-date notification reconcile failed: $e\n$s');
    });
    return _queue;
  }

  Future<void> _reconcile() async {
    final plan = planDueDateNotifications(
      _latestOutcomes,
      location: _location(),
      now: _now(),
    );
    if (!_seededFromOs) {
      _trackedIds.addAll(await notifications.trackedDueDateNotificationIds());
      _seededFromOs = true;
    }
    for (final id in _trackedIds.difference(plan.keepIds).toList()) {
      await notifications.cancelReminder(id);
      _trackedIds.remove(id);
      _scheduledById.remove(id);
    }
    for (final planned in plan.toSchedule) {
      final previous = _scheduledById[planned.id];
      if (previous != null && previous.sameAs(planned)) continue;
      await notifications.scheduleReminder(
        id: planned.id,
        title: planned.title,
        body: kDueDateNotificationBody,
        scheduledAt: planned.fireAt,
        payload: dueDateNotificationPayload(planned.outcomeId),
      );
      _scheduledById[planned.id] = planned;
      _trackedIds.add(planned.id);
    }
  }
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
