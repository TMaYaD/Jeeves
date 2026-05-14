/// End-to-end integration test for the Weekly Review wizard (#54).
///
/// Drives the wizard through every step via [PeriodicReviewNotifier] /
/// [PeriodicReviewSettingsNotifier], asserts on the durable side-effects
/// (completion timestamp, banner suppression), and verifies the secondary
/// scenarios listed in the issue plan (banner hidden within cadence; banner
/// hidden after dismissal).
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/periodic_review_provider.dart';
import 'package:jeeves/providers/periodic_review_settings_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/periodic_review_test_helpers.dart';
import '../test_helpers.dart';

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
      c = createPeriodicReviewTestContainer(db);
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
      // out of Inbox; Waiting For, Next Actions, and Someday/Maybe all
      // auto-skip on entry because no fixtures populate them, so the wizard
      // lands on the Summary in a single hop.
      notifier.advanceInbox();
      await notifier.advanceStep();
      expect(c.read(periodicReviewProvider).currentStep,
          equals(PeriodicReviewNotifier.kStepSummary));

      // 3. Tap "Done" → completeReview.
      await notifier.completeReview();

      // 4. The completion timestamp must be persisted via synced prefs.
      final last = c.read(periodicReviewLastCompletedProvider);
      expect(last, isNotNull);
      expect(c.read(periodicReviewIsDueProvider), isFalse);

      // 5. State has been reset so re-entering the wizard starts fresh.
      final post = c.read(periodicReviewProvider);
      expect(post.currentStep, equals(0));
      expect(post.inboxNav.isLoaded, isFalse);
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

    test('disjointness — person-tagged next action appears in Waiting For '
        'only, plain next action appears in Next Actions only', () async {
      await c.read(syncedPreferencesProvider.future);
      final now = DateTime.now();

      // Person-tagged next action — should land in Waiting For only.
      await db.into(db.todos).insert(TodosCompanion(
            id: const Value('wf1'),
            title: const Value('Delegated task'),
            clarified: const Value(true),
            intent: const Value('next'),
            userId: const Value('local'),
            createdAt: Value(now),
            updatedAt: Value(now),
          ));
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('alice'),
        name: Value('Alice'),
        type: Value('person'),
        userId: Value('local'),
      ));
      await db.tagDao.assignTag('wf1', 'alice', 'local');

      // Plain next action with no person tag — should land in Next Actions.
      await db.into(db.todos).insert(TodosCompanion(
            id: const Value('na1'),
            title: const Value('Plain next'),
            clarified: const Value(true),
            intent: const Value('next'),
            userId: const Value('local'),
            createdAt: Value(now.add(const Duration(seconds: 1))),
            updatedAt: Value(now.add(const Duration(seconds: 1))),
          ));

      // Project-tagged next action with NO person tag — must still appear in
      // Next Actions (project-tag exclusion no longer applies).
      await db.into(db.todos).insert(TodosCompanion(
            id: const Value('na2'),
            title: const Value('Project task'),
            clarified: const Value(true),
            intent: const Value('next'),
            userId: const Value('local'),
            createdAt: Value(now.add(const Duration(seconds: 2))),
            updatedAt: Value(now.add(const Duration(seconds: 2))),
          ));
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('garage'),
        name: Value('Garage'),
        type: Value('project'),
        userId: Value('local'),
      ));
      await db.tagDao.assignTag('na2', 'garage', 'local');

      final notifier = c.read(periodicReviewProvider.notifier);
      await notifier.loadAllSnapshots();

      final state = c.read(periodicReviewProvider);
      expect(state.waitingForNav.isLoaded, isTrue);
      expect(state.nextActionsNav.isLoaded, isTrue);
      final waitingIds =
          state.waitingForNav.items!.map((t) => t.id).toSet();
      final nextIds =
          state.nextActionsNav.items!.map((t) => t.id).toSet();

      expect(waitingIds, equals({'wf1'}));
      expect(nextIds, equals({'na1', 'na2'}));
      // Disjointness invariant: no task surfaces in both snapshots.
      expect(waitingIds.intersection(nextIds), isEmpty);
    });

    test('Next Actions step auto-skips when its snapshot is empty', () async {
      await c.read(syncedPreferencesProvider.future);
      final notifier = c.read(periodicReviewProvider.notifier);

      await notifier.goToStep(PeriodicReviewNotifier.kStepNextActions);
      final state = c.read(periodicReviewProvider);
      expect(state.nextActionsNav.isLoaded, isTrue);
      expect(state.nextActionsNav.isEmpty, isTrue);
      expect(state.currentStep,
          isNot(PeriodicReviewNotifier.kStepNextActions));
    });
  });
}
