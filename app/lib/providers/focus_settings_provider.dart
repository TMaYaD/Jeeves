import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/focus_settings.dart';

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
    _loadFromPrefs();
    return const FocusSettings();
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    state = FocusSettings(
      sprintDurationMinutes: prefs.getInt(_kSprintDurationMinutes) ?? 20,
      breakDurationMinutes: prefs.getInt(_kBreakDurationMinutes) ?? 3,
    );
  }

  Future<void> setSprintDurationMinutes(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSprintDurationMinutes, minutes);
    state = state.copyWith(sprintDurationMinutes: minutes);
  }

  Future<void> setBreakDurationMinutes(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kBreakDurationMinutes, minutes);
    state = state.copyWith(breakDurationMinutes: minutes);
  }
}
