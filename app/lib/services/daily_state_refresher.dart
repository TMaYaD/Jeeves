import 'dart:async';

import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/planning_settings_keys.dart';
import '../providers/daily_planning_provider.dart';
import 'notification_service.dart';

/// Keeps planning-day state fresh without requiring an app restart.
///
/// Responsibilities:
/// - Fires a refresh at each planning-time boundary (e.g. 08:00 → new day).
/// - Fires a refresh on [AppLifecycleState.resumed] to catch boundary crossings
///   that happened while the app was in the background.
/// - Arms a one-shot timer when the user snoozes a notification so the snooze
///   clears in-session when it expires.
/// - Cancels and reschedules the boundary timer when the user changes their
///   planning time in Settings.
///
/// Call [init] once in [main] after [loadPlanningTime] has been called.
/// Call [dispose] if the object needs to be torn down (rare in production).
class DailyStateRefresher with WidgetsBindingObserver {
  DailyStateRefresher._();

  static final instance = DailyStateRefresher._();

  Timer? _boundaryTimer;
  Timer? _snoozeTimer;
  TimeOfDay _planningTime = const TimeOfDay(hour: 8, minute: 0);
  bool _initialized = false;

  /// Registers the lifecycle observer and schedules the first boundary timer.
  ///
  /// [planningTime] should match the value returned by
  /// [currentCachedPlanningTime] immediately after [loadPlanningTime].
  void init(TimeOfDay planningTime) {
    if (_initialized) return;
    _initialized = true;
    _planningTime = planningTime;
    WidgetsBinding.instance.addObserver(this);
    _scheduleBoundaryTimer();
    // Wire snooze-timer scheduling via the module-level callback to avoid a
    // circular import between this file and daily_planning_provider.dart.
    onSnoozeScheduled = scheduleSnoozeTimer;
  }

  /// Releases resources. Typically not needed in a long-running app.
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _boundaryTimer?.cancel();
    _boundaryTimer = null;
    _snoozeTimer?.cancel();
    _snoozeTimer = null;
    onSnoozeScheduled = null;
    _initialized = false;
  }

  /// Cancels the current boundary timer and reschedules it for [planningTime].
  ///
  /// Call this whenever the user saves a new planning time in Settings so the
  /// rollover fires at the correct wall-clock time.
  void updatePlanningTime(TimeOfDay planningTime) {
    _planningTime = planningTime;
    updateCachedPlanningTime(planningTime);
    _boundaryTimer?.cancel();
    _scheduleBoundaryTimer();
    // Immediately re-evaluate planning state in case the new boundary crosses
    // the current wall-clock time (e.g. moving from 08:00 to 23:59 at 10:00
    // would change planningToday() to yesterday without this refresh).
    // Skip _rearmNotificationIfNeeded here — PlanningSettingsNotifier already
    // calls _reschedulePlanningReminder() after this, and _rearmNotificationIfNeeded
    // requires timezone init that is unavailable in unit tests.
    unawaited(refreshPlanningState());
  }

  /// Schedules a one-shot timer that clears the snooze flag when [until] is
  /// reached, then re-arms the planning notification if appropriate.
  void scheduleSnoozeTimer(DateTime until) {
    _snoozeTimer?.cancel();
    final delay = until.difference(DateTime.now());
    if (delay.isNegative) return;
    _snoozeTimer = Timer(delay, _onSnoozeExpired);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  // ---------------------------------------------------------------------------

  void _scheduleBoundaryTimer() {
    final now = DateTime.now();
    final todayBoundary = DateTime(
      now.year,
      now.month,
      now.day,
      _planningTime.hour,
      _planningTime.minute,
    );
    final nextBoundary = now.isBefore(todayBoundary)
        ? todayBoundary
        : todayBoundary.add(const Duration(days: 1));
    final delay = nextBoundary.difference(now);
    _boundaryTimer = Timer(delay, () async {
      try {
        await _refresh();
      } catch (e, st) {
        debugPrint('DailyStateRefresher: boundary refresh failed: $e\n$st');
      } finally {
        _scheduleBoundaryTimer();
      }
    });
  }

  Future<void> _refresh() async {
    await refreshPlanningState();
    await _rearmNotificationIfNeeded();
  }

  Future<void> _onSnoozeExpired() async {
    clearNotificationSnooze();
    await _rearmNotificationIfNeeded();
  }

  Future<void> _rearmNotificationIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final notificationEnabled = prefs.getBool(kSettingsNotificationEnabled) ?? true;
    if (notificationEnabled && !isNotificationSuppressedToday()) {
      await NotificationService.instance
          .schedulePlanningReminder(time: _planningTime);
    }
  }
}
