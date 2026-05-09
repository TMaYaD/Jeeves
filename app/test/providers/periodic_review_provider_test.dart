import 'package:drift/drift.dart' show Value;
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
    title: Value('Item $id'),
    userId: const Value('local'),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
}

Future<void> _insertMaybe(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Maybe $id'),
        userId: const Value('local'),
        intent: const Value('maybe'),
        clarified: const Value(true),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
}

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('PeriodicReviewNotifier', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = createPeriodicReviewTestContainer(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('loadInboxSnapshot populates inboxNav with todo ids', () async {
      await _insertInbox(db, 'a');
      await _insertInbox(db, 'b');

      await container
          .read(periodicReviewProvider.notifier)
          .loadInboxSnapshot();

      final nav = container.read(periodicReviewProvider).inboxNav;
      expect(nav.isLoaded, isTrue);
      expect(nav.length, equals(2));
    });

    test('loadInboxSnapshot leaves inboxNav empty when there is no inbox',
        () async {
      await container
          .read(periodicReviewProvider.notifier)
          .loadInboxSnapshot();

      final nav = container.read(periodicReviewProvider).inboxNav;
      expect(nav.isLoaded, isTrue);
      expect(nav.isEmpty, isTrue);
    });

    test('loadSomedaySnapshot populates somedayNav from maybeProvider',
        () async {
      await _insertMaybe(db, 's1');
      await _insertMaybe(db, 's2');

      await container
          .read(periodicReviewProvider.notifier)
          .loadSomedaySnapshot();

      final nav = container.read(periodicReviewProvider).somedayNav;
      expect(nav.isLoaded, isTrue);
      expect(nav.length, equals(2));
    });

    test('completeReview persists timestamp and resets in-session state',
        () async {
      await _insertInbox(db, 'a');
      await container.read(syncedPreferencesProvider.future);
      final notifier = container.read(periodicReviewProvider.notifier);

      // Walk the wizard far enough to populate state, then complete.
      await notifier.loadInboxSnapshot();
      notifier.advanceInbox();
      await notifier.goToStep(PeriodicReviewNotifier.kStepSummary);

      await notifier.completeReview();
      // Allow the syncedPreferences listener (which re-derives settings) to run.
      await Future<void>.delayed(Duration.zero);

      final last =
          container.read(periodicReviewLastCompletedProvider);
      expect(last, isNotNull);

      // State must be back to its initial form so the next ceremony does not
      // resume the previous one.
      final state = container.read(periodicReviewProvider);
      expect(state.currentStep, equals(0));
      expect(state.inboxNav.isLoaded, isFalse);
    });

    test('per-step nav advance/previous mutate the matching nav only', () async {
      await _insertMaybe(db, 'm1');
      await _insertMaybe(db, 'm2');

      final notifier = container.read(periodicReviewProvider.notifier);
      await notifier.loadSomedaySnapshot();
      notifier.advanceSomeday();
      expect(container.read(periodicReviewProvider).somedayNav.index, 1);
      notifier.previousSomeday();
      expect(container.read(periodicReviewProvider).somedayNav.index, 0);
    });
  });
}
