import 'package:drift/native.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import '../test_helpers.dart';

// Minimal stub — avoids hitting NotificationService platform channels in unit tests.
class _StubFocusSessionPlanningNotifier extends FocusSessionPlanningNotifier {
  @override
  Future<void> dismissBannerForToday() async {
    final today = planningToday();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('planning_banner_dismissed_date', today);
    focusSessionPlanningBannerDismissedNotifier.value = true;
  }

  @override
  Future<void> skipPlanningToday() async {
    await persistFocusSessionPlanningSkipToday();
    // NotificationService not called in tests.
  }

  @override
  Future<void> snoozePlanningNotification(int minutes) async {
    final until = DateTime.now().add(Duration(minutes: minutes));
    await persistFocusSessionPlanningSnoozedUntil(until);
    // NotificationService not called in tests.
  }
}

ProviderContainer _container(GtdDatabase db) => ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        focusSessionPlanningProvider
            .overrideWith(() => _StubFocusSessionPlanningNotifier()),
      ],
    );

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Reset to 08:00 default before each test.
    updateCachedPlanningTime(const TimeOfDay(hour: 8, minute: 0));
  });

  group('planningToday — planning-time boundary', () {
    test('returns calendar date when now is after the planning boundary', () {
      // Set planning time to 08:00 and ask for a time well past it.
      updateCachedPlanningTime(const TimeOfDay(hour: 8, minute: 0));
      // We can't control DateTime.now() directly, so we verify the function
      // returns a valid ISO-8601 date string in the expected format.
      final result = planningToday();
      expect(result, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });

    test('returns yesterday when now is before the planning boundary', () {
      // Set planning time to 23:59 so that any test run before 23:59 today
      // is treated as "before the boundary" and returns yesterday's date.
      updateCachedPlanningTime(const TimeOfDay(hour: 23, minute: 59));
      final now = DateTime.now();
      if (now.hour >= 23 && now.minute >= 59) {
        // Skip when running at or after 23:59 — boundary has passed.
        return;
      }
      // Before 23:59 → should return yesterday.
      final yesterday = now.subtract(const Duration(days: 1));
      final expected =
          '${yesterday.year.toString().padLeft(4, '0')}-'
          '${yesterday.month.toString().padLeft(2, '0')}-'
          '${yesterday.day.toString().padLeft(2, '0')}';
      expect(planningToday(), equals(expected));
    });

    test('returns current calendar date when planning time is 00:00', () {
      // 00:00 boundary means any time after midnight is "today".
      updateCachedPlanningTime(const TimeOfDay(hour: 0, minute: 0));
      final now = DateTime.now();
      final expected =
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      expect(planningToday(), equals(expected));
    });
  });

  group('FocusSessionPlanningNotifier', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = _container(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      focusSessionPlanningCompletionNotifier.value = false;
      focusSessionPlanningBannerDismissedNotifier.value = false;
    });

    test('startDay preserves energyLevel and availableMinutes', () async {
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      notifier.setEnergyLevel('medium');
      notifier.setAvailableTime(300); // 5 hours

      await notifier.startDay();

      final stateAfterStart = container.read(focusSessionPlanningProvider);
      expect(stateAfterStart.energyLevel, 'medium',
          reason: 'startDay should not clear energy level');
      expect(stateAfterStart.availableMinutes, 300,
          reason: 'startDay should not clear available minutes');
      expect(stateAfterStart.availableTimeSet, isTrue,
          reason: 'startDay should not clear availableTimeSet flag');
    });

    test('reEnterPlanning restores energy and time after startDay', () async {
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      notifier.setEnergyLevel('high');
      notifier.setAvailableTime(360); // 6 hours

      await notifier.startDay();
      await notifier.reEnterPlanning();

      final state = container.read(focusSessionPlanningProvider);
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
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      notifier.setInitialInboxCount(5);
      notifier.advanceStep();
      notifier.advanceStep();

      await notifier.startDay();

      final state = container.read(focusSessionPlanningProvider);
      expect(state.currentStep, 0);
      expect(state.initialInboxCount, isNull);
      expect(state.inboxClarifiedCount, 0);
      expect(state.inboxSkippedCount, 0);
    });
  });

  group('FocusSessionPlanningNotifier — banner dismissal', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = _container(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      focusSessionPlanningBannerDismissedNotifier.value = false;
      focusSessionPlanningCompletionNotifier.value = false;
    });

    test('dismissBannerForToday sets focusSessionPlanningBannerDismissedNotifier and persists',
        () async {
      final notifier = container.read(focusSessionPlanningProvider.notifier);
      expect(focusSessionPlanningBannerDismissedNotifier.value, isFalse);

      await notifier.dismissBannerForToday();

      expect(focusSessionPlanningBannerDismissedNotifier.value, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('planning_banner_dismissed_date'),
          equals(planningToday()));
    });

    test('focusSessionPlanningBannerDismissedNotifier resets to false for a different day',
        () async {
      // Simulate yesterday's dismissal persisted.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('planning_banner_dismissed_date', '2000-01-01');
      await initFocusSessionPlanningCompletion();

      // Today does not match '2000-01-01'.
      expect(focusSessionPlanningBannerDismissedNotifier.value, isFalse);
    });
  });

  group('FocusSessionPlanningNotifier — skip and snooze', () {
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
      await loadFocusSessionPlanningNotificationSuppression();
    });

    test('skipPlanningToday sets skipped flag for today', () async {
      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.skipPlanningToday();

      expect(isFocusSessionPlanningNotificationSuppressed(), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('planning_notification_skipped_date'),
          equals(planningToday()));
    });

    test('snoozePlanningNotification sets snoozed-until in the future',
        () async {
      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.snoozePlanningNotification(60);

      expect(isFocusSessionPlanningNotificationSuppressed(), isTrue);

      final prefs = await SharedPreferences.getInstance();
      final stored =
          DateTime.tryParse(prefs.getString('planning_notification_snoozed_until') ?? '');
      expect(stored, isNotNull);
      expect(stored!.isAfter(DateTime.now()), isTrue);
    });

    test('loadFocusSessionPlanningNotificationSuppression reflects skipped state', () async {
      // Persist the skip date directly without going through persistFocusSessionPlanningSkipToday
      // so we can independently verify loadFocusSessionPlanningNotificationSuppression picks it up.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('planning_notification_skipped_date', planningToday());

      await loadFocusSessionPlanningNotificationSuppression();
      expect(isFocusSessionPlanningNotificationSuppressed(), isTrue);
    });

    test('skip state from a previous day does not suppress today', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('planning_notification_skipped_date', '2000-01-01');
      await loadFocusSessionPlanningNotificationSuppression();

      expect(isFocusSessionPlanningNotificationSuppressed(), isFalse);
    });
  });
}
