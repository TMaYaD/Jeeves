import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:jeeves/providers/focus_session_planning_settings_provider.dart';
import 'package:jeeves/providers/shutdown_settings_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/ceremony_in_progress_provider.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart'
    show activeSessionProvider;
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/onboarding_provider.dart';
import 'package:jeeves/providers/nudge_provider.dart';
import 'package:jeeves/providers/periodic_review_settings_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/services/nudge_notification_scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

/// The Notification surface is a projection of the Nudge queue: what the OS
/// holds follows which Ritual would head the queue at each fire instant.
///
/// Everything runs through the production scheduler provider over a real
/// database and real synced preferences. Only the OS plugin (a recording
/// stand-in for [NotificationService]) and the clock are substituted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer c;
  late RecordingNotificationService service;
  late DateTime Function() clockFn;

  DateTime at(int dayOffset, int hour, [int minute = 0]) =>
      DateTime(2026, 11, 11 + dayOffset, hour, minute);

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }
  }

  /// Boots the app root's scheduler. [prefs] are synced-preference values
  /// written before the scheduler starts (settings, Weekly Review history).
  Future<void> boot({
    required DateTime now,
    Map<String, Object> prefs = const {},
  }) async {
    // A never-reviewed Weekly Review is due from the start and would outrank
    // everything else, so unless a test sets its history it was just reviewed.
    prefs = {
      'periodic_review_last_completed_at': now.toIso8601String(),
      ...prefs,
    };
    var current = now;
    clockFn = () => current;
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    service = RecordingNotificationService();
    c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => clockFn()),
      notificationServiceProvider.overrideWithValue(service),
      nudgeNotificationDebounceProvider.overrideWithValue(Duration.zero),
    ]);
    await db.captureDao.insertCapture(CapturesCompanion(
      id: const Value('inbox'),
      title: const Value('Plan this'),
      userId: const Value('local'),
      createdAt: Value(now),
      updatedAt: Value(now),
    ));
    await c.read(syncedPreferencesProvider.future);
    for (final entry in prefs.entries) {
      await c.read(syncedPreferencesProvider.notifier).set(entry.key, entry.value);
    }
    // Listened to, as the app root's `ref.watch` does: a provider nobody listens
    // to is paused, and so are the subscriptions it holds.
    c.listen(nudgeNotificationSchedulerProvider, (_, _) {});
    await settle();
    final facts = c.read(nudgeNotificationFactsProvider);
    if (service.scheduleCalls.isEmpty) {
      fail('the scheduler armed nothing after boot; facts: '
          '${facts == null ? 'null (an input is still loading: '
              'session=${c.read(activeSessionProvider)}, '
              'latest=${c.read(latestSessionStartedAtProvider)}, '
              'items=${c.read(hasAnyItemProvider)}, '
              'inbox=${c.read(unfilteredInboxProvider)}, '
              'next=${c.read(unfilteredNextProvider)})' : 'present, plan has '
              '${planNudgeNotifications(facts).length} entries'}');
    }
  }

  void setClock(DateTime now) => clockFn = () => now;

  tearDown(() async {
    c.dispose();
    await db.close();
  });

  Iterable<DateTime> oneOffs(RitualId ritual) =>
      service.alarmsOf(ritual).map((a) => a.fireAt);

  test('a due Weekly Review holds the shared 09:00 instant; completing it '
      're-arms Daily Planning', () async {
    await boot(now: at(0, 7), prefs: {
      'focus_session_planning_settings_time_hour': 9,
      'periodic_review_last_completed_at': at(-9, 7).toIso8601String(),
    });

    expect(oneOffs(RitualId.weeklyReview).first, at(0, 9));
    expect(service.alarmsOf(RitualId.dailyPlanning), isEmpty,
        reason: 'Weekly Review outranks Daily Planning at 09:00 every day');

    await c.read(periodicReviewSettingsProvider.notifier).completeReview();
    await settle();

    expect(oneOffs(RitualId.weeklyReview), isEmpty,
        reason: 'reviewed just now, so not due again for a week');
    expect(oneOffs(RitualId.dailyPlanning).first, at(0, 9),
        reason: 'with the review done, Daily Planning is the head again');
  });

  test('dismissing the banner removes the dismissed firing\'s alarms and '
      'keeps the next firing\'s', () async {
    await boot(now: at(0, 7), prefs: {
      // Due since 9 Nov 07:00; while due, the Nudge refires every day.
      'periodic_review_last_completed_at': at(-9, 7).toIso8601String(),
    });
    expect(oneOffs(RitualId.weeklyReview), hasLength(7));
    final visible = c.listen(nudgeVisibleProvider(RitualId.weeklyReview), (_, _) {});
    await settle();
    expect(visible.read(), isTrue);

    await c.read(nudgeActionsProvider).dismiss(RitualId.weeklyReview, at: at(0, 7));
    await settle();

    expect(visible.read(), isFalse);
    expect(oneOffs(RitualId.weeklyReview),
        [for (var day = 1; day <= 6; day++) at(day, 9)],
        reason: 'today is silenced on both surfaces; tomorrow\'s firing, '
            'which begins at midnight, is not');
    visible.close();
  });

  test('dismissing Daily Planning after a snooze cancels the snooze alarm and '
      'leaves tomorrow\'s', () async {
    await boot(now: at(0, 8, 30));
    final snoozeId = ritualSnoozeNotificationId(RitualId.dailyPlanning);

    await c
        .read(nudgeActionsProvider)
        .snooze(RitualId.dailyPlanning, const Duration(minutes: 30), at: at(0, 8, 30));
    await settle();
    expect(service.pending[snoozeId]?.fireAt.isAtSameMomentAs(at(0, 9)), isTrue,
        reason: 'the snooze expiry is a planned alarm');

    setClock(at(0, 8, 35));
    await c.read(nudgeActionsProvider).dismiss(RitualId.dailyPlanning, at: at(0, 8, 35));
    c.invalidate(nudgeNotificationFactsProvider);
    await settle();

    expect(service.pending.containsKey(snoozeId), isFalse);
    expect(oneOffs(RitualId.dailyPlanning).first, at(1, 8));
  });

  test('a content-state refire after a dismiss brings the Weekly Review '
      'notification back the same day', () async {
    await boot(now: at(0, 9), prefs: {
      'periodic_review_last_completed_at': at(-1, 9).toIso8601String(),
      'periodic_review_notification_hour': 11,
    });
    await db.into(db.todos).insert(TodosCompanion(
          id: const Value('maybe'),
          title: const Value('Someday thing'),
          userId: const Value('local'),
          createdAt: Value(at(0, 9).toUtc()),
          updatedAt: Value(at(0, 9).toUtc()),
        ));
    await db.todoDao.deferTaskToMaybe('maybe');
    await c.read(nudgeActionsProvider).dismiss(RitualId.weeklyReview, at: at(0, 9));
    await settle();
    expect(oneOffs(RitualId.weeklyReview), isNot(contains(at(0, 11))),
        reason: 'the Inbox holds a capture: nothing is firing today (the '
            'review is not due by cadence until 17 Nov)');

    // The Inbox empties: the content-state predicate goes false -> true.
    setClock(at(0, 10));
    await (db.update(db.captures)..where((t) => t.id.equals('inbox')))
        .write(CapturesCompanion(clarifiedAt: Value(at(0, 10).toUtc())));
    c.invalidate(nudgeNotificationFactsProvider);
    await settle();

    expect(oneOffs(RitualId.weeklyReview).first, at(0, 11),
        reason: 'a firing newer than the dismiss is notified today');
  });

  test('a Daily Planning wizard in progress withholds the current firing '
      'but not tomorrow\'s', () async {
    await boot(now: at(0, 8, 10));
    await c
        .read(nudgeActionsProvider)
        .snooze(RitualId.dailyPlanning, const Duration(minutes: 30), at: at(0, 8, 10));
    await settle();
    final snoozeId = ritualSnoozeNotificationId(RitualId.dailyPlanning);
    expect(service.pending.containsKey(snoozeId), isTrue);

    c.read(ceremonyInProgressProvider.notifier).enter(RitualId.dailyPlanning);
    await settle();

    expect(service.pending.containsKey(snoozeId), isFalse,
        reason: 'the 08:00 firing is the one being performed');
    expect(oneOffs(RitualId.dailyPlanning).first, at(1, 8));

    c.read(ceremonyInProgressProvider.notifier).exit(RitualId.dailyPlanning);
    await settle();
    expect(service.pending.containsKey(snoozeId), isTrue,
        reason: 'leaving the wizard without finishing does not hide the firing');
  });

  group('configured reminder times', () {
    Future<void> openSession(DateTime now) async {
      await db.into(db.todos).insert(TodosCompanion(
            id: const Value('planned'),
            title: const Value('Planned thing'),
            userId: const Value('local'),
            createdAt: Value(now.toUtc()),
            updatedAt: Value(now.toUtc()),
          ));
      await db.focusSessionDao
          .openSession(userId: 'local', taskIds: ['planned'], now: now);
    }

    test('Daily Planning arms at its configured time, follows a change and '
        'goes quiet when switched off', () async {
      await boot(now: at(0, 7), prefs: {
        'focus_session_planning_settings_time_hour': 8,
        'focus_session_planning_settings_time_minute': 15,
      });
      expect(oneOffs(RitualId.dailyPlanning).first, at(0, 8, 15));

      await c
          .read(focusSessionPlanningSettingsProvider.notifier)
          .setPlanningTime(const TimeOfDay(hour: 8, minute: 45));
      await settle();
      expect(oneOffs(RitualId.dailyPlanning).first, at(0, 8, 45));
      expect(oneOffs(RitualId.dailyPlanning), isNot(contains(at(0, 8, 15))),
          reason: 'the alarm at the old time is gone');

      await c
          .read(focusSessionPlanningSettingsProvider.notifier)
          .setNotificationEnabled(false);
      await settle();
      expect(oneOffs(RitualId.dailyPlanning), isEmpty);
    });

    test('Evening Shutdown arms at its configured time with a session open, '
        'follows a change and goes quiet when switched off', () async {
      // Shutdown settings live in SharedPreferences, not synced preferences,
      // so the non-default time goes in through the production notifier.
      await boot(now: at(0, 7));
      await openSession(at(0, 7));
      await c
          .read(shutdownSettingsProvider.notifier)
          .setShutdownTime(const TimeOfDay(hour: 19, minute: 40));
      c.invalidate(nudgeNotificationFactsProvider);
      await settle();
      expect(oneOffs(RitualId.eveningShutdown).first, at(0, 19, 40));

      await c
          .read(shutdownSettingsProvider.notifier)
          .setShutdownTime(const TimeOfDay(hour: 21, minute: 5));
      await settle();
      expect(oneOffs(RitualId.eveningShutdown).first, at(0, 21, 5));
      expect(oneOffs(RitualId.eveningShutdown), isNot(contains(at(0, 19, 40))));

      await c
          .read(shutdownSettingsProvider.notifier)
          .setNotificationEnabled(false);
      await settle();
      expect(oneOffs(RitualId.eveningShutdown), isEmpty);
    });

    test('Weekly Review arms at its configured time while due, follows a '
        'change and goes quiet when switched off', () async {
      await boot(now: at(0, 7), prefs: {
        'periodic_review_last_completed_at': at(-9, 7).toIso8601String(),
        'periodic_review_notification_hour': 10,
        'periodic_review_notification_minute': 25,
      });
      expect(oneOffs(RitualId.weeklyReview).first, at(0, 10, 25));

      await c
          .read(periodicReviewSettingsProvider.notifier)
          .setNotificationTime(const TimeOfDay(hour: 11, minute: 50));
      await settle();
      expect(oneOffs(RitualId.weeklyReview).first, at(0, 11, 50));
      expect(oneOffs(RitualId.weeklyReview), isNot(contains(at(0, 10, 25))));

      await c
          .read(periodicReviewSettingsProvider.notifier)
          .setNotificationEnabled(false);
      await settle();
      expect(oneOffs(RitualId.weeklyReview), isEmpty);
    });
  });

  group('exact alarm timing', () {
    test('alarms armed inexact are replaced once exact alarms are permitted, '
        'and left alone afterwards', () async {
      await boot(now: at(0, 7), prefs: {
        'periodic_review_last_completed_at': at(-9, 7).toIso8601String(),
      });
      expect(service.pending.values, isNotEmpty);
      expect(service.pending.values.every((a) => !a.exact), isTrue,
          reason: 'exact alarms were not permitted when they were armed');

      service.exactAlarmsAllowed = true;
      service.scheduleCalls.clear();
      c.invalidate(nudgeNotificationFactsProvider);
      await settle();
      expect(service.pending.values.every((a) => a.exact), isTrue,
          reason: 'the same instants are re-armed under the new permission');
      expect(service.scheduleCalls, isNotEmpty);

      service.scheduleCalls.clear();
      c.invalidate(nudgeNotificationFactsProvider);
      await settle();
      expect(service.scheduleCalls, isEmpty,
          reason: 'already exact: an unchanged plan causes no churn');
    });
  });
}
