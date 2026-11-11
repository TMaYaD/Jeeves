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
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/providers/system_trust_provider.dart';

import '../helpers/periodic_review_test_helpers.dart';
import '../test_helpers.dart';

const _lastCompletedKey = 'periodic_review_last_completed_at';
const _sessionFinishedKey = 'periodic_review_last_session_finished_at';
final _lastReviewed = DateTime.utc(2026, 3, 1, 9);
final _due = _lastReviewed.add(const Duration(days: 7));

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

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

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

      await _addCapture(db, 'extra', _lastReviewed);
      await settle();
      expect(container.read(unprocessedCaptureCountProvider), 51);
      expect(container.read(inboxTooFullProvider), isTrue);
    });

    test('clarifying the 51st Capture clears it', () async {
      await _addCaptures(db, 51, _lastReviewed);
      await start(lastReviewed: _lastReviewed);
      expect(container.read(inboxTooFullProvider), isTrue);

      await (db.update(db.captures)..where((c) => c.id.equals('c0')))
          .write(CapturesCompanion(clarifiedAt: Value(now.toUtc())));
      db.notifyCapturesViewWrite();
      await settle();
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
      final c = createPeriodicReviewTestContainer(db);
      await c.read(syncedPreferencesProvider.future);
      return c;
    }

    void expectDueAboutAWeekFromNow(ProviderContainer c) {
      final due = c.read(weeklyReviewDueAtProvider)!;
      final expected = DateTime.now().add(const Duration(days: 7));
      expect(due.difference(expected).abs(), lessThan(const Duration(minutes: 1)));
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
      expect(prefs.get<String>(_sessionFinishedKey), isNotNull);
      expect(prefs.get<String>(_lastCompletedKey), isNull);
      expectDueAboutAWeekFromNow(container);
    });

    test('a final Done stamps both keys and moves the due date', () async {
      await _addCapture(db, 'a', DateTime.utc(2026, 1, 1));
      container = await reviewContainer();
      container.listen(neverReviewedBaselineProvider, (_, _) {});
      await container.read(neverReviewedBaselineProvider.future);

      await container.read(periodicReviewProvider.notifier).completeReview();
      await Future<void>.delayed(Duration.zero);

      final prefs = container.read(syncedPreferencesProvider).requireValue;
      expect(prefs.get<String>(_sessionFinishedKey), isNotNull);
      expect(prefs.get<String>(_lastCompletedKey), isNotNull);
      expectDueAboutAWeekFromNow(container);
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

    test('the tick fires at the due instant', () {
      fakeAsync((async) {
        var clock = _due.subtract(const Duration(minutes: 5));
        final c = ProviderContainer(overrides: [
          clockProvider.overrideWithValue(() => clock),
          weeklyReviewDueAtProvider.overrideWithValue(_due),
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
