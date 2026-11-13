/// The Notification surface of the Nudge queue: a projection of which Ritual
/// holds the queue head at each instant a Ritual notification could fire.
///
/// An OS notification fires while the app is not running, so "schedule the
/// current head" cannot work: before 08:00 the queue is usually empty, and the
/// 08:00 Daily Planning reminder would never be armed. Instead the planner
/// evaluates the same predicates the live queue uses (`nudge_predicates.dart`)
/// at each candidate fire instant over a rolling [kNudgeNotificationHorizonDays]
/// day horizon, with the facts frozen at their current values. The reconciler
/// then makes the OS's pending Ritual notifications match the plan. A per-Ritual
/// daily keep-alive starts where the horizon ends, so reminders do not stop when
/// the app is not opened for a week.
///
/// See `CONTEXT.md`'s **Notification** and **Nudge queue** entries and
/// `docs/CEREMONIES.md` § Surfaces are projections.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/nudge_predicates.dart';
import '../models/ritual.dart';
import '../providers/ceremony_in_progress_provider.dart';
import '../providers/clock_provider.dart';
import '../providers/database_provider.dart';
import '../providers/focus_session_planning_provider.dart'
    show activeSessionProvider;
import '../providers/focus_session_planning_settings_provider.dart'
    show focusSessionPlanningSettingsProvider;
import '../providers/gtd_lists_provider.dart';
import '../providers/nudge_clock_provider.dart';
import '../providers/nudge_provider.dart';
import '../providers/nudge_triggers.dart';
import '../providers/onboarding_provider.dart';
import '../providers/periodic_review_settings_provider.dart';
import '../providers/shutdown_settings_provider.dart';
import 'notification_service.dart';

/// How many days ahead (today included) one-off alarms are planned.
const kNudgeNotificationHorizonDays = 7;

const _kWeeklyReviewCadence = Duration(days: 7);

// Ritual notification ids live below 10000 (the due-date range starts there):
// one slot per (Ritual, calendar day), the Ritual's snooze id, and a keep-alive.
const _kDayIdBase = 100;
const _kDayIdSlotsPerRitual = 100;

/// Everything the projection reads, frozen at [now].
class NudgeNotificationFacts {
  const NudgeNotificationFacts({
    required this.now,
    required this.notificationEnabled,
    required this.nudgeState,
    required this.inProgress,
    required this.dpr,
    required this.es,
    required this.wr,
    required this.weeklyReviewHour,
    required this.weeklyReviewMinute,
    required this.snoozeMinutes,
    this.weeklyReviewOpenSince,
  });

  final DateTime now;

  /// Per Ritual: whether its notifications are on. A Ritual with them off
  /// neither notifies nor blocks a lower-priority Ritual.
  final Map<RitualId, bool> notificationEnabled;

  final Map<RitualId, NudgeState> nudgeState;

  /// Rituals whose Ceremony is being performed now.
  final Set<RitualId> inProgress;

  final DprFacts dpr;
  final EsFacts es;
  final WrFacts wr;
  final int weeklyReviewHour;
  final int weeklyReviewMinute;

  /// Start of the active Weekly Review period, if one is open.
  final DateTime? weeklyReviewOpenSince;

  /// Minutes Snooze hides the Ritual's Nudge, carried in each payload.
  final Map<RitualId, int> snoozeMinutes;

  bool isEnabled(RitualId ritual) => notificationEnabled[ritual] ?? false;

  /// Hour and minute of [ritual]'s notification each day.
  ({int hour, int minute}) notificationTimeOf(RitualId ritual) =>
      switch (ritual) {
        RitualId.dailyPlanning =>
          (hour: dpr.planningHour, minute: dpr.planningMinute),
        RitualId.eveningShutdown =>
          (hour: es.shutdownHour, minute: es.shutdownMinute),
        RitualId.weeklyReview =>
          (hour: weeklyReviewHour, minute: weeklyReviewMinute),
      };
}

