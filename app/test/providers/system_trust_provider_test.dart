import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart'
    show unfilteredInboxProvider;
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/providers/periodic_review_provider.dart';
import 'package:jeeves/providers/periodic_review_settings_provider.dart'
    show periodicReviewLastCompletedProvider;
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/providers/system_trust_provider.dart';
import 'package:jeeves/services/notification_service.dart'
    show notificationServiceProvider;

import '../helpers/periodic_review_test_helpers.dart';
import '../test_helpers.dart';

const _lastCompletedKey = 'periodic_review_last_completed_at';
const _sessionFinishedKey = 'periodic_review_last_session_finished_at';
final _lastReviewed = DateTime.utc(2026, 3, 1, 9);
final _due = _lastReviewed.add(const Duration(days: 7));
final _doneAt = DateTime.utc(2026, 3, 4, 15, 30);

Future<void> _addCapture(GtdDatabase db, String id, DateTime createdAt) =>
    db.captureDao.insertCapture(CapturesCompanion(
      id: Value(id),
      title: Value('Capture $id'),
      userId: const Value('u'),
      createdAt: Value(createdAt),
    ));

Future<void> _addCaptures(GtdDatabase db, int count, DateTime createdAt) async {
  for (var i = 0; i < count; i++) {
    await _addCapture(db, 'c$i', createdAt);
  }
}

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late GtdDatabase db;
  late DateTime now;
  late ProviderContainer container;

  Future<void> start({String? completedKey, DateTime? lastReviewed}) async {
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
      nudgeBoundaryTickProvider
          .overrideWith((ref) => now.millisecondsSinceEpoch),
    ]);
    await container.read(syncedPreferencesProvider.future);
    if (lastReviewed != null) {
      await container
          .read(syncedPreferencesProvider.notifier)
          .set(completedKey ?? _lastCompletedKey, lastReviewed.toIso8601String());
    }
    // Keep the streams live, as the Nudge triggers do in the app.
    container.listen(unfilteredInboxProvider, (_, _) {});
    container.listen(neverReviewedBaselineProvider, (_, _) {});
    await container.read(unfilteredInboxProvider.future);
    await container.read(neverReviewedBaselineProvider.future);
  }

  /// Awaits the next Inbox emission after a write, rather than sleeping.
  Future<void> nextInboxEmission() {
    final next = Completer<void>();
    final sub = container.listen(unfilteredInboxProvider, (_, _) {
      if (!next.isCompleted) next.complete();
    });
    return next.future.whenComplete(sub.close);
  }

  setUp(() {
    db = GtdDatabase(NativeDatabase.memory());
    now = _due;
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  group('inbox signal', () {
    test('50 Captures is not too full; 51 is', () async {
      await _addCaptures(db, kInboxTooFullCaptureLimit, _lastReviewed);
      await start(lastReviewed: _lastReviewed);
      expect(container.read(unprocessedCaptureCountProvider), 50);
      expect(container.read(inboxTooFullProvider), isFalse);

      final emitted = nextInboxEmission();
      await _addCapture(db, 'extra', _lastReviewed);
      await emitted;
      expect(container.read(unprocessedCaptureCountProvider), 51);
      expect(container.read(inboxTooFullProvider), isTrue);
    });

    test('clarifying the 51st Capture clears it', () async {
      await _addCaptures(db, 51, _lastReviewed);
      await start(lastReviewed: _lastReviewed);
      expect(container.read(inboxTooFullProvider), isTrue);

      final emitted = nextInboxEmission();
      await (db.update(db.captures)..where((c) => c.id.equals('c0')))
          .write(CapturesCompanion(clarifiedAt: Value(now.toUtc())));
      db.notifyCapturesViewWrite();
      await emitted;
      expect(container.read(inboxTooFullProvider), isFalse);
    });
  });

  group('weekly review due date', () {
    test('a reviewed user is due at exactly last review + 7 days', () async {
      await start(lastReviewed: _lastReviewed);
      expect(container.read(weeklyReviewDueAtProvider), _due);
    });

    test('a never-reviewed user is due at earliest Capture or Outcome + 7d',
        () async {
      final earliestOutcome = DateTime.utc(2026, 3, 1, 9);
      await db.into(db.todos).insert(TodosCompanion(
            id: const Value('o1'),
            title: const Value('Outcome'),
            userId: const Value('u'),
            createdAt: Value(earliestOutcome),
          ));
      await _addCapture(db, 'late', earliestOutcome.add(const Duration(days: 3)));
      await start();
      expect(container.read(weeklyReviewLastReviewedAtProvider), isNull);
      expect(container.read(weeklyReviewDueAtProvider), _due);
    });

    test('no items and no review: nothing is due', () async {
      await start();
      expect(container.read(weeklyReviewDueAtProvider), isNull);
      expect(container.read(weeklyReviewDaysLateProvider), isNull);
      expect(container.read(systemTrustProvider).allGood, isTrue);
    });

    test('the later of completion and session-finished is the last review',
        () async {
      await start(lastReviewed: _lastReviewed);
      final later = _lastReviewed.add(const Duration(days: 2));
      await container
          .read(syncedPreferencesProvider.notifier)
          .set(_sessionFinishedKey, later.toIso8601String());
      expect(container.read(weeklyReviewLastReviewedAtProvider), later);
      expect(container.read(weeklyReviewDueAtProvider),
          later.add(const Duration(days: 7)));

      // An older session stamp never pulls the date back.
      await container
          .read(syncedPreferencesProvider.notifier)
          .set(_sessionFinishedKey,
              _lastReviewed.subtract(const Duration(days: 1)).toIso8601String());
      expect(container.read(weeklyReviewLastReviewedAtProvider), _lastReviewed);
    });
  });

  group('Done stamps the session-finished key', () {
    Future<ProviderContainer> reviewContainer() async {
      final c = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider
            .overrideWithValue(StubPeriodicReviewNotificationService()),
        clockProvider.overrideWithValue(() => _doneAt),
      ]);
      await c.read(syncedPreferencesProvider.future);
      return c;
    }

    void expectDueExactlyAWeekAfterDone(ProviderContainer c) {
      expect(c.read(weeklyReviewDueAtProvider),
          _doneAt.add(const Duration(days: 7)));
    }

    test('a partial Done stamps it, leaves completion alone, moves the due date',
        () async {
      await _addCapture(db, 'a', DateTime.utc(2026, 1, 1));
      container = await reviewContainer();
      container.listen(neverReviewedBaselineProvider, (_, _) {});
      await container.read(neverReviewedBaselineProvider.future);

      await container.read(periodicReviewProvider.notifier).completeSession();
      await Future<void>.delayed(Duration.zero);

      final prefs = container.read(syncedPreferencesProvider).requireValue;
      expect(prefs.get<String>(_sessionFinishedKey),
          _doneAt.toIso8601String());
      expect(prefs.get<String>(_lastCompletedKey), isNull);
      expectDueExactlyAWeekAfterDone(container);
    });

    test('a final Done stamps both keys and moves the due date', () async {
      await _addCapture(db, 'a', DateTime.utc(2026, 1, 1));
      container = await reviewContainer();
      container.listen(neverReviewedBaselineProvider, (_, _) {});
      await container.read(neverReviewedBaselineProvider.future);

      await container.read(periodicReviewProvider.notifier).completeReview();
      await Future<void>.delayed(Duration.zero);

      final prefs = container.read(syncedPreferencesProvider).requireValue;
      expect(prefs.get<String>(_sessionFinishedKey),
          _doneAt.toIso8601String());
      expect(prefs.get<String>(_lastCompletedKey), _doneAt.toIso8601String());
      expectDueExactlyAWeekAfterDone(container);
    });
  });

  group('days late', () {
    test('null before the due instant, 0 at it', () async {
      now = _due.subtract(const Duration(minutes: 1));
      await start(lastReviewed: _lastReviewed);
      expect(container.read(weeklyReviewDaysLateProvider), isNull);
      expect(container.read(systemTrustProvider).allGood, isTrue);

      now = _due;
      container.invalidate(weeklyReviewDaysLateProvider);
      expect(container.read(weeklyReviewDaysLateProvider), 0);
      expect(container.read(systemTrustProvider).needsAttention, isTrue);
    });

    test('counts local calendar days, not 24-hour spans', () async {
      await start(lastReviewed: _lastReviewed);
      final dueLocal = _due.toLocal();
      // Just before local midnight on the due day, then just after it.
      now = DateTime(dueLocal.year, dueLocal.month, dueLocal.day, 23, 59);
      container.invalidate(weeklyReviewDaysLateProvider);
      expect(container.read(weeklyReviewDaysLateProvider), 0);
      now = DateTime(dueLocal.year, dueLocal.month, dueLocal.day + 1, 0, 1);
      container.invalidate(weeklyReviewDaysLateProvider);
      expect(container.read(weeklyReviewDaysLateProvider), 1);
    });

    test('a spring-forward interval counts calendar days, not 24-hour spans',
        () async {
      // 2026-03-08 is the US spring-forward day. Due 2026-03-07 12:00 local,
      // now 2026-03-09 11:00 local: 47 elapsed hours (one is skipped), but
      // two calendar days late. Only meaningful in a DST zone, so CI runs
      // this file under TZ=America/Los_Angeles as well.
      final dueLocal = DateTime(2026, 3, 7, 12);
      final nowLocal = DateTime(2026, 3, 9, 11);
      expect(dueLocal.timeZoneOffset, isNot(nowLocal.timeZoneOffset),
          reason: 'needs a zone with DST; run with TZ=America/Los_Angeles');
      expect(nowLocal.difference(dueLocal).inHours, 46);
      await start(
          lastReviewed: dueLocal.subtract(const Duration(days: 7)).toUtc());
      now = nowLocal;
      container.invalidate(weeklyReviewDaysLateProvider);
      expect(container.read(weeklyReviewDaysLateProvider), 2);
    }, skip: DateTime(2026, 3, 7, 12).timeZoneOffset ==
            DateTime(2026, 3, 9, 11).timeZoneOffset
        ? 'runs under TZ=America/Los_Angeles in CI'
        : false);

    test('is exact across a month-end and a long gap', () async {
      await start(lastReviewed: _lastReviewed);
      final dueLocal = _due.toLocal();
      // 30 calendar days later spans any DST change in a local zone that has
      // one in March; the whole-day count must still be exactly 30.
      now = DateTime(dueLocal.year, dueLocal.month, dueLocal.day + 30, 12);
      container.invalidate(weeklyReviewDaysLateProvider);
      expect(container.read(weeklyReviewDaysLateProvider), 30);
    });
  });

  group('boundary tick', () {
    test('nextNudgeBoundary returns the due instant when it is earliest', () {
      final justBefore = _due.subtract(const Duration(seconds: 1));
      expect(
        nextNudgeBoundary(justBefore,
            shutdownHour: 23, shutdownMinute: 59, weeklyReviewDueAt: _due),
        _due,
      );
    });

    test('a partial-session due date keeps the completion-based refire', () {
      // Completed day 0 (Mar 1) 10:00; a partial Done on day 8 12:00 moves
      // the due instant to day 15 12:00. The shipped nudge still refires at
      // day 14 10:00, so the tick must not skip it.
      final completed = DateTime.utc(2026, 3, 1, 10);
      final partialDone = DateTime.utc(2026, 3, 9, 12);
      final now = DateTime.utc(2026, 3, 15, 9);
      expect(
        nextNudgeBoundary(now,
            shutdownHour: 23,
            shutdownMinute: 59,
            weeklyReviewDueAt: partialDone.add(const Duration(days: 7)),
            weeklyReviewLastCompleted: completed),
        DateTime.utc(2026, 3, 15, 10),
        reason: 'completion + 14d is the earlier boundary',
      );
    });

    test('the tick fires at the due instant', () {
      fakeAsync((async) {
        var clock = _due.subtract(const Duration(minutes: 5));
        final c = ProviderContainer(overrides: [
          clockProvider.overrideWithValue(() => clock),
          weeklyReviewDueAtProvider.overrideWithValue(_due),
          periodicReviewLastCompletedProvider.overrideWithValue(null),
        ]);
        addTearDown(c.dispose);

        final first = c.read(nudgeBoundaryTickProvider);
        expect(first, _due.millisecondsSinceEpoch ~/ 1000);

        clock = _due;
        async.elapse(const Duration(minutes: 5));
        final second = c.read(nudgeBoundaryTickProvider);
        expect(second, isNot(first));
      });
    });
  });
}
