import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/focus_settings.dart';
import 'synced_preferences_provider.dart';

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
        sprintDurationMinutes: _readCount(
          prefs,
          kFocusSprintDurationMinutesPrefKey,
          kDefaultSprintDurationMinutes,
        ),
        shortBreakDurationMinutes: _readCount(
          prefs,
          kFocusBreakDurationMinutesPrefKey,
          kDefaultShortBreakDurationMinutes,
        ),
        longBreakDurationMinutes: _readCount(
          prefs,
          kFocusLongBreakDurationMinutesPrefKey,
          kDefaultLongBreakDurationMinutes,
        ),
        sprintsBeforeLongBreak: _readCount(
          prefs,
          kFocusSprintsBeforeLongBreakPrefKey,
          kDefaultSprintsBeforeLongBreak,
        ),
      );

  /// Reads one length or count, treating anything unusable as the default.
  ///
  /// The merge cannot validate a value, so the reader is the only guard
  /// against a budget of zero: a missing key, a tombstone, a value that is
  /// not an integer and a value below one all read as the default.
  static int _readCount(SyncedPreferences prefs, String key, int fallback) {
    final value = prefs.get<int>(key);
    if (value == null || value < 1) return fallback;
    return value;
  }

  Future<void> setSprintDurationMinutes(int minutes) async {
    final value = minutes < 1 ? kDefaultSprintDurationMinutes : minutes;
    await syncedPrefs(ref).set(kFocusSprintDurationMinutesPrefKey, value);
    state = state.copyWith(sprintDurationMinutes: value);
  }

  Future<void> setShortBreakDurationMinutes(int minutes) async {
    final value = minutes < 1 ? kDefaultShortBreakDurationMinutes : minutes;
    await syncedPrefs(ref).set(kFocusBreakDurationMinutesPrefKey, value);
    state = state.copyWith(shortBreakDurationMinutes: value);
  }

  Future<void> setLongBreakDurationMinutes(int minutes) async {
    final value = minutes < 1 ? kDefaultLongBreakDurationMinutes : minutes;
    await syncedPrefs(ref).set(kFocusLongBreakDurationMinutesPrefKey, value);
    state = state.copyWith(longBreakDurationMinutes: value);
  }

  Future<void> setSprintsBeforeLongBreak(int sprints) async {
    final value = sprints < 1 ? kDefaultSprintsBeforeLongBreak : sprints;
    await syncedPrefs(ref).set(kFocusSprintsBeforeLongBreakPrefKey, value);
    state = state.copyWith(sprintsBeforeLongBreak: value);
  }
}