/// [ritual]'s Trigger firing edge at [instant] over the frozen facts, or null
/// when none of its Triggers is firing then.
DateTime? nudgeFiringEdgeAt(
  RitualId ritual,
  DateTime instant,
  NudgeNotificationFacts facts,
) {
  switch (ritual) {
    case RitualId.dailyPlanning:
      return dprFiringEdgeAt(instant, facts.dpr);
    case RitualId.eveningShutdown:
      return esFiringEdgeAt(instant, facts.es);
    case RitualId.weeklyReview:
      final lastCompleted = facts.wr.lastCompleted;
      final openSince = facts.weeklyReviewOpenSince;
      final reviewOpen =
          openSince != null && instant.isBefore(openSince.add(_kWeeklyReviewCadence));
      final due = reviewOpen ||
          lastCompleted == null ||
          !instant.isBefore(lastCompleted.add(_kWeeklyReviewCadence));
      // Mirrors the live Trigger: an open review is due before the next
      // cadence boundary, where the predicate has no edge yet.
      final cadenceEdge = !due
          ? null
          : wrFiringEdgeAt(
                instant,
                WrFacts(
                  hasAnyItem: facts.wr.hasAnyItem,
                  lastCompleted: lastCompleted,
                ),
              ) ??
              (facts.wr.hasAnyItem
                  ? lastCompleted?.add(_kWeeklyReviewCadence)
                  : null);
      final contentEdge =
          facts.wr.hasAnyItem ? facts.wr.contentFiringEdge : null;
      if (cadenceEdge == null) return contentEdge;
      if (contentEdge == null) return cadenceEdge;
      return contentEdge.isAfter(cadenceEdge) ? contentEdge : cadenceEdge;
  }
}

/// Whether [ritual]'s Nudge would be visible at [instant].
bool nudgeVisibleAtInstant(
  RitualId ritual,
  DateTime instant,
  NudgeNotificationFacts facts,
) {
  // A performance in progress hides only the firing it began in.
  final inProgressEdge = facts.inProgress.contains(ritual)
      ? nudgeFiringEdgeAt(ritual, facts.now, facts)
      : null;
  return nudgeVisibleAt(
    instant,
    nudgeFiringEdgeAt(ritual, instant, facts),
    facts.nudgeState[ritual] ?? const NudgeState(),
    inProgressEdge,
  );
}

/// The Ritual that holds the Notification surface at [instant]: the highest
/// priority Ritual that has notifications on and whose Nudge is visible then.
/// Null when none does.
RitualId? notifyingRitualAt(DateTime instant, NudgeNotificationFacts facts) {
  for (final ritual in ritualsByPriority) {
    if (facts.isEnabled(ritual) && nudgeVisibleAtInstant(ritual, instant, facts)) {
      return ritual;
    }
  }
  return null;
}

/// One alarm the OS should hold.
class PlannedNudgeNotification {
  const PlannedNudgeNotification({
    required this.id,
    required this.ritual,
    required this.fireAt,
    required this.payload,
    this.isKeepAlive = false,
  });

  final int id;
  final RitualId ritual;
  final DateTime fireAt;
  final String payload;

  /// A daily recurring alarm starting at [fireAt], not a one-off.
  final bool isKeepAlive;
}

int _dayNotificationId(RitualId ritual, DateTime day) {
  final epochDay =
      DateTime.utc(day.year, day.month, day.day).difference(DateTime.utc(1970)).inDays;
  return _kDayIdBase +
      RitualId.values.indexOf(ritual) * _kDayIdSlotsPerRitual +
      epochDay % _kDayIdSlotsPerRitual;
}

