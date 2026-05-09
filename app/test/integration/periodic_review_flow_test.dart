/// End-to-end integration test for the Weekly Review wizard (#54).
///
/// Drives the wizard through every step via [PeriodicReviewNotifier] /
/// [PeriodicReviewSettingsNotifier], asserts on the durable side-effects
/// (completion timestamp, banner suppression, persisted objectives), and
/// verifies the secondary scenarios listed in the issue plan (banner hidden
/// within cadence; banner hidden after dismissal).
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/periodic_review_provider.dart';
import 'package:jeeves/providers/periodic_review_settings_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

class _StubNotificationService extends NotificationService {
  _StubNotificationService() : super.forTesting();

  @override
  Future<void> schedulePeriodicReviewReminder(
      {required TimeOfDay time}) async {}

  @override
  Future<void> snoozePeriodicReviewReminder(int minutes) async {}

  @override
  Future<void> cancelPeriodicReviewReminder() async {}
}

ProviderContainer _container(GtdDatabase db) => ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider
            .overrideWithValue(_StubNotificationService()),
      ],
    );

Future<void> _insertInbox(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.inboxDao.insertTodo(TodosCompanion(
    id: Value(id),
    title: Value('Inbox item $id'),
    userId: const Value('local'),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
}

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Weekly Review flow', () {
    late GtdDatabase db;
    late ProviderContainer c;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      c = _container(db);
    });

    tearDown(() async {
      c.dispose();
      await db.close();
    });

    test('happy path — banner due, complete wizard, banner dismissed',
        () async {
      await c.read(syncedPreferencesProvider.future);

      // 1. Pre-completion state: due, not dismissed, banner enabled.
      expect(c.read(periodicReviewIsDueProvider), isTrue);
      expect(c.read(periodicReviewBannerDismissedTodayProvider), isFalse);
      expect(c.read(periodicReviewBannerEnabledProvider), isTrue);

      // 2. Walk every step in the wizard.
      await _insertInbox(db, 'i1');
      final notifier = c.read(periodicReviewProvider.notifier);

      await notifier.goToStep(PeriodicReviewNotifier.kStepInbox);
      // Single inbox item: skipping it past the cursor moves the wizard into
      // the "Inbox is clear" terminal state. The next advanceStep crosses
      // out of Inbox; Waiting For, Projects, and Someday/Maybe all auto-skip
      // on entry because no fixtures populate them, so the wizard lands on
      // Objectives in a single hop.
      notifier.advanceInbox();
      await notifier.advanceStep();
      expect(c.read(periodicReviewProvider).currentStep,
          equals(PeriodicReviewNotifier.kStepObjectives));
      notifier.setObjectives(['Ship the wizard']);
      await notifier.advanceStep(); // → Summary

      // 3. Tap "Done" → completeReview.
      await notifier.completeReview();

      // 4. The completion timestamp must be persisted via synced prefs.
      final last = c.read(periodicReviewLastCompletedProvider);
      expect(last, isNotNull);
      expect(c.read(periodicReviewIsDueProvider), isFalse);

      // 5. Objectives are now in synced prefs for next week's pre-population.
      expect(
        c.read(periodicReviewLastObjectivesProvider),
        equals(['Ship the wizard']),
      );

      expect(c.read(periodicReviewProvider).isComplete, isTrue);
    });

    test('banner hidden when completed within 7 days', () async {
      await c.read(syncedPreferencesProvider.future);
      final twoDaysAgo =
          DateTime.now().toUtc().subtract(const Duration(days: 2));
      await c
          .read(syncedPreferencesProvider.notifier)
          .set('periodic_review_last_completed_at', twoDaysAgo.toIso8601String());

      expect(c.read(periodicReviewIsDueProvider), isFalse);
    });

    test('banner hidden after dismissBannerForToday', () async {
      await c.read(syncedPreferencesProvider.future);
      await c
          .read(periodicReviewSettingsProvider.notifier)
          .dismissBannerForToday();

      expect(c.read(periodicReviewBannerDismissedTodayProvider), isTrue);
    });

    test('inbox auto-skip — empty inbox advances past Step 0 on entry',
        () async {
      await c.read(syncedPreferencesProvider.future);
      final notifier = c.read(periodicReviewProvider.notifier);

      await notifier.goToStep(PeriodicReviewNotifier.kStepInbox);
      final state = c.read(periodicReviewProvider);
      expect(state.inboxNav.isLoaded, isTrue);
      expect(state.inboxNav.isEmpty, isTrue);
      // Auto-skip fires synchronously inside _onStepEnter once the snapshot
      // load resolves, so currentStep must have advanced past Step 0.
      expect(state.currentStep, isNot(PeriodicReviewNotifier.kStepInbox));
    });
  });
}
