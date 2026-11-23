/// Habit notifications: a Habit whose anchor is a clock time gets a local
/// notification at that time on each day it is for.
///
/// The planner is pure, like the rest of the streak engine: it reads the
/// Habit histories the caller already loaded and never touches the database,
/// the clock or the OS. A stack's notification is armed at its clock-time
/// Habit's time and names the stack's Habits that are still for that day.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../database/daos/habit_dao.dart' show HabitAnchorKind;
import '../database/gtd_database.dart' show Habit, HabitInactivePeriod;
import '../models/habit_commitment.dart';
import '../models/habit_days.dart';
import '../models/habit_progress.dart';
import '../models/habit_stack.dart';
import '../providers/clock_provider.dart';
import '../providers/database_provider.dart';
import '../providers/habit_progress_provider.dart' show habitTodayProvider;
import 'due_date_notifications.dart' show dueDateNotificationId;
import 'notification_ids.dart' show fnv1a32;
import 'notification_service.dart'
    show NotificationService, notificationServiceProvider;

/// The payload prefix of a habit notification. Distinct from `outcome:`
/// (due dates), `nudge:` (Rituals) and `focus` (sprints).
const String kHabitNotificationPayloadPrefix = 'habit:';

/// How many days ahead a habit notification is planned, like the Ritual
/// notifications' horizon. A week is the most the OS is asked to hold.
const int kHabitNotificationHorizonDays = 7;

/// How many habit notifications may be pending at once.
///
/// Android limits how many alarms one app may hold on some devices, and the
/// Ritual, due-date, follow-up and sprint notifications need headroom, so
/// only the nearest are scheduled.
const int kMaxScheduledHabitNotifications = 200;

/// The button a habit notification carries.
enum HabitNotificationAction {
  /// "Check in": records the Check-in without opening the app.
  checkIn,

  /// "Start Focus": opens Focus Mode on the Habit.
  startFocus,

  /// No button: a measurable Habit has nothing a button could record.
  none,
}

/// The token a [HabitNotificationAction] travels as in a payload.
String habitNotificationActionToken(HabitNotificationAction action) =>
    switch (action) {
      HabitNotificationAction.checkIn => 'checkin',
      HabitNotificationAction.startFocus => 'focus',
      HabitNotificationAction.none => 'none',
    };

/// The action a payload token stands for.
HabitNotificationAction habitNotificationActionFromToken(String? token) =>
    switch (token) {
      'checkin' => HabitNotificationAction.checkIn,
      'focus' => HabitNotificationAction.startFocus,
      _ => HabitNotificationAction.none,
    };

/// One habit notification the planner decided on.
class PlannedHabitNotification {
  const PlannedHabitNotification({
    required this.id,
    required this.namedHabitIds,
    required this.firstHabitId,
    required this.clockTimeHabitId,
    required this.day,
    required this.fireAt,
    required this.title,
    required this.body,
    required this.action,
    required this.signature,
    required this.payload,
  });

  /// The stable notification id, one per stack and day.
  final int id;

  /// The ids of the Habits the notification names, in stack order.
  final List<String> namedHabitIds;

  /// The first Habit the notification names: its button follows this one.
  final String firstHabitId;

  /// The Habit whose clock time armed the notification.
  final String clockTimeHabitId;

  /// The day the notification is for (`YYYY-MM-DD`).
  final String day;

  /// The instant the notification fires, in the device's zone.
  final tz.TZDateTime fireAt;

  /// The notification's title.
  final String title;

  /// The notification's body.
  final String body;

  /// The button the notification carries.
  final HabitNotificationAction action;

  /// The signature of the notification's wording.
  final String signature;

  /// The payload the OS hands back on a tap.
  final String payload;

  /// Whether this entry is the same notification as [other]: the same stack,
  /// day, wording and button.
  bool sameAs(PlannedHabitNotification other) =>
      namedHabitIds.join(',') == other.namedHabitIds.join(',') &&
      day == other.day &&
      title == other.title &&
      body == other.body &&
      action == other.action &&
      fireAt.isAtSameMomentAs(other.fireAt);
}

