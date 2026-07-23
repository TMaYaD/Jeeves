import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/periodic_review_settings_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/periodic_review_test_helpers.dart';
import '../test_helpers.dart';

ProviderContainer _container() => createPeriodicReviewTestContainer(
      GtdDatabase(NativeDatabase.memory()),
    );

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('PeriodicReviewSettings derived providers', () {
    test('isDue is true when last completion key is unset', () async {
      final c = _container();
      addTearDown(c.dispose);

      await c.read(syncedPreferencesProvider.future);
      expect(c.read(periodicReviewIsDueProvider), isTrue);
    });

    test('isDue is true when last completion is exactly 7 days ago', () async {
      final c = _container();
      addTearDown(c.dispose);

      await c.read(syncedPreferencesProvider.future);
      final sevenDaysAgo =
          DateTime.now().toUtc().subtract(const Duration(days: 7));
      await c
          .read(syncedPreferencesProvider.notifier)
          .set('periodic_review_last_completed_at',
              sevenDaysAgo.toIso8601String());
      expect(c.read(periodicReviewIsDueProvider), isTrue);
    });

    test('isDue is false when last completion is just under 7 days ago',
        () async {
      final c = _container();
      addTearDown(c.dispose);

      await c.read(syncedPreferencesProvider.future);
      final justUnder =
          DateTime.now().toUtc().subtract(const Duration(days: 6, hours: 23));
      await c
          .read(syncedPreferencesProvider.notifier)
          .set('periodic_review_last_completed_at',
              justUnder.toIso8601String());
      expect(c.read(periodicReviewIsDueProvider), isFalse);
    });

    test('bannerEnabled defaults to true when key is unset', () async {
      final c = _container();
      addTearDown(c.dispose);

      await c.read(syncedPreferencesProvider.future);
      expect(c.read(periodicReviewBannerEnabledProvider), isTrue);
    });

  });

  group('PeriodicReviewSettingsNotifier', () {
    test('completeReview writes the timestamp via synced prefs', () async {
      final c = _container();
      addTearDown(c.dispose);

      await c.read(syncedPreferencesProvider.future);
      await c.read(periodicReviewSettingsProvider.notifier).completeReview();

      final raw = c
          .read(syncedPreferencesProvider)
          .asData!
          .value
          .get<String>('periodic_review_last_completed_at');
      expect(raw, isNotNull);
      final parsed = DateTime.parse(raw!);
      expect(parsed.isUtc, isTrue);
      expect(c.read(periodicReviewIsDueProvider), isFalse);
    });

    // dismissBannerForToday test removed: banner dismiss state now lives
    // in the Nudge module's synced-prefs entry (covered by
    // nudge_provider_test.dart's visibility-predicate tests).

    test('setNotificationTime persists hour and minute', () async {
      final c = _container();
      addTearDown(c.dispose);

      await c.read(syncedPreferencesProvider.future);
      await c
          .read(periodicReviewSettingsProvider.notifier)
          .setNotificationTime(const TimeOfDay(hour: 7, minute: 30));

      // Allow the syncedPreferences listener inside the notifier to run.
      await Future<void>.delayed(Duration.zero);

      final settings = c.read(periodicReviewSettingsProvider);
      expect(settings.notificationTime.hour, equals(7));
      expect(settings.notificationTime.minute, equals(30));
    });

  });
}
