import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/planning_settings_keys.dart';
import '../models/focus_session_planning_settings.dart';
import '../services/daily_state_refresher.dart';
import '../services/notification_service.dart';
import 'focus_session_planning_provider.dart';

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
    _migrateAndLoadFromPrefs();
    return const FocusSessionPlanningSettings();
  }

  Future<void> _migrateAndLoadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();

    // One-time migration from old planning_settings_* keys.
    // No-op on fresh install or after migration already ran.
    const migrations = {
      'planning_settings_time_hour': kSettingsTimeHour,
      'planning_settings_time_minute': kSettingsTimeMinute,
      'planning_settings_notification_enabled': kSettingsNotificationEnabled,
      'planning_settings_banner_enabled': _kBannerEnabled,
      'planning_settings_default_snooze_duration': _kDefaultSnoozeDuration,
    };
    for (final entry in migrations.entries) {
      final oldKey = entry.key;
      final newKey = entry.value;
      if (prefs.containsKey(oldKey) && !prefs.containsKey(newKey)) {
        final value = prefs.get(oldKey);
        if (value is int) await prefs.setInt(newKey, value);
        if (value is bool) await prefs.setBool(newKey, value);
        await prefs.remove(oldKey);
      }
    }

    final hour = prefs.getInt(kSettingsTimeHour) ?? 8;
    final minute = prefs.getInt(kSettingsTimeMinute) ?? 0;
    final notificationEnabled =
        prefs.getBool(kSettingsNotificationEnabled) ?? true;
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
    await prefs.setInt(kSettingsTimeHour, time.hour);
    await prefs.setInt(kSettingsTimeMinute, time.minute);
    state = state.copyWith(planningTime: time);
    // Keep the boundary timer and cached planning time in sync so the rollover
    // fires at the correct wall-clock time.
    DailyStateRefresher.instance.updatePlanningTime(time);
    await _rescheduleFocusSessionPlanningReminder();
  }

  Future<void> setNotificationEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kSettingsNotificationEnabled, enabled);
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
    } else if (!state.notificationEnabled) {
      // Fully disabled: cancel both the recurring reminder and any snooze.
      await svc.cancelFocusSessionPlanningReminder();
    } else {
      // Temporarily suppressed (skip/snooze): cancel only the recurring
      // reminder so an active snooze notification is not wiped.
      await svc.cancelRecurringFocusSessionPlanningReminder();
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
      prefs.getBool(kSettingsNotificationEnabled) ?? true;
  if (!notificationEnabled) {
    // Fully disabled: cancel both the recurring reminder and any snooze.
    await svc.cancelFocusSessionPlanningReminder();
    return;
  }
  if (isFocusSessionPlanningNotificationSuppressed()) {
    // Temporarily suppressed (skip/snooze): cancel only the recurring
    // reminder so an active snooze notification survives the restart.
    await svc.cancelRecurringFocusSessionPlanningReminder();
    return;
  }

  final hour = prefs.getInt(kSettingsTimeHour) ?? 8;
  final minute = prefs.getInt(kSettingsTimeMinute) ?? 0;
  await svc.scheduleFocusSessionPlanningReminder(
      time: TimeOfDay(hour: hour, minute: minute));
}