/// The payload of a habit notification:
/// `habit:` followed by the first named Habit's id, then `|stack=`, `|day=`,
/// `|at=`, `|action=` and `|sig=` fields.
class HabitNotificationPayload {
  const HabitNotificationPayload({
    required this.habitId,
    required this.stackHabitId,
    required this.day,
    required this.atMillis,
    required this.action,
    required this.signature,
  });

  /// The first Habit the notification names — the one a body tap opens.
  final String habitId;

  /// The Habit whose clock time armed the notification.
  final String stackHabitId;

  /// The day the notification is for (`YYYY-MM-DD`).
  final String day;

  /// The instant the notification fires, in epoch milliseconds.
  final int atMillis;

  /// The button the notification carries.
  final HabitNotificationAction action;

  /// The signature of the notification's wording.
  final String signature;
}

/// The payload for a habit notification.
String habitNotificationPayload({
  required String firstHabitId,
  required String clockTimeHabitId,
  required String day,
  required DateTime fireAt,
  required HabitNotificationAction action,
  required String signature,
}) =>
    '$kHabitNotificationPayloadPrefix$firstHabitId'
    '|stack=$clockTimeHabitId'
    '|day=$day'
    '|at=${fireAt.millisecondsSinceEpoch}'
    '|action=${habitNotificationActionToken(action)}'
    '|sig=$signature';

/// A short, stable signature of a notification's wording.
///
/// The wording is not in the payload — a Habit's title is the user's own
/// text and may hold anything — so the payload carries a signature of it
/// instead. The reconciler compares payloads to see whether the alarm it
/// holds still says what it should: a stack that no longer names the same
/// Habits, or a target that moved, has to be re-armed with new wording.
String habitNotificationSignature(String title, String body) =>
    fnv1a32('$title\u0000$body').toRadixString(16);

/// The payload of a habit notification, or null when [payload] is not one.
HabitNotificationPayload? parseHabitNotificationPayload(String? payload) {
  if (payload == null ||
      !payload.startsWith(kHabitNotificationPayloadPrefix)) {
    return null;
  }
  final parts = payload.substring(kHabitNotificationPayloadPrefix.length).split('|');
  if (parts.isEmpty) return null;
  final habitId = parts.first;
  if (habitId.isEmpty) return null;

  String? field(String name) {
    for (final part in parts.skip(1)) {
      if (part.startsWith('$name=')) return part.substring(name.length + 1);
    }
    return null;
  }

  final stackHabitId = field('stack');
  final day = field('day');
  final atMillis = int.tryParse(field('at') ?? '');
  if (stackHabitId == null || stackHabitId.isEmpty) return null;
  if (day == null || day.isEmpty) return null;
  if (atMillis == null) return null;
  return HabitNotificationPayload(
    habitId: habitId,
    stackHabitId: stackHabitId,
    day: day,
    atMillis: atMillis,
    action: habitNotificationActionFromToken(field('action')),
    signature: field('sig') ?? '',
  );
}

// ---------------------------------------------------------------------------
// Copy
//
// The wording of a habit notification, in one block, so the design's own lines
// can go in by changing this file and nothing else.
// ---------------------------------------------------------------------------

/// What separates the titles of a stack's Habits.
const String kHabitStackTitleSeparator = ', then ';

/// The body of a binary Habit's notification.
const String kHabitBinaryNotificationBody = 'Time for it.';

/// The body of a binary Habit's notification when the Habit carries an
/// estimate of how long it takes.
String habitEstimatedNotificationBody(int estimateMinutes) =>
    '$estimateMinutes min — start when you\'re ready.';

/// The body of a measurable Habit's notification.
String habitMeasurableNotificationBody(double target, String unit) =>
    'Target: ${_amountText(target)} $unit';

