import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart'
    show unfilteredInboxProvider;
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/providers/system_health_provider.dart';

import '../test_helpers.dart';

const _lastCompletedKey = 'periodic_review_last_completed_at';
final _lastCompleted = DateTime.utc(2026, 3, 1, 9);
final _due = _lastCompleted.add(const Duration(days: 7));

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

  Future<void> start({DateTime? lastCompleted}) async {
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
      nudgeBoundaryTickProvider.overrideWith((ref) => now.millisecondsSinceEpoch),
    ]);
    await container.read(syncedPreferencesProvider.future);
    if (lastCompleted != null) {
      await container
          .read(syncedPreferencesProvider.notifier)
          .set(_lastCompletedKey, lastCompleted.toIso8601String());
    }
    // Keep the streams live, as the Nudge triggers do in the app.
    container.listen(unfilteredInboxProvider, (_, __) {});
    container.listen(neverReviewedBaselineProvider, (_, __) {});
    await container.read(unfilteredInboxProvider.future);
    await container.read(neverReviewedBaselineProvider.future);
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

  setUp(() {
    db = GtdDatabase(NativeDatabase.memory());
    now = _due;
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  group('review arm', () {
    test('not overdue before due: level none, no causes', () async {
      now = _due.subtract(const Duration(minutes: 1));
      await start(lastCompleted: _lastCompleted);
      expect(container.read(weeklyReviewOverdueDurationProvider), Duration.zero);
      expect(container.read(guardrailLevelProvider), GuardrailLevel.none);
      expect(container.read(guardrailCausesProvider), isEmpty);
    });

    test('just over due: level1, reviewOverdue', () async {
      now = _due.add(const Duration(minutes: 1));
      await start(lastCompleted: _lastCompleted);
      expect(container.read(weeklyReviewOverdueDurationProvider),
          const Duration(minutes: 1));
      expect(container.read(guardrailLevelProvider), GuardrailLevel.level1);
      expect(container.read(guardrailCausesProvider),
          {GuardrailCause.reviewOverdue});
    });

    test('exactly 48h overdue is still level1; just over is level2', () async {
      now = _due.add(const Duration(hours: kGuardrailReviewOverdueGraceHours));
      await start(lastCompleted: _lastCompleted);
      expect(container.read(guardrailLevelProvider), GuardrailLevel.level1);

      now = now.add(const Duration(minutes: 1));
      container.invalidate(weeklyReviewOverdueDurationProvider);
      expect(container.read(guardrailLevelProvider), GuardrailLevel.level2);
      expect(container.read(guardrailCausesProvider),
          {GuardrailCause.reviewOverdue});
    });

    test('completing a review drops the level at once', () async {
      now = _due.add(const Duration(hours: 60));
      await start(lastCompleted: _lastCompleted);
      expect(container.read(guardrailLevelProvider), GuardrailLevel.level2);

      await container
          .read(syncedPreferencesProvider.notifier)
          .set(_lastCompletedKey, now.toIso8601String());
      expect(container.read(guardrailLevelProvider), GuardrailLevel.none);
    });

    test('an open, partly done review period does not lift the level',
        () async {
      now = _due.add(const Duration(hours: 60));
      await start(lastCompleted: _lastCompleted);
      await container
          .read(syncedPreferencesProvider.notifier)
          .set('periodic_review_open_since', now.toIso8601String());
      expect(container.read(guardrailLevelProvider), GuardrailLevel.level2);
    });
  });

  group('inbox arm', () {
    test('50 Captures is not over the limit; 51 is level2 inboxOverLimit',
        () async {
      now = _due.subtract(const Duration(days: 1));
      await _addCaptures(db, kGuardrailInboxCaptureLimit, _lastCompleted);
      await start(lastCompleted: _lastCompleted);
      expect(container.read(unprocessedCaptureCountProvider), 50);
      expect(container.read(guardrailLevelProvider), GuardrailLevel.none);

      await _addCapture(db, 'extra', _lastCompleted);
      await settle();
      expect(container.read(unprocessedCaptureCountProvider), 51);
      expect(container.read(guardrailLevelProvider), GuardrailLevel.level2);
      expect(container.read(guardrailCausesProvider),
          {GuardrailCause.inboxOverLimit});
    });

    test('clarifying a Capture drops the count and the level', () async {
      now = _due.subtract(const Duration(days: 1));
      await _addCaptures(db, 51, _lastCompleted);
      await start(lastCompleted: _lastCompleted);
      expect(container.read(guardrailLevelProvider), GuardrailLevel.level2);

      await (db.update(db.captures)..where((c) => c.id.equals('c0')))
          .write(CapturesCompanion(clarifiedAt: Value(now.toUtc())));
      db.notifyCapturesViewWrite();
      await settle();
      expect(container.read(unprocessedCaptureCountProvider), 50);
      expect(container.read(guardrailLevelProvider), GuardrailLevel.none);
    });

    test('both arms report both causes', () async {
      now = _due.add(const Duration(hours: 60));
      await _addCaptures(db, 51, _lastCompleted);
      await start(lastCompleted: _lastCompleted);
      expect(container.read(guardrailCausesProvider),
          {GuardrailCause.reviewOverdue, GuardrailCause.inboxOverLimit});
    });
  });

  group('never-completed baseline', () {
    test('no items and no completion: not overdue', () async {
      await start();
      expect(container.read(weeklyReviewOverdueDurationProvider), Duration.zero);
      expect(container.read(guardrailLevelProvider), GuardrailLevel.none);
    });

    test('measures from the earliest Capture or Outcome created_at', () async {
      final earliestOutcome = DateTime.utc(2026, 3, 1, 9);
      await db.into(db.todos).insert(TodosCompanion(
            id: const Value('o1'),
            title: const Value('Outcome'),
            userId: const Value('u'),
            createdAt: Value(earliestOutcome),
          ));
      await _addCapture(db, 'late', earliestOutcome.add(const Duration(days: 3)));

      now = _due.add(const Duration(hours: 1));
      await start();
      expect(container.read(weeklyReviewOverdueDurationProvider),
          const Duration(hours: 1));
      expect(container.read(guardrailLevelProvider), GuardrailLevel.level1);

      now = _due.add(const Duration(hours: 49));
      container.invalidate(weeklyReviewOverdueDurationProvider);
      expect(container.read(guardrailLevelProvider), GuardrailLevel.level2);
    });

    test('a new user within a week of first use is not overdue', () async {
      await _addCapture(db, 'first', _lastCompleted);
      now = _lastCompleted.add(const Duration(days: 3));
      await start();
      expect(container.read(guardrailLevelProvider), GuardrailLevel.none);
    });
  });

  group('boundary tick', () {
    test('nextNudgeBoundary includes last completion + 7d + 48h', () {
      final afterDue = _due.add(const Duration(minutes: 1));
      final next = nextNudgeBoundary(afterDue,
          shutdownHour: 23,
          shutdownMinute: 59,
          weeklyReviewLastCompleted: _lastCompleted);
      // The Level 2 instant is the earliest boundary unless midnight or the
      // shutdown anchor comes first; pick a time-of-day that makes it win.
      final level2 =
          _due.add(const Duration(hours: kGuardrailReviewOverdueGraceHours));
      expect(next.isAfter(afterDue), isTrue);
      expect(next.isAfter(level2), isFalse);

      final justBefore = level2.subtract(const Duration(seconds: 1));
      expect(
          nextNudgeBoundary(justBefore,
              shutdownHour: 23,
              shutdownMinute: 59,
              weeklyReviewLastCompleted: _lastCompleted),
          level2);
    });
  });
}
