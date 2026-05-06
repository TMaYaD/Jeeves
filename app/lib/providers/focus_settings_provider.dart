import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/focus_settings.dart';
import 'synced_preferences_provider.dart';

// Public so sprint_timer_provider can read directly to avoid async-load race.
const kFocusSprintDurationMinutesPrefKey = 'focus_settings_sprint_duration_minutes';
const kFocusBreakDurationMinutesPrefKey = 'focus_settings_break_duration_minutes';

const _kSprintDurationMinutes = kFocusSprintDurationMinutesPrefKey;
const _kBreakDurationMinutes = kFocusBreakDurationMinutesPrefKey;

final focusSettingsProvider =
    NotifierProvider<FocusSettingsNotifier, FocusSettings>(
  FocusSettingsNotifier.new,
);

class FocusSettingsNotifier extends Notifier<FocusSettings> {
  @override
  FocusSettings build() {
    // Re-derive state whenever synced preferences change.
    ref.listen(syncedPreferencesProvider, (_, next) {
      if (next is AsyncData<SyncedPreferences>) {
        state = _fromPrefs(next.value);
      }
    });
    // Return defaults immediately; updated by listener once DB loads.
    final current = ref.read(syncedPreferencesProvider).asData?.value;
    return current != null ? _fromPrefs(current) : const FocusSettings();
  }

  FocusSettings _fromPrefs(SyncedPreferences prefs) => FocusSettings(
        sprintDurationMinutes:
            prefs.get<int>(_kSprintDurationMinutes) ?? 20,
        breakDurationMinutes:
            prefs.get<int>(_kBreakDurationMinutes) ?? 3,
      );

  Future<void> setSprintDurationMinutes(int minutes) async {
    await syncedPrefs(ref).set(_kSprintDurationMinutes, minutes);
    state = state.copyWith(sprintDurationMinutes: minutes);
  }

  Future<void> setBreakDurationMinutes(int minutes) async {
    await syncedPrefs(ref).set(_kBreakDurationMinutes, minutes);
    state = state.copyWith(breakDurationMinutes: minutes);
  }
}