/// A target as the user reads it: `8`, not `8.0`.
String _amountText(double amount) {
  if (amount == amount.roundToDouble() && amount.abs() < 1e15) {
    return amount.toInt().toString();
  }
  return amount.toString();
}

// ---------------------------------------------------------------------------
// The planner
// ---------------------------------------------------------------------------

/// The habit notifications for the days around [now].
///
/// [histories] are the Habits with their commitments, pauses and Check-ins.
/// [now] is the instant the plan is made for; [location] is the device's
/// time zone, which decides the calendar day "today" and the wall-clock time
/// a notification fires at.
///
/// The result is the notifications that should still fire ([upcoming], soonest
/// first) and today's notifications whose time has already passed
/// ([passedToday]). A passed entry is not re-armed: it may be on its way, and
/// cancelling it would lose it.
typedef HabitNotificationPlan = ({
  List<PlannedHabitNotification> upcoming,
  List<PlannedHabitNotification> passedToday,
});

/// Plans the habit notifications of [histories] for the next [horizonDays]
/// days.
///
/// A Habit is **for** a day when its own rule says so: due that day for the
/// day-based kinds, and its period not yet met for the per-week and per-month
/// ones. A stack notifies on the days one of its members is for, is armed at
/// its clock-time Habit's time and names the members that are for that day.
HabitNotificationPlan planHabitNotifications({
  required List<HabitHistory> histories,
  required DateTime now,
  required tz.Location location,
  int horizonDays = kHabitNotificationHorizonDays,
  int maxScheduled = kMaxScheduledHabitNotifications,
}) {
  // "Today" is the calendar day the device is on, in the device's own zone.
  final localNow = tz.TZDateTime.from(now, location);
  final today = parseHabitDay(habitDayKey(localNow))!;

  final historyById = {for (final history in histories) history.habit.id: history};
  // Today's progress decides what is still to do today, and how far a
  // per-week or per-month Habit has got. It is the same for every day of the
  // horizon, so it is computed once.
  final todayProgress = <String, HabitProgress>{
    for (final history in histories)
      history.habit.id: computeHabitProgress(history, today),
  };

  final upcoming = <PlannedHabitNotification>[];
  final passedToday = <PlannedHabitNotification>[];

  for (var offset = 0; offset < horizonDays; offset++) {
    final day = DateTime.utc(today.year, today.month, today.day + offset);
    final dayKey = habitDayKey(day);

    // A pause or an archive is judged on the day it covers, so a pause that
    // ends in three days leaves the Habit active from that day on — planned
    // ahead, with no app open on the day.
    final active = <Habit>[
      for (final history in histories)
        if (!_isInactiveOn(history.inactivePeriods, dayKey)) history.habit,
    ];

    for (final chain in habitStackChains(active)) {
      final planned = _planChain(
        chain: chain,
        historyById: historyById,
        todayProgress: todayProgress,
        day: day,
        dayKey: dayKey,
        today: today,
        location: location,
      );
      if (planned == null) continue;
      if (day == today && !planned.fireAt.isAfter(now)) {
        passedToday.add(planned);
      } else {
        upcoming.add(planned);
      }
    }
  }

  upcoming.sort((a, b) {
    final byTime = a.fireAt.compareTo(b.fireAt);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  });
  final capped = upcoming.take(maxScheduled).toList();
  return (upcoming: capped, passedToday: passedToday);
}

