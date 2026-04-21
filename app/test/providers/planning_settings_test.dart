import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/planning_settings_provider.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Stub NotificationService — no-ops all platform channel calls
// ---------------------------------------------------------------------------

class _StubNotificationService extends NotificationService {
  _StubNotificationService() : super.forTesting();

  @override
  Future<void> schedulePlanningReminder({required TimeOfDay time}) async {}

  @override
  Future<void> cancelPlanningReminder() async {}

  @override
  Future<void> snoozePlanningReminder(int minutes) async {}

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

  group('PlanningSettingsNotifier', () {
    late ProviderContainer container;

    setUp(() {
      container = _container();
    });

    tearDown(() => container.dispose());

    test('defaults are applied when no persisted values exist', () {
      final settings = container.read(planningSettingsProvider);
      expect(settings.planningTime,
          equals(const TimeOfDay(hour: 8, minute: 0)));
      expect(settings.notificationEnabled, isTrue);
      expect(settings.bannerEnabled, isTrue);
      expect(settings.defaultSnoozeDuration, equals(60));
    });

    test('setBannerEnabled persists and updates state', () async {
      final notifier =
          container.read(planningSettingsProvider.notifier);
      await notifier.setBannerEnabled(false);

      expect(container.read(planningSettingsProvider).bannerEnabled, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('planning_settings_banner_enabled'), isFalse);
    });

    test('setNotificationEnabled persists and updates state', () async {
      final notifier =
          container.read(planningSettingsProvider.notifier);
      await notifier.setNotificationEnabled(false);

      expect(container.read(planningSettingsProvider).notificationEnabled,
          isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('planning_settings_notification_enabled'), isFalse);
    });

    test('setPlanningTime persists hour and minute', () async {
      final notifier =
          container.read(planningSettingsProvider.notifier);
      await notifier.setPlanningTime(const TimeOfDay(hour: 7, minute: 30));

      final settings = container.read(planningSettingsProvider);
      expect(settings.planningTime.hour, equals(7));
      expect(settings.planningTime.minute, equals(30));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('planning_settings_time_hour'), equals(7));
      expect(prefs.getInt('planning_settings_time_minute'), equals(30));
    });

    test('setDefaultSnoozeDuration persists and updates state', () async {
      final notifier =
          container.read(planningSettingsProvider.notifier);
      await notifier.setDefaultSnoozeDuration(15);

      expect(
          container.read(planningSettingsProvider).defaultSnoozeDuration,
          equals(15));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('planning_settings_default_snooze_duration'),
          equals(15));
    });

    test('settings survive across provider container recreation', () async {
      final notifier =
          container.read(planningSettingsProvider.notifier);
      await notifier.setBannerEnabled(false);
      await notifier.setPlanningTime(const TimeOfDay(hour: 9, minute: 15));

      container.dispose();

      // New container — reads from SharedPreferences.
      final newContainer = _container();
      addTearDown(newContainer.dispose);

      // Trigger async load and wait for it to complete.
      newContainer.read(planningSettingsProvider);
      await Future.delayed(Duration.zero);

      final settings = newContainer.read(planningSettingsProvider);
      expect(settings.bannerEnabled, isFalse);
      expect(settings.planningTime.hour, equals(9));
      expect(settings.planningTime.minute, equals(15));
    });
  });
}
