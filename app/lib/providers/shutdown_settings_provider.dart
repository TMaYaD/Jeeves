import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/shutdown_settings.dart';
import 'synced_preferences_provider.dart';

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
    // Re-derive state when synced preferences change (includes cross-device sync).
    ref.listen(syncedPreferencesProvider, (_, next) {
      if (next is AsyncData<SyncedPreferences>) {
        state = _fromPrefs(next.value);
      }
    });
    final current = ref.read(syncedPreferencesProvider).asData?.value;
    return current != null ? _fromPrefs(current) : const ShutdownSettings();
  }

  ShutdownSettings _fromPrefs(SyncedPreferences prefs) {
    return ShutdownSettings(
      shutdownTime: TimeOfDay(
        hour: prefs.get<int>(_kShutdownTimeHour) ?? 18,
        minute: prefs.get<int>(_kShutdownTimeMinute) ?? 0,
      ),
      notificationEnabled:
          prefs.get<bool>(_kShutdownNotificationEnabled) ?? true,
      bannerEnabled: prefs.get<bool>(_kShutdownBannerEnabled) ?? true,
    );
  }

  Future<void> setShutdownTime(TimeOfDay time) async {
    await syncedPrefs(ref).setMany({
      _kShutdownTimeHour: time.hour,
      _kShutdownTimeMinute: time.minute,
    });
  }

  Future<void> setNotificationEnabled(bool enabled) async {
    await syncedPrefs(ref).set(_kShutdownNotificationEnabled, enabled);
  }

  Future<void> setBannerEnabled(bool enabled) async {
    await syncedPrefs(ref).set(_kShutdownBannerEnabled, enabled);
  }
}
