import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/nudge_action_outbox.dart';
import 'package:jeeves/providers/nudge_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/services/ritual_notification_response_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/periodic_review_test_helpers.dart';
import '../test_helpers.dart';

/// Skip / Snooze on a Ritual notification and the Nudge are one state.
///
/// Every journey sends a real [NotificationResponse] through the production
/// handler ([handleRitualNotificationResponse], the function `main.dart`
/// registers with the plugin) and lets the production drainer provider apply
/// the outbox to a real database. Only the OS plugin (a recording stand-in for
/// [NotificationService]) and the router are substituted.

class _RecordingNotificationService extends StubPeriodicReviewNotificationService {
  final snoozed = <(RitualId, int)>[];
  final skipped = <RitualId>[];

  @override
  Future<void> snoozeRitualReminder(RitualId ritual, int minutes) async =>
      snoozed.add((ritual, minutes));

  @override
  Future<void> skipTodayRitualReminder(RitualId ritual) async =>
      skipped.add(ritual);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer c;
  late _RecordingNotificationService service;
  late DateTime Function() clockFn;
  late DateTime firstDue;
  late DateTime nextDue;

  /// Builds the container. [startWeeklyReviewLast] is when Weekly Review was
  /// last completed (null leaves the cadence Trigger idle).
  Future<void> boot({
    required DateTime Function() clock,
    DateTime? weeklyReviewLastCompleted,
    required DateTime itemCreatedAt,
    bool startDrainer = true,
  }) async {
    clockFn = clock;
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    service = _RecordingNotificationService();
    c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => clockFn()),
      notificationServiceProvider.overrideWithValue(service),
    ]);
    await db.captureDao.insertCapture(CapturesCompanion(
      id: const Value('inbox'),
      title: const Value('Review this capture'),
      userId: const Value('local'),
      createdAt: Value(itemCreatedAt),
      updatedAt: Value(itemCreatedAt),
    ));
    await c.read(syncedPreferencesProvider.future);
    if (weeklyReviewLastCompleted != null) {
      await c.read(syncedPreferencesProvider.notifier).set(
            'periodic_review_last_completed_at',
            weeklyReviewLastCompleted.toIso8601String(),
          );
    }
    if (startDrainer) c.read(nudgeActionOutboxDrainerProvider);
  }

  /// A tap on a notification action button, through the production handler.
  Future<void> tap(RitualId ritual, String actionId) =>
      handleRitualNotificationResponse(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: actionId,
          payload: 'nudge:${ritual.keyPrefix}',
        ),
        service: service,
        navigate: (_) {},
        now: () => clockFn(),
      );

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }
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

  test('Daily Planning Skip hides the banner until the next planning anchor', () async {
    var now = DateTime(2026, 11, 11, 9); // after the 08:00 planning anchor
    await boot(clock: () => now, itemCreatedAt: now);
    final sub = c.listen(nudgeVisibleProvider(RitualId.dailyPlanning), (_, _) {});
    await settle();
    expect(sub.read(), isTrue, reason: 'planning is due and nothing is planned');

    await tap(RitualId.dailyPlanning, kNotificationActionSkip);
    await settle();
    expect(service.skipped, [RitualId.dailyPlanning]);
    expect(sub.read(), isFalse, reason: 'Skip must reach the Nudge');

    // From the evening Shutdown time the banner stays hidden overnight.
    now = DateTime(2026, 11, 11, 18, 5);
    c.invalidate(nudgeBoundaryTickProvider);
    await settle();
    expect(sub.read(), isFalse,
        reason: 'Daily Planning is idle from Shutdown time to the next anchor');

    // The next morning's planning anchor is a new firing.
    now = DateTime(2026, 11, 12, 8, 5);
    c.invalidate(nudgeBoundaryTickProvider);
    await settle();
    expect(sub.read(), isTrue,
        reason: 'a firing after the tap time releases the dismissal');
    sub.close();
  });

  testWidgets('Weekly Review Snooze hides the banner, and it returns when the '
      'snooze runs out while the app stays open', (tester) async {
    final realStart = tester.binding.clock.now();
    final base = DateTime.now();
    await tester.runAsync(() => boot(
          clock: () => base.add(tester.binding.clock.now().difference(realStart)),
          weeklyReviewLastCompleted: firstDue.subtract(const Duration(days: 7)),
          itemCreatedAt: firstDue,
        ));
    try {
      final sub =
          c.listen(nudgeVisibleProvider(RitualId.weeklyReview), (_, _) {});
      await tester.runAsync(settle);
      await tester.pump();
      expect(sub.read(), isTrue);

      await tester.runAsync(() => tap(RitualId.weeklyReview, kPeriodicReviewActionSnooze));
      await tester.runAsync(settle);
      await tester.pump();
      expect(service.snoozed, [(RitualId.weeklyReview, 60)]);
      expect(sub.read(), isFalse, reason: 'snoozed by the notification button');

      await tester.pump(const Duration(minutes: 59));
      await tester.runAsync(settle);
      expect(sub.read(), isFalse, reason: 'still inside the snooze');

      await tester.pump(const Duration(minutes: 2));
      await tester.runAsync(settle);
      await tester.pump();
      expect(sub.read(), isTrue, reason: 'only elapsed time ends the snooze');
      sub.close();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        c.dispose();
        await pumpEventQueue();
      });
    }
  });

  test('a Skip tapped before a refire but drained after it does not '
      'suppress the refire', () async {
    var now = firstDue.add(const Duration(hours: 1));
    await boot(
      clock: () => now,
      weeklyReviewLastCompleted: firstDue.subtract(const Duration(days: 7)),
      itemCreatedAt: firstDue,
      startDrainer: false, // the app is not running when the button is tapped
    );
    await tap(RitualId.weeklyReview, kPeriodicReviewActionSkip);

    // The app comes back after the next cadence edge and drains the outbox.
    now = nextDue.add(const Duration(hours: 1));
    c.read(nudgeActionOutboxDrainerProvider);
    final sub = c.listen(nudgeVisibleProvider(RitualId.weeklyReview), (_, _) {});
    await settle();

    expect(c.read(nudgeStateProvider(RitualId.weeklyReview)).dismissedAt,
        isNotNull,
        reason: 'the Skip was applied');
    expect(sub.read(), isTrue,
        reason: 'dismissed_at is the tap time, which precedes the refire');
    sub.close();
  });

  test('a Skip tapped before a content-state refire but drained after it '
      'does not suppress the refire', () async {
    // Cadence stays idle (reviewed yesterday), so only the content-state
    // Trigger can bring the banner back.
    var now = DateTime(2026, 11, 11, 9);
    await boot(
      clock: () => now,
      weeklyReviewLastCompleted: now.subtract(const Duration(days: 1)),
      itemCreatedAt: now,
      startDrainer: false, // the app is not running when the button is tapped
    );
    final nowUtc = now.toUtc();
    await db.into(db.todos).insert(TodosCompanion(
          id: const Value('maybe'),
          title: const Value('Someday thing'),
          userId: const Value('local'),
          createdAt: Value(nowUtc),
          updatedAt: Value(nowUtc),
        ));
    await db.todoDao.deferTaskToMaybe('maybe');

    final sub = c.listen(nudgeVisibleProvider(RitualId.weeklyReview), (_, _) {});
    await settle();
    expect(sub.read(), isFalse,
        reason: 'the Inbox holds a capture, so the content predicate is false');

    // Skip at T. The app is not running, so it only reaches the outbox.
    await tap(RitualId.weeklyReview, kPeriodicReviewActionSkip);

    // T+1h: the Inbox empties, and the predicate goes false -> true.
    now = now.add(const Duration(hours: 1));
    await (db.update(db.captures)
          ..where((t) => t.id.equals('inbox')))
        .write(CapturesCompanion(clarifiedAt: Value(now.toUtc())));
    await settle();
    expect(sub.read(), isTrue, reason: 'the content-state Trigger refired');

    // The app comes back and drains: dismissed_at is T, before the refire.
    c.read(nudgeActionOutboxDrainerProvider);
    await settle();
    final dismissedAt =
        c.read(nudgeStateProvider(RitualId.weeklyReview)).dismissedAt;
    expect(dismissedAt, isNotNull);
    expect(dismissedAt!.isAtSameMomentAs(DateTime(2026, 11, 11, 9)), isTrue,
        reason: 'the Skip is applied with its tap time, not the drain time');
    expect(sub.read(), isTrue,
        reason: 'a Skip older than the refire must not hide it');
    sub.close();
  });

  test('a Skip tapped after the refire suppresses it', () async {
    final now = nextDue.add(const Duration(minutes: 30));
    await boot(
      clock: () => now,
      weeklyReviewLastCompleted: firstDue.subtract(const Duration(days: 7)),
      itemCreatedAt: firstDue,
    );
    final sub = c.listen(nudgeVisibleProvider(RitualId.weeklyReview), (_, _) {});
    await settle();
    expect(sub.read(), isTrue);

    await tap(RitualId.weeklyReview, kPeriodicReviewActionSkip);
    await settle();
    expect(sub.read(), isFalse);
    sub.close();
  });
}
