import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ritual.dart';
import '../models/shutdown_settings.dart';
import '../services/notification_service.dart';
import 'evening_shutdown_provider.dart';

const _kShutdownTimeHour = 'shutdown_settings_time_hour';
const _kShutdownTimeMinute = 'shutdown_settings_time_minute';
const _kShutdownNotificationEnabled = 'shutdown_settings_notification_enabled';
const _kShutdownBannerEnabled = 'shutdown_settings_banner_enabled';

final shutdownSettingsProvider =
    NotifierProvider<ShutdownSettingsNotifier, ShutdownSettings>(
  ShutdownSettingsNotifier.new,
);

class ShutdownSettingsNotifier extends Notifier<ShutdownSettings> {
  @override
  ShutdownSettings build() {
    _loadFromPrefs();
    return const ShutdownSettings();
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final hour = prefs.getInt(_kShutdownTimeHour) ?? 18;
    final minute = prefs.getInt(_kShutdownTimeMinute) ?? 0;
    final notificationEnabled =
        prefs.getBool(_kShutdownNotificationEnabled) ?? true;
    final bannerEnabled = prefs.getBool(_kShutdownBannerEnabled) ?? true;

    state = ShutdownSettings(
      shutdownTime: TimeOfDay(hour: hour, minute: minute),
      notificationEnabled: notificationEnabled,
      bannerEnabled: bannerEnabled,
    );
  }

  Future<void> setShutdownTime(TimeOfDay time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kShutdownTimeHour, time.hour);
    await prefs.setInt(_kShutdownTimeMinute, time.minute);
    state = state.copyWith(shutdownTime: time);
    await _rescheduleShutdownReminder();
  }

  Future<void> setNotificationEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShutdownNotificationEnabled, enabled);
    state = state.copyWith(notificationEnabled: enabled);
    await _rescheduleShutdownReminder();
  }

  Future<void> setBannerEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShutdownBannerEnabled, enabled);
    state = state.copyWith(bannerEnabled: enabled);
  }

  Future<void> _rescheduleShutdownReminder() async {
    final svc = ref.read(notificationServiceProvider);
    // See focus_session_planning_settings_provider for the rationale: three
    // states, in priority order — disabled / skipped-today / otherwise. A
    // pending snooze falls through to the schedule path so its one-off (on a
    // separate id) is preserved while the recurring schedule is re-armed.
    if (!state.notificationEnabled) {
      await svc.cancelRitualReminder(RitualId.eveningShutdown);
    } else if (isShutdownNotificationSkippedToday()) {
      await svc.cancelRecurringRitualReminder(RitualId.eveningShutdown);
    } else {
      await svc.scheduleRitualReminder(
          RitualId.eveningShutdown, state.shutdownTime);
    }
  }
}

/// Restores the shutdown notification schedule on app startup.
Future<void> initShutdownNotificationSchedule() async {
  final prefs = await SharedPreferences.getInstance();
  final svc = NotificationService.instance;
  final notificationEnabled =
      prefs.getBool(_kShutdownNotificationEnabled) ?? true;
  if (!notificationEnabled) {
    await svc.cancelRitualReminder(RitualId.eveningShutdown);
    return;
  }
  if (isShutdownNotificationSkippedToday()) {
    // Skip-today only — drop today's recurring fire; preserve any pending
    // snooze on its own id by not calling cancelRitualReminder.
    await svc.cancelRecurringRitualReminder(RitualId.eveningShutdown);
    return;
  }
  // Normal path (and snoozed-only): re-arm the recurring schedule.
  final hour = prefs.getInt(_kShutdownTimeHour) ?? 18;
  final minute = prefs.getInt(_kShutdownTimeMinute) ?? 0;
  await svc.scheduleRitualReminder(
      RitualId.eveningShutdown, TimeOfDay(hour: hour, minute: minute));
}