/// The alarms that should be pending, soonest first: for each day of the
/// horizon, each Ritual whose notification time falls on the Notification
/// surface; each pending snooze's expiry; and one keep-alive per Ritual still
/// notifying at the end of the horizon.
List<PlannedNudgeNotification> planNudgeNotifications(
  NudgeNotificationFacts facts,
) {
  final now = facts.now;
  final planned = <PlannedNudgeNotification>[];

  PlannedNudgeNotification? entryAt(
    RitualId ritual,
    DateTime instant, {
    required int id,
    bool isKeepAlive = false,
  }) {
    if (notifyingRitualAt(instant, facts) != ritual) return null;
    final edge = nudgeFiringEdgeAt(ritual, instant, facts);
    if (edge == null) return null;
    return PlannedNudgeNotification(
      id: id,
      ritual: ritual,
      fireAt: instant,
      isKeepAlive: isKeepAlive,
      payload: ritualNotificationPayload(
        ritual,
        edge: edge,
        snoozeMinutes: facts.snoozeMinutes[ritual] ?? 60,
        fireAt: instant,
      ),
    );
  }

  for (var offset = 0; offset < kNudgeNotificationHorizonDays; offset++) {
    final day = DateTime(now.year, now.month, now.day + offset);
    for (final ritual in RitualId.values) {
      if (!facts.isEnabled(ritual)) continue;
      final time = facts.notificationTimeOf(ritual);
      final instant = DateTime(day.year, day.month, day.day, time.hour, time.minute);
      if (!instant.isAfter(now)) continue;
      final entry = entryAt(ritual, instant, id: _dayNotificationId(ritual, day));
      if (entry != null) planned.add(entry);
    }
  }

  for (final ritual in RitualId.values) {
    if (!facts.isEnabled(ritual)) continue;
    final snoozedUntil = facts.nudgeState[ritual]?.snoozedUntil;
    if (snoozedUntil == null || !snoozedUntil.isAfter(now)) continue;
    if (planned.any((p) => p.ritual == ritual && p.fireAt.isAtSameMomentAs(snoozedUntil))) {
      continue;
    }
    final entry =
        entryAt(ritual, snoozedUntil, id: ritualSnoozeNotificationId(ritual));
    if (entry != null) planned.add(entry);
  }

  final keepAliveDay =
      DateTime(now.year, now.month, now.day + kNudgeNotificationHorizonDays);
  for (final ritual in RitualId.values) {
    if (!facts.isEnabled(ritual)) continue;
    final time = facts.notificationTimeOf(ritual);
    final instant = DateTime(
        keepAliveDay.year, keepAliveDay.month, keepAliveDay.day, time.hour, time.minute);
    final entry = entryAt(
      ritual,
      instant,
      id: kRitualKeepAliveIdBase + RitualId.values.indexOf(ritual),
      isKeepAlive: true,
    );
    if (entry != null) planned.add(entry);
  }

  planned.sort((a, b) {
    final byTime = a.fireAt.compareTo(b.fireAt);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  });
  return planned;
}

/// Makes the OS's pending and delivered Ritual notifications match the plan.
/// Runs one reconciliation at a time.
class NudgeNotificationScheduler {
  /// [clock] is read when scheduling, not when the facts were captured: the
  /// debounce can run a reconciliation just after an alarm's instant, and the
  /// OS refuses to schedule one in the past. Defaults to the facts' own `now`.
  NudgeNotificationScheduler(this._notifications, {DateTime Function()? clock})
      : _clock = clock;

  final NotificationService _notifications;
  final DateTime Function()? _clock;
  Future<void> _queue = Future.value();
  bool _disposed = false;

  /// Queues a reconciliation against [facts].
  Future<void> enqueue(NudgeNotificationFacts facts) {
    _queue = _queue.then((_) async {
      if (_disposed) return;
      await reconcile(facts);
    }).catchError((Object e, StackTrace s) {
      debugPrint('Nudge notification reconcile failed: $e\n$s');
    });
    return _queue;
  }

  /// Completes once every reconciliation queued so far has finished.
  Future<void> settled() => _queue;

  void dispose() => _disposed = true;

