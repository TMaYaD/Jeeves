import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/nudge_action_outbox.dart';
import 'package:jeeves/providers/nudge_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/periodic_review_test_helpers.dart';
import '../test_helpers.dart';

/// Skip / Snooze on a Ritual notification and the Nudge are one state.
///
/// Drives the notification action the way the handler does — resolve the
/// action ID from a real [NotificationResponse], record it in the outbox —
/// then drains it into a real database and reads the Nudge queue. The OS
/// plugin itself is the only boundary not exercised.
final _drainProvider =
    FutureProvider<int>((ref) => drainNudgeActionOutbox(ref));

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer c;
  late DateTime firstDue;
  late DateTime nextDue;

  Future<void> boot({required DateTime now}) async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
      notificationServiceProvider
          .overrideWithValue(StubPeriodicReviewNotificationService()),
    ]);
    await db.captureDao.insertCapture(CapturesCompanion(
      id: const Value('inbox'),
      title: const Value('Review this capture'),
      userId: const Value('local'),
      createdAt: Value(firstDue),
      updatedAt: Value(firstDue),
    ));
    await c.read(syncedPreferencesProvider.future);
    await c.read(syncedPreferencesProvider.notifier).set(
          'periodic_review_last_completed_at',
          firstDue.subtract(const Duration(days: 7)).toIso8601String(),
        );
  }

  /// The handler's Skip / Snooze path, minus the OS alarm calls.
  Future<void> tapAction(String actionId, {required DateTime at}) async {
    final response = NotificationResponse(
      notificationResponseType:
          NotificationResponseType.selectedNotificationAction,
      actionId: actionId,
      payload: 'nudge:periodic_review',
    );
    final action = ritualNotificationActionFor(response.actionId)!;
    await recordRitualNotificationAction(
      ritual: action.ritual,
      kind: action.kind,
      at: at,
      snoozeMinutes: 60,
    );
  }

  Future<bool> weeklyReviewVisible() async {
    final sub = c.listen(nudgeVisibleProvider(RitualId.weeklyReview), (_, _) {});
    await pumpEventQueue();
    final visible = sub.read();
    sub.close();
    return visible;
  }

  setUp(() {
    final today = DateTime.now();
    firstDue = DateTime(today.year, today.month, today.day - 1, 12);
    nextDue = firstDue.add(const Duration(days: 7));
  });

  tearDown(() async {
    c.dispose();
    await db.close();
  });

  test('Skip on the Weekly Review notification hides its banner', () async {
    await boot(now: DateTime.now());
    expect(await weeklyReviewVisible(), isTrue);

    await tapAction(kPeriodicReviewActionSkip, at: DateTime.now());
    await c.read(_drainProvider.future);
    expect(await weeklyReviewVisible(), isFalse);
  });

  test('Snooze on the Weekly Review notification hides its banner until the '
      'snooze expires', () async {
    await boot(now: DateTime.now());
    await tapAction(kPeriodicReviewActionSnooze, at: DateTime.now());
    await c.read(_drainProvider.future);

    final state = c.read(nudgeStateProvider(RitualId.weeklyReview));
    expect(state.snoozedUntil!.isAfter(DateTime.now()), isTrue);
    expect(await weeklyReviewVisible(), isFalse);
  });

  test('a snooze tapped long ago has already expired when drained', () async {
    await boot(now: DateTime.now());
    await tapAction(kPeriodicReviewActionSnooze,
        at: DateTime.now().subtract(const Duration(hours: 3)));
    await c.read(_drainProvider.future);

    expect(await weeklyReviewVisible(), isTrue);
  });

  test('a Skip tapped before a refire but drained after it does not '
      'suppress the refire', () async {
    // The clock is already past the next cadence edge when the outbox drains.
    await boot(now: nextDue.add(const Duration(hours: 1)));
    await tapAction(kPeriodicReviewActionSkip,
        at: firstDue.add(const Duration(hours: 1)));
    await c.read(_drainProvider.future);

    expect(await weeklyReviewVisible(), isTrue,
        reason: 'dismissed_at is the tap time, which precedes the refire');
  });

  test('a Skip tapped after the refire suppresses it', () async {
    await boot(now: nextDue.add(const Duration(hours: 1)));
    await tapAction(kPeriodicReviewActionSkip,
        at: nextDue.add(const Duration(minutes: 30)));
    await c.read(_drainProvider.future);

    expect(await weeklyReviewVisible(), isFalse);
  });
}
