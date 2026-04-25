import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_settings_provider.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Stub NotificationService — no-ops all platform channel calls
// ---------------------------------------------------------------------------

class _StubNotificationService extends NotificationService {
  _StubNotificationService() : super.forTesting();

  @override
  Future<void> scheduleFocusSessionPlanningReminder(
      {required TimeOfDay time}) async {}

  @override
  Future<void> cancelFocusSessionPlanningReminder() async {}

  @override
  Future<void> cancelRecurringFocusSessionPlanningReminder() async {}

  @override
  Future<void> snoozeFocusSessionPlanningReminder(int minutes) async {}

  @override
  Future<void> cancelReminder(int id) async {}

  @override
  Future<void> cancelAll() async {}
}

ProviderContainer _container() => ProviderContainer(
      overrides: [
        databaseProvider
            .overrideWithValue(GtdDatabase(NativeDatabase.memory())),
        notificationServiceProvider
            .overrideWithValue(_StubNotificationService()),
      ],
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('FocusSessionPlanningSettingsNotifier', () {
    late ProviderContainer container;

    setUp(() {
      container = _container();
    });

    tearDown(() => container.dispose());

    test('defaults are applied when no persisted values exist', () {
      final settings = container.read(focusSessionPlanningSettingsProvider);
      expect(settings.planningTime,
          equals(const TimeOfDay(hour: 8, minute: 0)));
      expect(settings.notificationEnabled, isTrue);
      expect(settings.bannerEnabled, isTrue);
      expect(settings.defaultSnoozeDuration, equals(60));
    });

    test('setBannerEnabled persists and updates state', () async {
      final notifier =
          container.read(focusSessionPlanningSettingsProvider.notifier);
      await notifier.setBannerEnabled(false);

      expect(container.read(focusSessionPlanningSettingsProvider).bannerEnabled,
          isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(
          prefs.getBool('focus_session_planning_settings_banner_enabled'),
          isFalse);
    });

    test('setNotificationEnabled persists and updates state', () async {
      final notifier =
          container.read(focusSessionPlanningSettingsProvider.notifier);
      await notifier.setNotificationEnabled(false);

      expect(
          container
              .read(focusSessionPlanningSettingsProvider)
              .notificationEnabled,
          isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(
          prefs.getBool(
              'focus_session_planning_settings_notification_enabled'),
          isFalse);
    });

    test('setPlanningTime persists hour and minute', () async {
      final notifier =
          container.read(focusSessionPlanningSettingsProvider.notifier);
      await notifier.setPlanningTime(const TimeOfDay(hour: 7, minute: 30));

      final settings = container.read(focusSessionPlanningSettingsProvider);
      expect(settings.planningTime.hour, equals(7));
      expect(settings.planningTime.minute, equals(30));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('focus_session_planning_settings_time_hour'),
          equals(7));
      expect(prefs.getInt('focus_session_planning_settings_time_minute'),
          equals(30));
    });

    test('setDefaultSnoozeDuration persists and updates state', () async {
      final notifier =
          container.read(focusSessionPlanningSettingsProvider.notifier);
      await notifier.setDefaultSnoozeDuration(15);

      expect(
          container
              .read(focusSessionPlanningSettingsProvider)
              .defaultSnoozeDuration,
          equals(15));

      final prefs = await SharedPreferences.getInstance();
      expect(
          prefs.getInt(
              'focus_session_planning_settings_default_snooze_duration'),
          equals(15));
    });

    test('settings survive across provider container recreation', () async {
      final notifier =
          container.read(focusSessionPlanningSettingsProvider.notifier);
      await notifier.setBannerEnabled(false);
      await notifier.setPlanningTime(const TimeOfDay(hour: 9, minute: 15));

      container.dispose();

      // New container — reads from SharedPreferences.
      final newContainer = _container();
      addTearDown(newContainer.dispose);

      // Trigger async load and wait for it to complete.
      newContainer.read(focusSessionPlanningSettingsProvider);
      await Future.delayed(Duration.zero);

      final settings = newContainer.read(focusSessionPlanningSettingsProvider);
      expect(settings.bannerEnabled, isFalse);
      expect(settings.planningTime.hour, equals(9));
      expect(settings.planningTime.minute, equals(15));
    });
  });

  group('FocusSessionPlanningSettingsNotifier — prefs migration', () {
    late ProviderContainer container;

    tearDown(() => container.dispose());

    test('migrates old planning_settings_* keys to new names on first run',
        () async {
      // Seed old keys as if an existing user is upgrading.
      SharedPreferences.setMockInitialValues({
        'planning_settings_time_hour': 9,
        'planning_settings_time_minute': 30,
        'planning_settings_notification_enabled': false,
        'planning_settings_banner_enabled': false,
        'planning_settings_default_snooze_duration': 15,
      });

      container = _container();
      container.read(focusSessionPlanningSettingsProvider);
      await Future.delayed(Duration.zero);

      final prefs = await SharedPreferences.getInstance();

      // Old keys should be removed.
      expect(prefs.containsKey('planning_settings_time_hour'), isFalse);
      expect(prefs.containsKey('planning_settings_banner_enabled'), isFalse);

      // New keys should hold the migrated values.
      expect(prefs.getInt('focus_session_planning_settings_time_hour'),
          equals(9));
      expect(prefs.getInt('focus_session_planning_settings_time_minute'),
          equals(30));
      expect(
          prefs.getBool(
              'focus_session_planning_settings_notification_enabled'),
          isFalse);
      expect(
          prefs.getBool('focus_session_planning_settings_banner_enabled'),
          isFalse);
      expect(
          prefs.getInt(
              'focus_session_planning_settings_default_snooze_duration'),
          equals(15));

      // State should reflect migrated values.
      final settings = container.read(focusSessionPlanningSettingsProvider);
      expect(settings.planningTime.hour, equals(9));
      expect(settings.bannerEnabled, isFalse);
    });

    test('migration is no-op when new keys already exist', () async {
      // Simulate post-migration state: new keys present, old keys absent.
      SharedPreferences.setMockInitialValues({
        'focus_session_planning_settings_time_hour': 7,
        'focus_session_planning_settings_banner_enabled': false,
      });

      container = _container();
      container.read(focusSessionPlanningSettingsProvider);
      await Future.delayed(Duration.zero);

      final prefs = await SharedPreferences.getInstance();

      // New keys unchanged.
      expect(prefs.getInt('focus_session_planning_settings_time_hour'),
          equals(7));
      expect(
          prefs.getBool('focus_session_planning_settings_banner_enabled'),
          isFalse);

      // Old keys never introduced.
      expect(prefs.containsKey('planning_settings_time_hour'), isFalse);
    });

    test('migration is no-op on fresh install (neither old nor new keys exist)',
        () async {
      SharedPreferences.setMockInitialValues({});

      container = _container();
      container.read(focusSessionPlanningSettingsProvider);
      await Future.delayed(Duration.zero);

      final settings = container.read(focusSessionPlanningSettingsProvider);

      // Defaults used.
      expect(settings.planningTime, equals(const TimeOfDay(hour: 8, minute: 0)));
      expect(settings.notificationEnabled, isTrue);
      expect(settings.bannerEnabled, isTrue);
      expect(settings.defaultSnoozeDuration, equals(60));
    });
  });
}