  Future<void> reconcile(NudgeNotificationFacts facts) async {
    final plan = planNudgeNotifications(facts);

    // A delivered notification stays only while its Ritual still holds the
    // surface. Withdraw first: cancelling an id also drops a pending alarm that
    // shares it, so the pending set must be read afterwards.
    final head = notifyingRitualAt(facts.now, facts);
    for (final delivered in await _notifications.deliveredRitualNotifications()) {
      if (delivered.ritual != head) await _notifications.cancelReminder(delivered.id);
    }

    final pendingPayloadById = {
      for (final p in await _notifications.pendingRitualNotifications())
        p.id: p.payload,
    };
    final plannedIds = {for (final p in plan) p.id};
    for (final MapEntry(key: id, value: payload) in pendingPayloadById.entries) {
      if (plannedIds.contains(id)) continue;
      // The plan only lists future instants. A one-off whose instant has just
      // passed but is still pending was not delivered yet (the OS may deliver
      // an inexact alarm late); it stays while its Ritual holds the surface.
      final fireAt = parseRitualNotificationPayload(payload)?.fireAt;
      final ritual = parseRitualNotificationPayload(payload)?.ritual;
      final dueButUndelivered = fireAt != null &&
          !fireAt.isAfter(facts.now) &&
          ritual != null &&
          ritual == head &&
          !isRitualKeepAliveNotificationId(id);
      if (dueButUndelivered) continue;
      await _notifications.cancelReminder(id);
    }
    final executionNow = _clock?.call() ?? facts.now;
    for (final entry in plan) {
      // Same id and same payload (which records the fire instant): unchanged.
      if (pendingPayloadById[entry.id] == entry.payload) continue;
      // Its instant passed while the reconciliation waited; the next one
      // replans from the new time.
      if (!entry.isKeepAlive && !entry.fireAt.isAfter(executionNow)) continue;
      try {
        await _schedule(entry);
      } catch (e, s) {
        // One refused alarm must not stop the ones after it.
        debugPrint('Scheduling Ritual notification ${entry.id} failed: $e\n$s');
      }
    }
  }

  Future<void> _schedule(PlannedNudgeNotification entry) {
    if (entry.isKeepAlive) {
      return _notifications.scheduleRitualKeepAlive(
        id: entry.id,
        ritual: entry.ritual,
        firstFireAt: entry.fireAt,
        payload: entry.payload,
      );
    }
    return _notifications.scheduleRitualNotification(
      id: entry.id,
      ritual: entry.ritual,
      fireAt: entry.fireAt,
      payload: entry.payload,
    );
  }
}

/// Start of the most recent Focus Session, open or closed; null when none.
final latestSessionStartedAtProvider = StreamProvider<DateTime?>((ref) {
  return ref.watch(databaseProvider).focusSessionDao.watchLatestSessionStartedAt();
});

/// Bumped when the app resumes, so the projection is re-read at the new time.
final nudgeNotificationResumeTickProvider =
    NotifierProvider<NudgeNotificationResumeTick, int>(
        NudgeNotificationResumeTick.new);

class NudgeNotificationResumeTick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// How long input changes are coalesced before reconciling: several inputs are
/// list streams that emit in bursts.
final nudgeNotificationDebounceProvider =
    Provider<Duration>((ref) => const Duration(milliseconds: 500));

