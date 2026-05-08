import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/periodic_review_provider.dart';
import 'package:jeeves/providers/periodic_review_settings_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

class _StubNotificationService extends NotificationService {
  _StubNotificationService() : super.forTesting();

  @override
  Future<void> schedulePeriodicReviewReminder(
      {required TimeOfDay time}) async {}

  @override
  Future<void> snoozePeriodicReviewReminder(int minutes) async {}

  @override
  Future<void> cancelPeriodicReviewReminder() async {}
}

ProviderContainer _container(GtdDatabase db) => ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider
            .overrideWithValue(_StubNotificationService()),
      ],
    );

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
      container = _container(db);
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

    test('setObjectives accepts any list', () {
      container
          .read(periodicReviewProvider.notifier)
          .setObjectives(['Plan', 'Ship', 'Touch grass']);
      expect(container.read(periodicReviewProvider).objectives.length, 3);
    });

    test('completeReview persists objectives JSON and flips isComplete',
        () async {
      await container.read(syncedPreferencesProvider.future);
      final notifier = container.read(periodicReviewProvider.notifier);
      notifier.setObjectives(['  Plan  ', '', 'Ship']);

      await notifier.completeReview();
      // Allow the syncedPreferences listener (which re-derives settings) to run.
      await Future<void>.delayed(Duration.zero);

      final state = container.read(periodicReviewProvider);
      expect(state.isComplete, isTrue);

      final objectives =
          container.read(periodicReviewLastObjectivesProvider);
      expect(objectives, equals(['Plan', 'Ship']));

      final last =
          container.read(periodicReviewLastCompletedProvider);
      expect(last, isNotNull);
    });

    test(
        'recordBrainDumpItem increments the captured counter without DAO writes',
        () {
      container.read(periodicReviewProvider.notifier).recordBrainDumpItem();
      container.read(periodicReviewProvider.notifier).recordBrainDumpItem();

      expect(container.read(periodicReviewProvider).brainDumpAdded, equals(2));
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