/// The notification for one stack on one day, or null when the stack does not
/// notify then.
PlannedHabitNotification? _planChain({
  required List<Habit> chain,
  required Map<String, HabitHistory> historyById,
  required Map<String, HabitProgress> todayProgress,
  required DateTime day,
  required String dayKey,
  required DateTime today,
  required tz.Location location,
}) {
  // Only the stack's clock-time Habit carries a time: an after- or
  // before-Habit anchor, a part of the day and no anchor at all never notify
  // on their own.
  final clockTimeHabit = chain.firstWhere(
    (habit) =>
        habit.anchorKind == HabitAnchorKind.clockTime.storedValue &&
        habit.anchorClockTime != null,
    orElse: () => chain.first,
  );
  if (clockTimeHabit.anchorKind != HabitAnchorKind.clockTime.storedValue) {
    return null;
  }
  final time = _parseClockTime(clockTimeHabit.anchorClockTime);
  if (time == null) return null;

  final named = <Habit>[
    for (final habit in chain)
      if (_isForDay(
        historyById[habit.id]!,
        todayProgress[habit.id]!,
        day: day,
        dayKey: dayKey,
        today: today,
      ))
        habit,
  ];
  if (named.isEmpty) return null;

  final first = named.first;
  final firstHistory = historyById[first.id]!;
  final commitment =
      commitmentInForceOn(firstHistory.commitments, dayKey);
  final action = _actionFor(first, commitment);
  final fireAt = tz.TZDateTime(
      location, day.year, day.month, day.day, time.hour, time.minute);
  final title = _titleFor(named);
  final body = _bodyFor(first, commitment);
  final signature = habitNotificationSignature(title, body);

  return PlannedHabitNotification(
    id: habitNotificationId(clockTimeHabit.id, dayKey),
    namedHabitIds: [for (final habit in named) habit.id],
    firstHabitId: first.id,
    clockTimeHabitId: clockTimeHabit.id,
    day: dayKey,
    fireAt: fireAt,
    title: title,
    body: body,
    action: action,
    signature: signature,
    payload: habitNotificationPayload(
      firstHabitId: first.id,
      clockTimeHabitId: clockTimeHabit.id,
      day: dayKey,
      fireAt: fireAt,
      action: action,
      signature: signature,
    ),
  );
}

/// Whether [history]'s Habit is still for [day].
///
/// Today the streak engine's own answer decides: done, not due and paused do
/// not notify. A later day is judged by the commitment in force then — due for
/// the day-based kinds, and its period not yet met for the per-week and
/// per-month ones.
bool _isForDay(
  HabitHistory history,
  HabitProgress todayProgress, {
  required DateTime day,
  required String dayKey,
  required DateTime today,
}) {
  if (day == today) {
    return todayProgress.todayState == HabitTodayState.notYet;
  }
  // A Check-in already made for that day means the day is done.
  for (final checkIn in history.checkIns) {
    if (checkIn.countsForDay == dayKey) return false;
  }
  final commitment = commitmentInForceOn(history.commitments, dayKey);
  if (commitment == null) return false;
  switch (commitment.repeatKind) {
    case HabitRepeatKind.everyDay:
    case HabitRepeatKind.chosenWeekdays:
    case HabitRepeatKind.everyNDays:
      return isDueOn(commitment, day);
    case HabitRepeatKind.timesPerWeek:
    case HabitRepeatKind.timesPerMonth:
      return _periodStillOpen(todayProgress, commitment, day, today);
  }
}

/// Whether a per-week or per-month Habit's period is still open on [day].
///
/// The period is open while the Habit has not reached N yet. A day in a later
/// period than today's is open — nothing has been done in it yet — and a day
/// in today's period is open while today's count is below N.
bool _periodStillOpen(
  HabitProgress todayProgress,
  HabitCommitment commitment,
  DateTime day,
  DateTime today,
) {
  final target = commitment.timesPerPeriod;
  if (target == null) return false;
  final span = periodSpan(commitment, day);
  if (span == null) return false;
  final todaySpan = periodSpan(commitment, today);
  if (todaySpan == null) return false;
  if (span.start.isAfter(todaySpan.start)) return true;
  if (span.start.isBefore(todaySpan.start)) return false;
  final count = todayProgress.periodCount ?? 0;
  return count < target;
}

/// The button [habit]'s notification carries, judged by the commitment in
/// force on the day.
///
/// A measurable Habit has nothing a button could record, a binary Habit with
/// an estimate has a Focus session to start, and a plain binary Habit has a
/// Check-in to record.
HabitNotificationAction _actionFor(Habit habit, HabitCommitment? commitment) {
  if (commitment != null && commitment.isMeasurable) {
    return HabitNotificationAction.none;
  }
  final estimate = habit.timeEstimateMinutes;
  if (estimate != null && estimate > 0) {
    return HabitNotificationAction.startFocus;
  }
  return HabitNotificationAction.checkIn;
}

