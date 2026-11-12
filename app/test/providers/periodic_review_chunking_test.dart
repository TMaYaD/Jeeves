import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/periodic_review_provider.dart';
import 'package:jeeves/providers/periodic_review_ranker.dart';
import 'package:jeeves/providers/periodic_review_settings_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/providers/system_trust_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

class ReverseRanker implements PeriodicReviewRanker {
  @override
  Future<List<PeriodicReviewCandidate>> rank(
    List<PeriodicReviewCandidate> candidates,
  ) async => candidates.reversed.toList();
}

class IncompleteRanker implements PeriodicReviewRanker {
  @override
  Future<List<PeriodicReviewCandidate>> rank(
    List<PeriodicReviewCandidate> candidates,
  ) async => [candidates.last, candidates.last];
}

void main() {
  setUpAll(configureSqliteForTests);
  late GtdDatabase db;
  late ProviderContainer container;
  final now = DateTime.utc(2026, 6, 1, 12);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
    ]);
    await container.read(syncedPreferencesProvider.future);
    for (var index = 0; index < 10; index++) {
      await db.into(db.todos).insert(TodosCompanion(
        id: Value('o$index'),
        title: Value('Outcome $index'),
        userId: const Value('local'),
        intent: const Value('next'),
        clarified: const Value(true),
        createdAt: Value(now.subtract(Duration(days: 20 - index))),
        updatedAt: Value(now),
      ));
    }
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('Everything preserves every snapshot and writes no open timestamp', () async {
    final notifier = container.read(periodicReviewProvider.notifier);
    await notifier.loadAllSnapshots();
    final before = container.read(periodicReviewProvider);
    await notifier.startSession();
    final after = container.read(periodicReviewProvider);
    expect(after.inboxNav, before.inboxNav);
    expect(after.waitingForNav, before.waitingForNav);
    expect(after.nextNav, before.nextNav);
    expect(after.somedayNav, before.somedayNav);
    expect(after.isFinalSession, isTrue);
    expect(container.read(periodicReviewOpenSinceProvider), isNull);
  });

  test('partial selection retains step order and finish does not complete', () async {
    final notifier = container.read(periodicReviewProvider.notifier);
    await notifier.loadAllSnapshots();
    final original = container.read(periodicReviewProvider).nextNav.items!;
    await notifier.startSession(budgetMinutes: 15);
    final selected = container.read(periodicReviewProvider);
    expect(selected.nextNav.items!.map((t) => t.id),
        original.where((t) => int.parse(t.id.substring(1)) < 7).map((t) => t.id));
    expect(selected.nextNav.length, 7);
    expect(selected.isFinalSession, isFalse);
    expect(container.read(periodicReviewOpenSinceProvider), now);
    expect(await notifier.remainingItemCount(), 10);
    await notifier.finishSession();
    expect(container.read(periodicReviewLastCompletedProvider), isNull);
    expect(container.read(periodicReviewProvider).currentStep, 0);
    // Due by the never-reviewed baseline (the oldest Outcome is 20 days old).
    container.listen(neverReviewedBaselineProvider, (_, _) {});
    await container.read(neverReviewedBaselineProvider.future);
    expect(container.read(periodicReviewIsDueProvider), isTrue);
  });

  test('provider override changes membership without changing chunking', () async {
    container.dispose();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
      periodicReviewRankerProvider.overrideWithValue(ReverseRanker()),
    ]);
    await container.read(syncedPreferencesProvider.future);
    final notifier = container.read(periodicReviewProvider.notifier);
    await notifier.loadAllSnapshots();
    final original = container.read(periodicReviewProvider).nextNav.items!;
    await notifier.startSession(budgetMinutes: 15);
    expect(container.read(periodicReviewProvider).nextNav.items,
        original.skip(3).toList());
  });

  test('omitted and duplicate ranker results cannot lose candidates', () async {
    container.dispose();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
      periodicReviewRankerProvider.overrideWithValue(IncompleteRanker()),
    ]);
    await container.read(syncedPreferencesProvider.future);
    final notifier = container.read(periodicReviewProvider.notifier);
    await notifier.loadAllSnapshots();
    final original = container.read(periodicReviewProvider).nextNav.items!;
    await notifier.startSession(budgetMinutes: 15);
    expect(container.read(periodicReviewProvider).nextNav.items!.map((t) => t.id).toSet(),
        {...original.take(6).map((t) => t.id), original.last.id});
  });

  test('open timestamp is bounded by completion and seven-day expiry', () async {
    final prefs = container.read(syncedPreferencesProvider.notifier);
    expect(container.read(periodicReviewOpenSinceProvider), isNull);
    final opened = now.subtract(const Duration(days: 1));
    await prefs.set('periodic_review_open_since', opened.toIso8601String());
    expect(container.read(periodicReviewOpenSinceProvider), opened);
    await prefs.set('periodic_review_last_completed_at', opened.toIso8601String());
    expect(container.read(periodicReviewOpenSinceProvider), isNull);
    await prefs.set('periodic_review_last_completed_at',
        now.subtract(const Duration(days: 10)).toIso8601String());
    await prefs.set('periodic_review_open_since',
        now.subtract(const Duration(days: 7)).toIso8601String());
    expect(container.read(periodicReviewOpenSinceProvider), isNull);
  });

  test('one budget spans all four steps and covered Outcomes are filtered', () async {
    final personId = await db.tagDao.createPersonTag('Alice', 'local');
    await db.todoDao.setPersonTagsForTodo('o0', {personId}, 'local');
    await (db.update(db.todos)..where((t) => t.id.equals('o1')))
        .write(const TodosCompanion(intent: Value('maybe')));
    await db.captureDao.insertCapture(CapturesCompanion(
      id: const Value('capture'),
      title: const Value('Inbox'),
      userId: const Value('local'),
      createdAt: Value(now),
      updatedAt: Value(now),
    ));
    final notifier = container.read(periodicReviewProvider.notifier);
    await notifier.loadAllSnapshots();
    await notifier.startSession(budgetMinutes: 15);
    final state = container.read(periodicReviewProvider);
    expect(state.inboxNav.items, ['capture']);
    expect(state.waitingForNav.items!.map((t) => t.id), ['o0']);
    expect(state.nextNav.items!.map((t) => t.id).toSet(), {'o2','o3','o4','o5','o6'});
    expect(state.somedayNav.items, isEmpty);

    // Clarifications on other surfaces count too, including exact-boundary stamps.
    await (db.update(db.todos)..where((t) => t.id.isIn(['o0', 'o1', 'o2'])))
        .write(TodosCompanion(lastClarifiedAt: Value(now)));
    expect(await notifier.remainingItemCount(), 8);
    await notifier.finishSession();
    await notifier.loadAllSnapshots();
    final resumed = container.read(periodicReviewProvider);
    expect(resumed.inboxNav.items, ['capture']);
    expect(resumed.waitingForNav.items, isEmpty);
    expect(resumed.somedayNav.items, isEmpty);
    expect(resumed.nextNav.items!.map((t) => t.id).toSet(),
        {'o3','o4','o5','o6','o7','o8','o9'});
  });

  test('batch planned lookup excludes current and unrelated Actions', () async {
    await db.actionDao.addPlannedAction('o0', 'First planned');
    await db.actionDao.addPlannedAction('o0', 'Second planned');
    await db.actionDao.addPlannedAction('o1', 'Unrequested planned');
    await db.actionDao.setCurrentAction('o2', 'Current only');
    expect(await db.actionDao.getOutcomeIdsWithPlannedActions({'o0', 'o2', 'o3'}),
        {'o0'});
    expect(await db.actionDao.getOutcomeIdsWithPlannedActions({}), isEmpty);
  });
}