/// The frozen facts of the projection, or null until everything they read has
/// loaded (a loading list is not an empty one).
final nudgeNotificationFactsProvider = Provider<NudgeNotificationFacts?>((ref) {
  ref.watch(nudgeBoundaryTickProvider);
  ref.watch(nudgeNotificationResumeTickProvider);
  // Watch before any early return so the edge tracker sees false→true.
  final contentEdge = ref.watch(contentFiringEdgeProvider);
  if (!ref.watch(nudgePrefsReadyProvider)) return null;

  final session = ref.watch(activeSessionProvider);
  final latestSessionStartedAt = ref.watch(latestSessionStartedAtProvider);
  final hasAnyItem = ref.watch(hasAnyItemProvider);
  final inbox = ref.watch(unfilteredInboxProvider);
  final next = ref.watch(unfilteredNextProvider);
  if (!session.hasValue ||
      !latestSessionStartedAt.hasValue ||
      !hasAnyItem.hasValue ||
      !inbox.hasValue ||
      !next.hasValue) {
    return null;
  }

  final planning = ref.watch(focusSessionPlanningSettingsProvider);
  final shutdown = ref.watch(shutdownSettingsProvider);
  final review = ref.watch(periodicReviewSettingsProvider);
  return NudgeNotificationFacts(
    now: ref.watch(clockProvider)(),
    notificationEnabled: {
      RitualId.dailyPlanning: planning.notificationEnabled,
      RitualId.eveningShutdown: shutdown.notificationEnabled,
      RitualId.weeklyReview: review.notificationEnabled,
    },
    nudgeState: {
      for (final ritual in RitualId.values)
        ritual: ref.watch(nudgeStateProvider(ritual)),
    },
    inProgress: ref.watch(ceremonyInProgressProvider),
    dpr: DprFacts(
      planningHour: planning.planningTime.hour,
      planningMinute: planning.planningTime.minute,
      shutdownHour: shutdown.shutdownTime.hour,
      shutdownMinute: shutdown.shutdownTime.minute,
      hasAnyItem: hasAnyItem.requireValue,
      hasInboxOrNext:
          inbox.requireValue.isNotEmpty || next.requireValue.isNotEmpty,
      latestSessionStartedAt: latestSessionStartedAt.requireValue,
    ),
    es: EsFacts(
      shutdownHour: shutdown.shutdownTime.hour,
      shutdownMinute: shutdown.shutdownTime.minute,
      sessionIsOpen: session.requireValue != null,
    ),
    wr: WrFacts(
      hasAnyItem: hasAnyItem.requireValue,
      lastCompleted: ref.watch(periodicReviewLastCompletedProvider),
      contentFiringEdge:
          ref.watch(wrContentFiringProvider) == true ? contentEdge : null,
    ),
    weeklyReviewHour: review.notificationTime.hour,
    weeklyReviewMinute: review.notificationTime.minute,
    weeklyReviewOpenSince: ref.watch(periodicReviewOpenSinceProvider),
    snoozeMinutes: {
      RitualId.dailyPlanning: planning.defaultSnoozeDuration,
      RitualId.eveningShutdown: 60,
      RitualId.weeklyReview: 60,
    },
  );
});

/// Keeps the OS's Ritual notifications equal to the projection of the Nudge
/// queue. Read once from the app root; there is no cold-start path. A no-op on
/// web, where the notification stack is not initialised.
final nudgeNotificationSchedulerProvider = Provider<void>((ref) {
  if (kIsWeb) return;
  final scheduler = NudgeNotificationScheduler(
    ref.watch(notificationServiceProvider),
    clock: ref.read(clockProvider),
  );
  final debounce = ref.read(nudgeNotificationDebounceProvider);
  Timer? pending;

  ref.listen(nudgeNotificationFactsProvider, (_, facts) {
    if (facts == null) return;
    pending?.cancel();
    pending = Timer(debounce, () => unawaited(scheduler.enqueue(facts)));
  }, fireImmediately: true);

  final observer = _ResumeObserver(
    () => ref.read(nudgeNotificationResumeTickProvider.notifier).bump(),
  );
  WidgetsBinding.instance.addObserver(observer);
  ref.onDispose(() {
    pending?.cancel();
    scheduler.dispose();
    WidgetsBinding.instance.removeObserver(observer);
  });
});

class _ResumeObserver with WidgetsBindingObserver {
  _ResumeObserver(this._onResumed);

  final void Function() _onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResumed();
  }
}
