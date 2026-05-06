import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/focus_session_planning_settings.dart';
import '../services/notification_service.dart';
import 'focus_session_planning_provider.dart';
import 'synced_preferences_provider.dart';

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
    // Re-derive state when synced preferences change (includes cross-device sync).
    ref.listen(syncedPreferencesProvider, (_, next) {
      if (next is AsyncData<SyncedPreferences>) {
        state = _fromPrefs(next.value);
        // Reschedule notification whenever settings change from any device.
        _rescheduleFocusSessionPlanningReminder();
      }
    });
    final current = ref.read(syncedPreferencesProvider).asData?.value;
    return current != null ? _fromPrefs(current) : const FocusSessionPlanningSettings();
  }

  FocusSessionPlanningSettings _fromPrefs(SyncedPreferences prefs) {
    final hour = prefs.get<int>(_kTimeHour) ?? 8;
    final minute = prefs.get<int>(_kTimeMinute) ?? 0;
    return FocusSessionPlanningSettings(
      planningTime: TimeOfDay(hour: hour, minute: minute),
      notificationEnabled: prefs.get<bool>(_kNotificationEnabled) ?? true,
      bannerEnabled: prefs.get<bool>(_kBannerEnabled) ?? true,
      defaultSnoozeDuration: prefs.get<int>(_kDefaultSnoozeDuration) ?? 60,
    );
  }

  Future<void> setPlanningTime(TimeOfDay time) async {
    await syncedPrefs(ref).set(_kTimeHour, time.hour);
    await syncedPrefs(ref).set(_kTimeMinute, time.minute);
  }

  Future<void> setNotificationEnabled(bool enabled) async {
    await syncedPrefs(ref).set(_kNotificationEnabled, enabled);
  }

  Future<void> setBannerEnabled(bool enabled) async {
    await syncedPrefs(ref).set(_kBannerEnabled, enabled);
  }

  Future<void> setDefaultSnoozeDuration(int minutes) async {
    await syncedPrefs(ref).set(_kDefaultSnoozeDuration, minutes);
  }

  Future<void> _rescheduleFocusSessionPlanningReminder() async {
    final svc = ref.read(notificationServiceProvider);
    if (state.notificationEnabled &&
        !isFocusSessionPlanningNotificationSuppressed()) {
      await svc.scheduleFocusSessionPlanningReminder(time: state.planningTime);
    } else if (!state.notificationEnabled) {
      await svc.cancelFocusSessionPlanningReminder();
    } else {
      await svc.cancelRecurringFocusSessionPlanningReminder();
    }
  }
}

/// Restores the planning notification schedule on app startup.
///
/// Reads from SharedPreferences for cold-start (before Riverpod/DB are ready).
/// On the first restart after the preferences migration, SharedPreferences may
/// be empty and defaults (8:00 AM, enabled) are used. The Notifier reschedules
/// at the correct time once syncedPreferencesProvider loads inside the app.
Future<void> initFocusSessionPlanningNotificationSchedule() async {
  await loadFocusSessionPlanningNotificationSuppression();
  final prefs = await SharedPreferences.getInstance();
  final svc = NotificationService.instance;
  final notificationEnabled = prefs.getBool(_kNotificationEnabled) ?? true;
  if (!notificationEnabled) {
    await svc.cancelFocusSessionPlanningReminder();
    return;
  }
  if (isFocusSessionPlanningNotificationSuppressed()) {
    await svc.cancelRecurringFocusSessionPlanningReminder();
    return;
  }
  final hour = prefs.getInt(_kTimeHour) ?? 8;
  final minute = prefs.getInt(_kTimeMinute) ?? 0;
  await svc.scheduleFocusSessionPlanningReminder(
      time: TimeOfDay(hour: hour, minute: minute));
}
