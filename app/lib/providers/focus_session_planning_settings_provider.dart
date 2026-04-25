import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/focus_session_planning_settings.dart';
import '../services/notification_service.dart';
import 'focus_session_planning_provider.dart';

const _kTimeHour = 'focus_session_planning_settings_time_hour';
const _kTimeMinute = 'focus_session_planning_settings_time_minute';
const _kNotificationEnabled =
    'focus_session_planning_settings_notification_enabled';
const _kBannerEnabled = 'focus_session_planning_settings_banner_enabled';
const _kDefaultSnoozeDuration =
    'focus_session_planning_settings_default_snooze_duration';

final focusSessionPlanningSettingsProvider =
    NotifierProvider<FocusSessionPlanningSettingsNotifier,
        FocusSessionPlanningSettings>(
  FocusSessionPlanningSettingsNotifier.new,
);

class FocusSessionPlanningSettingsNotifier
    extends Notifier<FocusSessionPlanningSettings> {
  @override
  FocusSessionPlanningSettings build() {
    // Async init; starts from defaults synchronously.
    _loadFromPrefs();
    return const FocusSessionPlanningSettings();
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();

    final hour = prefs.getInt(_kTimeHour) ?? 8;
    final minute = prefs.getInt(_kTimeMinute) ?? 0;
    final notificationEnabled =
        prefs.getBool(_kNotificationEnabled) ?? true;
    final bannerEnabled = prefs.getBool(_kBannerEnabled) ?? true;
    final defaultSnoozeDuration =
        prefs.getInt(_kDefaultSnoozeDuration) ?? 60;

    state = FocusSessionPlanningSettings(
      planningTime: TimeOfDay(hour: hour, minute: minute),
      notificationEnabled: notificationEnabled,
      bannerEnabled: bannerEnabled,
      defaultSnoozeDuration: defaultSnoozeDuration,
    );
  }

  Future<void> setPlanningTime(TimeOfDay time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kTimeHour, time.hour);
    await prefs.setInt(_kTimeMinute, time.minute);
    state = state.copyWith(planningTime: time);
    await _rescheduleFocusSessionPlanningReminder();
  }

  Future<void> setNotificationEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNotificationEnabled, enabled);
    state = state.copyWith(notificationEnabled: enabled);
    await _rescheduleFocusSessionPlanningReminder();
  }

  Future<void> setBannerEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBannerEnabled, enabled);
    state = state.copyWith(bannerEnabled: enabled);
  }

  Future<void> setDefaultSnoozeDuration(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kDefaultSnoozeDuration, minutes);
    state = state.copyWith(defaultSnoozeDuration: minutes);
  }

  /// Schedules or cancels the daily planning notification based on current
  /// settings and whether the user has already skipped today.
  Future<void> _rescheduleFocusSessionPlanningReminder() async {
    final svc = ref.read(notificationServiceProvider);
    if (state.notificationEnabled &&
        !isFocusSessionPlanningNotificationSuppressed()) {
      await svc.scheduleFocusSessionPlanningReminder(time: state.planningTime);
    } else {
      await svc.cancelFocusSessionPlanningReminder();
    }
  }
}

/// Restores the planning notification schedule on app startup.
///
/// Must be called in [main] after [NotificationService.initialize].
/// Loads skip/snooze suppression state itself before checking it.
Future<void> initFocusSessionPlanningNotificationSchedule() async {
  await loadFocusSessionPlanningNotificationSuppression();
  final prefs = await SharedPreferences.getInstance();
  final svc = NotificationService.instance;
  final notificationEnabled =
      prefs.getBool(_kNotificationEnabled) ?? true;
  if (!notificationEnabled || isFocusSessionPlanningNotificationSuppressed()) {
    // Clear any reminder left scheduled from a previous session so the
    // current (disabled/suppressed) settings are honoured even if the app
    // was killed before [_rescheduleFocusSessionPlanningReminder] could run.
    await svc.cancelFocusSessionPlanningReminder();
    return;
  }

  final hour = prefs.getInt(_kTimeHour) ?? 8;
  final minute = prefs.getInt(_kTimeMinute) ?? 0;
  await svc.scheduleFocusSessionPlanningReminder(
      time: TimeOfDay(hour: hour, minute: minute));
}
