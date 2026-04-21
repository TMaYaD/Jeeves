import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/daily_planning_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import '../test_helpers.dart';

// Minimal stub — avoids hitting NotificationService platform channels in unit tests.
class _StubDailyPlanningNotifier extends DailyPlanningNotifier {
  @override
  Future<void> dismissBannerForToday() async {
    final today = planningToday();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('planning_banner_dismissed_date', today);
    bannerDismissedNotifier.value = true;
  }

  @override
  Future<void> skipPlanningToday() async {
    await persistSkipToday();
    // NotificationService not called in tests.
  }

  @override
  Future<void> snoozePlanningNotification(int minutes) async {
    final until = DateTime.now().add(Duration(minutes: minutes));
    await persistSnoozedUntil(until);
    // NotificationService not called in tests.
  }
}

ProviderContainer _container(GtdDatabase db) => ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        dailyPlanningProvider.overrideWith(() => _StubDailyPlanningNotifier()),
      ],
    );

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DailyPlanningNotifier', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = _container(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      planningCompletionNotifier.value = false;
      bannerDismissedNotifier.value = false;
    });

    test('startDay preserves energyLevel and availableMinutes', () async {
      final notifier = container.read(dailyPlanningProvider.notifier);

      notifier.setEnergyLevel('medium');
      notifier.setAvailableTime(300); // 5 hours

      await notifier.startDay();

      final stateAfterStart = container.read(dailyPlanningProvider);
      expect(stateAfterStart.energyLevel, 'medium',
          reason: 'startDay should not clear energy level');
      expect(stateAfterStart.availableMinutes, 300,
          reason: 'startDay should not clear available minutes');
      expect(stateAfterStart.availableTimeSet, isTrue,
          reason: 'startDay should not clear availableTimeSet flag');
    });

    test('reEnterPlanning restores energy and time after startDay', () async {
      final notifier = container.read(dailyPlanningProvider.notifier);

      notifier.setEnergyLevel('high');
      notifier.setAvailableTime(360); // 6 hours

      await notifier.startDay();
      await notifier.reEnterPlanning();

      final state = container.read(dailyPlanningProvider);
      expect(state.energyLevel, 'high',
          reason: 'reEnterPlanning should restore energy from before startDay');
      expect(state.availableMinutes, 360,
          reason: 'reEnterPlanning should restore available minutes');
      expect(state.availableTimeSet, isTrue,
          reason: 'reEnterPlanning should restore availableTimeSet flag');
      expect(state.currentStep, 0,
          reason: 'reEnterPlanning should reset to step 0');
    });

    test('startDay resets step and inbox counters', () async {
      final notifier = container.read(dailyPlanningProvider.notifier);

      notifier.setInitialInboxCount(5);
      notifier.advanceStep();
      notifier.advanceStep();

      await notifier.startDay();

      final state = container.read(dailyPlanningProvider);
      expect(state.currentStep, 0);
      expect(state.initialInboxCount, isNull);
      expect(state.inboxClarifiedCount, 0);
      expect(state.inboxSkippedCount, 0);
    });
  });

  group('DailyPlanningNotifier — banner dismissal', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = _container(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      bannerDismissedNotifier.value = false;
      planningCompletionNotifier.value = false;
    });

    test('dismissBannerForToday sets bannerDismissedNotifier and persists',
        () async {
      final notifier = container.read(dailyPlanningProvider.notifier);
      expect(bannerDismissedNotifier.value, isFalse);

      await notifier.dismissBannerForToday();

      expect(bannerDismissedNotifier.value, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('planning_banner_dismissed_date'),
          equals(planningToday()));
    });

    test('bannerDismissedNotifier resets to false for a different day',
        () async {
      // Simulate yesterday's dismissal persisted.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('planning_banner_dismissed_date', '2000-01-01');
      await initPlanningCompletion();

      // Today does not match '2000-01-01'.
      expect(bannerDismissedNotifier.value, isFalse);
    });
  });

  group('DailyPlanningNotifier — skip and snooze', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = _container(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      // Reset SharedPreferences mock and reload suppression flags to clear state.
      SharedPreferences.setMockInitialValues({});
      await loadNotificationSuppression();
    });

    test('skipPlanningToday sets skipped flag for today', () async {
      final notifier = container.read(dailyPlanningProvider.notifier);
      await notifier.skipPlanningToday();

      expect(isNotificationSuppressedToday(), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('planning_notification_skipped_date'),
          equals(planningToday()));
    });

    test('snoozePlanningNotification sets snoozed-until in the future',
        () async {
      final notifier = container.read(dailyPlanningProvider.notifier);
      await notifier.snoozePlanningNotification(60);

      expect(isNotificationSuppressedToday(), isTrue);

      final prefs = await SharedPreferences.getInstance();
      final stored =
          DateTime.tryParse(prefs.getString('planning_notification_snoozed_until') ?? '');
      expect(stored, isNotNull);
      expect(stored!.isAfter(DateTime.now()), isTrue);
    });

    test('loadNotificationSuppression reflects skipped state', () async {
      // Persist the skip date directly without going through persistSkipToday
      // so we can independently verify loadNotificationSuppression picks it up.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('planning_notification_skipped_date', planningToday());

      await loadNotificationSuppression();
      expect(isNotificationSuppressedToday(), isTrue);
    });

    test('skip state from a previous day does not suppress today', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('planning_notification_skipped_date', '2000-01-01');
      await loadNotificationSuppression();

      expect(isNotificationSuppressedToday(), isFalse);
    });
  });
}
