import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_settings_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Stub NotificationService — no-ops all platform channel calls
// ---------------------------------------------------------------------------

class _StubNotificationService extends NotificationService {
  _StubNotificationService() : super.forTesting();

  @override
  Future<void> scheduleRitualReminder(
      RitualId ritual, TimeOfDay time) async {}

  @override
  Future<void> cancelRitualReminder(RitualId ritual) async {}

  @override
  Future<void> cancelRecurringRitualReminder(RitualId ritual) async {}

  @override
  Future<void> snoozeRitualReminder(RitualId ritual, int minutes) async {}

  @override
  Future<void> skipTodayRitualReminder(RitualId ritual) async {}

  @override
  Future<void> cancelReminder(int id) async {}

  @override
  Future<void> cancelAll() async {}
}

ProviderContainer _container({GtdDatabase? db}) => ProviderContainer(
      overrides: [
        databaseProvider
            .overrideWithValue(db ?? GtdDatabase(NativeDatabase.memory())),
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
      expect(settings.defaultTimeEstimate, equals(10));
    });

    test('setDefaultTimeEstimate persists and updates state', () async {
      await container.read(syncedPreferencesProvider.future);
      final notifier =
          container.read(focusSessionPlanningSettingsProvider.notifier);
      await notifier.setDefaultTimeEstimate(25);

      expect(
          container
              .read(focusSessionPlanningSettingsProvider)
              .defaultTimeEstimate,
          equals(25));
      expect(
        container.read(syncedPreferencesProvider).asData!.value
            .get<int>('focus_session_planning_settings_default_time_estimate'),
        equals(25),
      );
    });

    test('setBannerEnabled persists and updates state', () async {
      await container.read(syncedPreferencesProvider.future);
      final notifier =
          container.read(focusSessionPlanningSettingsProvider.notifier);
      await notifier.setBannerEnabled(false);

      expect(container.read(focusSessionPlanningSettingsProvider).bannerEnabled,
          isFalse);
      expect(
        container.read(syncedPreferencesProvider).asData!.value
            .get<bool>('focus_session_planning_settings_banner_enabled'),
        isFalse,
      );
    });

    test('setNotificationEnabled persists and updates state', () async {
      await container.read(syncedPreferencesProvider.future);
      final notifier =
          container.read(focusSessionPlanningSettingsProvider.notifier);
      await notifier.setNotificationEnabled(false);

      expect(
          container
              .read(focusSessionPlanningSettingsProvider)
              .notificationEnabled,
          isFalse);
      expect(
        container.read(syncedPreferencesProvider).asData!.value
            .get<bool>('focus_session_planning_settings_notification_enabled'),
        isFalse,
      );
    });

    test('setPlanningTime persists hour and minute', () async {
      await container.read(syncedPreferencesProvider.future);
      final notifier =
          container.read(focusSessionPlanningSettingsProvider.notifier);
      await notifier.setPlanningTime(const TimeOfDay(hour: 7, minute: 30));

      final settings = container.read(focusSessionPlanningSettingsProvider);
      expect(settings.planningTime.hour, equals(7));
      expect(settings.planningTime.minute, equals(30));
      expect(
        container.read(syncedPreferencesProvider).asData!.value
            .get<int>('focus_session_planning_settings_time_hour'),
        equals(7),
      );
      expect(
        container.read(syncedPreferencesProvider).asData!.value
            .get<int>('focus_session_planning_settings_time_minute'),
        equals(30),
      );
    });

    test('setDefaultSnoozeDuration persists and updates state', () async {
      await container.read(syncedPreferencesProvider.future);
      final notifier =
          container.read(focusSessionPlanningSettingsProvider.notifier);
      await notifier.setDefaultSnoozeDuration(15);

      expect(
          container
              .read(focusSessionPlanningSettingsProvider)
              .defaultSnoozeDuration,
          equals(15));
      expect(
        container.read(syncedPreferencesProvider).asData!.value
            .get<int>('focus_session_planning_settings_default_snooze_duration'),
        equals(15),
      );
    });

    test('settings survive across provider container recreation', () async {
      final db = GtdDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final c1 = _container(db: db);
      await c1.read(syncedPreferencesProvider.future);
      await c1.read(focusSessionPlanningSettingsProvider.notifier).setBannerEnabled(false);
      await c1.read(focusSessionPlanningSettingsProvider.notifier).setPlanningTime(
          const TimeOfDay(hour: 9, minute: 15));
      c1.dispose();

      final c2 = _container(db: db);
      addTearDown(c2.dispose);
      await c2.read(syncedPreferencesProvider.future);
      // Flush the syncedPreferences listener in FocusSessionPlanningSettingsNotifier.
      await Future.delayed(Duration.zero);

      final settings = c2.read(focusSessionPlanningSettingsProvider);
      expect(settings.bannerEnabled, isFalse);
      expect(settings.planningTime.hour, equals(9));
      expect(settings.planningTime.minute, equals(15));
    });
  });

}
