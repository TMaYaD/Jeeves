/// [FocusSettingsNotifier]: the settings the long Break is read from
/// (issue #911).
///
/// A preference can arrive in a shape the settings cannot use — absent,
/// tombstoned, the wrong type, below one — and the budget that decides the
/// long Break must never be zero. Every unusable value reads as the default.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/focus_settings.dart';
import 'package:jeeves/providers/focus_settings_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';

/// Synced preferences with a fixed map, and a record of what was written.
class _FakeSyncedPreferences extends SyncedPreferencesNotifier {
  final Map<String, dynamic> values;
  final Map<String, dynamic> writes = {};

  _FakeSyncedPreferences([Map<String, dynamic>? values])
      : values = values ?? <String, dynamic>{};

  @override
  Future<SyncedPreferences> build() async => SyncedPreferences(values);

  @override
  Future<void> set(String key, dynamic value) async {
    writes[key] = value;
  }
}

Future<ProviderContainer> _container(Map<String, dynamic> values) async {
  final container = ProviderContainer(overrides: [
    syncedPreferencesProvider.overrideWith(() => _FakeSyncedPreferences(values)),
  ]);
  addTearDown(container.dispose);
  container.read(focusSettingsProvider);
  await container.read(syncedPreferencesProvider.future);
  await pumpEventQueue();
  return container;
}

void main() {
  test('with nothing stored, every setting reads as its default', () async {
    final container = await _container({});
    final settings = container.read(focusSettingsProvider);
    expect(settings.sprintDurationMinutes, kDefaultSprintDurationMinutes);
    expect(settings.shortBreakDurationMinutes, kDefaultShortBreakDurationMinutes);
    expect(settings.longBreakDurationMinutes, kDefaultLongBreakDurationMinutes);
    expect(settings.sprintsBeforeLongBreak, kDefaultSprintsBeforeLongBreak);
  });

  test('a stored value is read', () async {
    final container = await _container({
      kFocusLongBreakDurationMinutesPrefKey: 25,
      kFocusSprintsBeforeLongBreakPrefKey: 6,
    });
    final settings = container.read(focusSettingsProvider);
    expect(settings.longBreakDurationMinutes, 25);
    expect(settings.sprintsBeforeLongBreak, 6);
  });

  test('a tombstoned setting reads as its default', () async {
    // A tombstone is a row with a null value; the snapshot leaves the key out.
    final container = await _container({
      kFocusLongBreakDurationMinutesPrefKey: 25,
    });
    final settings = container.read(focusSettingsProvider);
    expect(settings.longBreakDurationMinutes, 25);

    final cleared = await _container({
      kFocusLongBreakDurationMinutesPrefKey: null,
    });
    expect(cleared.read(focusSettingsProvider).longBreakDurationMinutes,
        kDefaultLongBreakDurationMinutes);
  });

  test('a setting of the wrong type reads as its default', () async {
    final container = await _container({
      kFocusLongBreakDurationMinutesPrefKey: '25',
      kFocusSprintsBeforeLongBreakPrefKey: 2.5,
    });
    final settings = container.read(focusSettingsProvider);
    expect(settings.longBreakDurationMinutes, kDefaultLongBreakDurationMinutes);
    expect(settings.sprintsBeforeLongBreak, kDefaultSprintsBeforeLongBreak);
  });

  test('a setting below one reads as its default', () async {
    final container = await _container({
      kFocusLongBreakDurationMinutesPrefKey: 0,
      kFocusSprintsBeforeLongBreakPrefKey: -3,
    });
    final settings = container.read(focusSettingsProvider);
    expect(settings.longBreakDurationMinutes, kDefaultLongBreakDurationMinutes);
    expect(settings.sprintsBeforeLongBreak, kDefaultSprintsBeforeLongBreak);
  });

  group('the setters', () {
    test('a value below one is stored as the default', () async {
      final container = await _container({});
      final notifier = container.read(focusSettingsProvider.notifier);
      final prefs = container.read(syncedPreferencesProvider.notifier)
          as _FakeSyncedPreferences;

      await notifier.setLongBreakDurationMinutes(0);
      expect(container.read(focusSettingsProvider).longBreakDurationMinutes,
          kDefaultLongBreakDurationMinutes);
      expect(prefs.writes[kFocusLongBreakDurationMinutesPrefKey],
          kDefaultLongBreakDurationMinutes);

      await notifier.setSprintsBeforeLongBreak(0);
      expect(container.read(focusSettingsProvider).sprintsBeforeLongBreak,
          kDefaultSprintsBeforeLongBreak);
      expect(prefs.writes[kFocusSprintsBeforeLongBreakPrefKey],
          kDefaultSprintsBeforeLongBreak);
    });

    test('a chosen value is stored and read back', () async {
      final container = await _container({});
      final notifier = container.read(focusSettingsProvider.notifier);
      final prefs = container.read(syncedPreferencesProvider.notifier)
          as _FakeSyncedPreferences;

      await notifier.setLongBreakDurationMinutes(30);
      await notifier.setSprintsBeforeLongBreak(5);

      expect(container.read(focusSettingsProvider).longBreakDurationMinutes, 30);
      expect(container.read(focusSettingsProvider).sprintsBeforeLongBreak, 5);
      expect(prefs.writes[kFocusLongBreakDurationMinutesPrefKey], 30);
      expect(prefs.writes[kFocusSprintsBeforeLongBreakPrefKey], 5);
    });
  });
}
