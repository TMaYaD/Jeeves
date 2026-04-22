import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    if (state.notificationEnabled && !isShutdownNotificationSuppressedToday()) {
      await svc.scheduleShutdownReminder(time: state.shutdownTime);
    } else {
      await svc.cancelShutdownReminder();
    }
  }
}

/// Restores the shutdown notification schedule on app startup.
Future<void> initShutdownNotificationSchedule() async {
  final prefs = await SharedPreferences.getInstance();
  final svc = NotificationService.instance;
  final notificationEnabled =
      prefs.getBool(_kShutdownNotificationEnabled) ?? true;
  if (!notificationEnabled || isShutdownNotificationSuppressedToday()) {
    await svc.cancelShutdownReminder();
    return;
  }

  final hour = prefs.getInt(_kShutdownTimeHour) ?? 18;
  final minute = prefs.getInt(_kShutdownTimeMinute) ?? 0;
  await svc.scheduleShutdownReminder(
      time: TimeOfDay(hour: hour, minute: minute));
}
