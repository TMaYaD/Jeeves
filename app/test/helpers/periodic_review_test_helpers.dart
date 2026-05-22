/// Shared test scaffolding for the Weekly Review wizard tests.
///
/// Both the unit-level provider test and the integration test build
/// a [ProviderContainer] with the same overrides — keep that wiring
/// here so adding a new override (e.g. a new method on
/// [NotificationService]) only needs touching one file.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/services/notification_service.dart';

/// No-op [NotificationService] for tests — flutter_local_notifications
/// uses platform channels that are unavailable in the unit-test
/// environment, so every method the wizard touches is overridden to
/// silently return.
class StubPeriodicReviewNotificationService extends NotificationService {
  StubPeriodicReviewNotificationService() : super.forTesting();

  @override
  Future<void> scheduleRitualReminder(
      RitualId ritual, TimeOfDay time) async {}

  @override
  Future<void> snoozeRitualReminder(RitualId ritual, int minutes) async {}

  @override
  Future<void> cancelRitualReminder(RitualId ritual) async {}

  @override
  Future<void> cancelRecurringRitualReminder(RitualId ritual) async {}

  @override
  Future<void> skipTodayRitualReminder(RitualId ritual) async {}
}

/// Standard [ProviderContainer] for periodic-review tests: real Drift
/// database + stub notification service. If a test needs additional
/// overrides on top of these, build the container locally instead.
ProviderContainer createPeriodicReviewTestContainer(GtdDatabase db) =>
    ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider
            .overrideWithValue(StubPeriodicReviewNotificationService()),
      ],
    );