/// The title of a notification naming [named]: the Habit's own title, or the
/// stack's titles in stack order.
String _titleFor(List<Habit> named) =>
    [for (final habit in named) habit.title].join(kHabitStackTitleSeparator);

/// The body of a notification whose first named Habit is [habit].
String _bodyFor(Habit habit, HabitCommitment? commitment) {
  if (commitment != null && commitment.isMeasurable) {
    return habitMeasurableNotificationBody(
      commitment.dailyTargetAmount!,
      commitment.unitLabel ?? '',
    );
  }
  final estimate = habit.timeEstimateMinutes;
  if (estimate != null && estimate > 0) {
    return habitEstimatedNotificationBody(estimate);
  }
  return kHabitBinaryNotificationBody;
}

/// The stable notification id of the stack of [clockTimeHabitId] on [dayKey].
///
/// One id per stack and day, so a day's alarm is replaced rather than
/// duplicated. Hashed over a prefixed string, so it differs from the due-date
/// and follow-up ids of the same shape.
int habitNotificationId(String clockTimeHabitId, String dayKey) =>
    dueDateNotificationId('$kHabitNotificationPayloadPrefix$clockTimeHabitId@$dayKey');

/// The hour and minute of a stored `HH:MM`, or null when it is not one.
({int hour, int minute})? _parseClockTime(String? clockTime) {
  if (clockTime == null) return null;
  final match = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch(clockTime);
  if (match == null) return null;
  return (
    hour: int.parse(match.group(1)!),
    minute: int.parse(match.group(2)!)
  );
}

/// Whether an inactive period covers the day with [dayKey].
///
/// A period covers a day from its first day up to — but not including — the
/// day the Habit is active again.
bool _isInactiveOn(List<HabitInactivePeriod> periods, String dayKey) {
  for (final period in periods) {
    if (period.startsOn.compareTo(dayKey) > 0) continue;
    final endsBefore = period.endsBefore;
    if (endsBefore == null || dayKey.compareTo(endsBefore) < 0) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// The reconciler
// ---------------------------------------------------------------------------

/// What the OS holds for the habit notifications: `pending` are still
/// scheduled; `pendingPayloads` maps a pending id to the payload it carries;
/// `delivered` already fired and sit in the tray.
typedef HabitNotificationsOnDevice = ({
  Set<int> pending,
  Map<int, String> pendingPayloads,
  Set<int> delivered,
});

/// Keeps the OS's scheduled habit notifications equal to the plan.
///
/// The plan is derived from the Habit histories, so the reconciler watches
/// them and re-plans after every write: a Habit that is checked in, paused,
/// archived, restored or edited changes what should be pending.
///
/// One reconciliation runs at a time.
class HabitNotificationReconciler {
  HabitNotificationReconciler({
    required this.notifications,
    required this.histories,
    tz.Location Function()? location,
    DateTime Function()? now,
  })  : _location = location ?? (() => tz.local),
        _now = now ?? DateTime.now;

  /// The OS boundary.
  final NotificationService notifications;

  /// The Habit histories the plan is made from.
  final Stream<List<HabitHistory>> histories;

  final tz.Location Function() _location;
  final DateTime Function() _now;

  List<HabitHistory> _latest = const [];
  bool _rescheduleAll = false;
  Future<void> _queue = Future.value();
  StreamSubscription<List<HabitHistory>>? _subscription;
  AppLifecycleListener? _lifecycleListener;

  /// Starts listening. [listenToLifecycle] registers the timezone re-check on
  /// app resume; it needs a bound widgets binding.
  void start({bool listenToLifecycle = true}) {
    _subscription = histories.listen((latest) {
      _latest = latest;
      _enqueue(() => _reconcile());
    });
    if (listenToLifecycle) {
      _lifecycleListener = AppLifecycleListener(onResume: onResumed);
    }
  }

  /// Re-reads the device timezone; if it changed, every notification is
  /// re-scheduled at its wall-clock time in the new zone.
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
      debugPrint('Habit notification reconcile failed: $e\n$s');
    });
    return _queue;
  }

  Future<void> _reconcile() async {
    // Ask the OS what is actually pending and delivered; never infer delivery
    // from the clock, since an inexact alarm can fire minutes late.
    final onDevice = await notifications.habitNotificationsOnDevice();
    // Plan only after the awaited device query: it can take long enough for
    // an alarm to fire meanwhile. Planning earlier would call that alarm
    // still-future, cancel its fresh tray entry and re-schedule a passed time.
    final plan = planHabitNotifications(
      histories: _latest,
      now: _now(),
      location: _location(),
    );
    final desiredIds = {for (final entry in plan.upcoming) entry.id};
    // A notification whose time has passed is kept: it may be on its way, and
    // cancelling it would lose it.
    final keepIds = <int>{...desiredIds, ...plan.passedToday.map((e) => e.id)};
    final passedFireTimes = <(int, int)>{
      for (final entry in plan.passedToday)
        (entry.id, entry.fireAt.millisecondsSinceEpoch),
    };

    // A pending alarm the plan no longer wants is obsolete (the Habit was
    // checked in, paused, archived, or its time moved) — unless it is
    // unchanged and merely late: the Habit is still for that day, the time
    // has passed, and the instant recorded in the alarm equals the one
    // planned today. Android may deliver such an alarm minutes late, so it
    // must survive.
    for (final id in onDevice.pending.difference(desiredIds)) {
      final recorded =
          parseHabitNotificationPayload(onDevice.pendingPayloads[id])?.atMillis;
      final unchangedAwaitingDelivery = recorded != null &&
          passedFireTimes.contains((id, recorded));
      if (!unchangedAwaitingDelivery) {
        await notifications.cancelReminder(id);
      }
    }
    // A delivered notification stays in the tray while its Habit is still
    // for that day, and goes once it is not (checked in, paused, archived,
    // time edited): the stale entry goes.
    for (final id in onDevice.delivered.difference(keepIds)) {
      await notifications.cancelReminder(id);
    }
    for (final entry in plan.upcoming) {
      final pendingPayload = onDevice.pendingPayloads[entry.id];
      // Skip only when the OS still holds this exact alarm: it may have
      // dropped it (app data cleared by a task killer, channel deleted) while
      // we ran.
      if (!_rescheduleAll && pendingPayload == entry.payload) continue;
      try {
        await notifications.scheduleHabitNotification(
          id: entry.id,
          title: entry.title,
          body: entry.body,
          fireAt: entry.fireAt,
          payload: entry.payload,
          action: entry.action,
        );
      } catch (e) {
        // One refused alarm does not stop the rest: the next reconciliation
        // tries again.
        debugPrint('Habit notification $entry.id was not scheduled: $e');
      }
    }
    _rescheduleAll = false;
  }
}


/// Null on web, where the notification stack is not initialised.
///
/// The plan follows the Habit histories, so the notifications follow every
/// write: a Habit that is checked in, paused, archived, restored or edited
/// changes what is pending. Watching [habitTodayProvider] re-plans the plan
/// at midnight, and the reconciler re-plans it on resume, after re-reading
/// the device's time zone.
final habitNotificationReconcilerProvider =
    Provider<HabitNotificationReconciler?>((ref) {
  if (kIsWeb) return null;
  ref.watch(habitTodayProvider);
  final reconciler = HabitNotificationReconciler(
    notifications: ref.watch(notificationServiceProvider),
    histories: ref.watch(databaseProvider).habitDao.watchHabitHistories(),
    now: () => ref.read(clockProvider)(),
  )..start();
  ref.onDispose(reconciler.dispose);
  return reconciler;
});
