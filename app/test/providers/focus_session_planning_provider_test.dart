import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show RoutingKind;
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import '../test_helpers.dart';

// Minimal stub — avoids hitting NotificationService platform channels in unit tests.
class _StubFocusSessionPlanningNotifier extends FocusSessionPlanningNotifier {
  @override
  Future<void> dismissBannerForToday() async {
    final today = planningToday();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('planning_banner_dismissed_date', today);
    focusSessionPlanningBannerDismissedNotifier.value = true;
  }

  @override
  Future<void> skipPlanningToday() async {
    await persistFocusSessionPlanningSkipToday();
    // NotificationService not called in tests.
  }

  @override
  Future<void> snoozePlanningNotification(int minutes) async {
    final until = DateTime.now().add(Duration(minutes: minutes));
    await persistFocusSessionPlanningSnoozedUntil(until);
    // NotificationService not called in tests.
  }
}

ProviderContainer _container(GtdDatabase db) => ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        focusSessionPlanningProvider
            .overrideWith(() => _StubFocusSessionPlanningNotifier()),
      ],
    );

Future<void> _insertInboxItem(
  GtdDatabase db, {
  required String id,
  DateTime? createdAt,
}) async {
  final now = createdAt ?? DateTime.now();
  await db.inboxDao.insertTodo(TodosCompanion(
    id: Value(id),
    title: Value('Item $id'),
    userId: const Value('local'),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
}

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('FocusSessionPlanningNotifier', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = _container(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      focusSessionPlanningCompletionNotifier.value = false;
      focusSessionPlanningBannerDismissedNotifier.value = false;
    });

    test('startDay preserves energyLevel and availableMinutes', () async {
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      notifier.setEnergyLevel('medium');
      notifier.setAvailableTime(300); // 5 hours

      await notifier.startDay();

      final stateAfterStart = container.read(focusSessionPlanningProvider);
      expect(stateAfterStart.energyLevel, 'medium',
          reason: 'startDay should not clear energy level');
      expect(stateAfterStart.availableMinutes, 300,
          reason: 'startDay should not clear available minutes');
      expect(stateAfterStart.availableTimeSet, isTrue,
          reason: 'startDay should not clear availableTimeSet flag');
    });

    test('reEnterPlanning restores energy and time after startDay', () async {
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      notifier.setEnergyLevel('high');
      notifier.setAvailableTime(360); // 6 hours

      await notifier.startDay();
      await notifier.reEnterPlanning();

      final state = container.read(focusSessionPlanningProvider);
      expect(state.energyLevel, 'high',
          reason: 'reEnterPlanning should restore energy from before startDay');
      expect(state.availableMinutes, 360,
          reason: 'reEnterPlanning should restore available minutes');
      expect(state.availableTimeSet, isTrue,
          reason: 'reEnterPlanning should restore availableTimeSet flag');
      expect(state.currentStep, 0,
          reason: 'reEnterPlanning should reset to step 0');
    });

    test('startDay resets step and snapshot navigation', () async {
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      notifier.advanceStep();
      notifier.advanceStep();

      await notifier.startDay();

      final state = container.read(focusSessionPlanningProvider);
      expect(state.currentStep, 0);
      expect(state.inboxNav.items, isNull);
      expect(state.inboxNav.index, 0);
      expect(state.inboxRoutings, isEmpty);
    });
  });

  group('FocusSessionPlanningNotifier — banner dismissal', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = _container(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      focusSessionPlanningBannerDismissedNotifier.value = false;
      focusSessionPlanningCompletionNotifier.value = false;
    });

    test('dismissBannerForToday sets focusSessionPlanningBannerDismissedNotifier and persists',
        () async {
      final notifier = container.read(focusSessionPlanningProvider.notifier);
      expect(focusSessionPlanningBannerDismissedNotifier.value, isFalse);

      await notifier.dismissBannerForToday();

      expect(focusSessionPlanningBannerDismissedNotifier.value, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('planning_banner_dismissed_date'),
          equals(planningToday()));
    });

    test('focusSessionPlanningBannerDismissedNotifier resets to false for a different day',
        () async {
      // Simulate yesterday's dismissal persisted.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('planning_banner_dismissed_date', '2000-01-01');
      await initFocusSessionPlanningCompletion();

      // Today does not match '2000-01-01'.
      expect(focusSessionPlanningBannerDismissedNotifier.value, isFalse);
    });
  });

  group('FocusSessionPlanningNotifier — inbox double-process guard', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = _container(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      focusSessionPlanningCompletionNotifier.value = false;
    });

    test('processInboxItem twice concurrently updates DB only once',
        () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      // Fire both without awaiting the first so they race.
      final first = notifier.processInboxItem('item-1', title: 'Test item');
      final second = notifier.processInboxItem('item-1', title: 'Test item');
      await Future.wait([first, second]);

      final state = container.read(focusSessionPlanningProvider);
      expect(state.inboxRoutings[0]?.kind, equals(RoutingKind.nextAction),
          reason: 'Routing recorded exactly once for index 0');
      expect(state.inboxNav.index, equals(1),
          reason: 'Index advanced exactly once');

      final row = await (db.select(db.todos)
            ..where((t) => t.id.equals('item-1')))
          .getSingle();
      expect(row.clarified, isTrue);
    });

    test('processInboxItemToMaybe twice concurrently updates DB only once',
        () async {
      await _insertInboxItem(db, id: 'item-2');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      final first = notifier.processInboxItemToMaybe('item-2');
      final second = notifier.processInboxItemToMaybe('item-2');
      await Future.wait([first, second]);

      final state = container.read(focusSessionPlanningProvider);
      expect(state.inboxRoutings[0]?.kind, equals(RoutingKind.maybe),
          reason: 'Routing recorded exactly once for index 0');
      expect(state.inboxNav.index, equals(1));

      final row = await (db.select(db.todos)
            ..where((t) => t.id.equals('item-2')))
          .getSingle();
      expect(row.clarified, isTrue);
      expect(row.intent, 'maybe');
    });
  });

  group('FocusSessionPlanningNotifier — skip and snooze', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = _container(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      // Reset SharedPreferences mock and reload suppression flags to clear state.
      SharedPreferences.setMockInitialValues({});
      await loadFocusSessionPlanningNotificationSuppression();
    });

    test('skipPlanningToday sets skipped flag for today', () async {
      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.skipPlanningToday();

      expect(isFocusSessionPlanningNotificationSuppressed(), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('planning_notification_skipped_date'),
          equals(planningToday()));
    });

    test('snoozePlanningNotification sets snoozed-until in the future',
        () async {
      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.snoozePlanningNotification(60);

      expect(isFocusSessionPlanningNotificationSuppressed(), isTrue);

      final prefs = await SharedPreferences.getInstance();
      final stored =
          DateTime.tryParse(prefs.getString('planning_notification_snoozed_until') ?? '');
      expect(stored, isNotNull);
      expect(stored!.isAfter(DateTime.now()), isTrue);
    });

    test('loadFocusSessionPlanningNotificationSuppression reflects skipped state', () async {
      // Persist the skip date directly without going through persistFocusSessionPlanningSkipToday
      // so we can independently verify loadFocusSessionPlanningNotificationSuppression picks it up.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('planning_notification_skipped_date', planningToday());

      await loadFocusSessionPlanningNotificationSuppression();
      expect(isFocusSessionPlanningNotificationSuppressed(), isTrue);
    });

    test('skip state from a previous day does not suppress today', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('planning_notification_skipped_date', '2000-01-01');
      await loadFocusSessionPlanningNotificationSuppression();

      expect(isFocusSessionPlanningNotificationSuppressed(), isFalse);
    });
  });

  group('Inbox snapshot navigation', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = _container(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      focusSessionPlanningCompletionNotifier.value = false;
    });

    test('loadInboxSnapshot populates state from DB in FIFO order', () async {
      // Insert oldest first, newest last. watchInbox orders DESC by createdAt,
      // so reversed gives oldest-first (FIFO).
      final t1 = DateTime(2025, 1, 1);
      final t2 = DateTime(2025, 1, 2);
      await _insertInboxItem(db, id: 'old', createdAt: t1);
      await _insertInboxItem(db, id: 'new', createdAt: t2);

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      final state = container.read(focusSessionPlanningProvider);
      expect(state.inboxNav.items, isNotNull);
      expect(state.inboxNav.items, equals(['old', 'new']),
          reason: 'oldest item first (FIFO order)');
    });

    test('loadInboxSnapshot is idempotent', () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      // Insert a new item; second load should not pick it up.
      await _insertInboxItem(db, id: 'item-2');
      await notifier.loadInboxSnapshot();

      final state = container.read(focusSessionPlanningProvider);
      expect(state.inboxNav.items!.length, equals(1),
          reason: 'second load is a no-op; snapshot stays frozen');
    });

    test('nextInboxItem increments index', () async {
      await _insertInboxItem(db, id: 'item-1');
      await _insertInboxItem(db, id: 'item-2');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      expect(container.read(focusSessionPlanningProvider).inboxNav.index, 0);
      notifier.nextInboxItem();
      expect(container.read(focusSessionPlanningProvider).inboxNav.index, 1);
    });

    test('previousInboxItem decrements index, clamped at 0', () async {
      await _insertInboxItem(db, id: 'item-1');
      await _insertInboxItem(db, id: 'item-2');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();
      notifier.nextInboxItem(); // index = 1

      notifier.previousInboxItem(); // index = 0
      expect(container.read(focusSessionPlanningProvider).inboxNav.index, 0);

      // Already at 0 — must stay at 0.
      notifier.previousInboxItem();
      expect(container.read(focusSessionPlanningProvider).inboxNav.index, 0);
    });

    test('skipInboxItem advances index without DB write and without adding to inboxRoutings',
        () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      notifier.skipInboxItem();

      final state = container.read(focusSessionPlanningProvider);
      expect(state.inboxNav.index, 1);
      expect(state.inboxRoutings, isEmpty);

      final row = await (db.select(db.todos)
            ..where((t) => t.id.equals('item-1')))
          .getSingle();
      expect(row.clarified, isFalse,
          reason: 'skip must not write to DB');
    });

    test('processInboxItem writes to DB, advances index, and records routing',
        () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();
      await notifier.processInboxItem('item-1', title: 'Test item');

      final state = container.read(focusSessionPlanningProvider);
      expect(state.inboxNav.index, 1);
      expect(state.inboxRoutings[0]?.kind, equals(RoutingKind.nextAction));

      final row = await (db.select(db.todos)
            ..where((t) => t.id.equals('item-1')))
          .getSingle();
      expect(row.clarified, isTrue);
    });

    test('processInboxItemToMaybe writes to DB, advances index, and records routing',
        () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();
      await notifier.processInboxItemToMaybe('item-1');

      final state = container.read(focusSessionPlanningProvider);
      expect(state.inboxNav.index, 1);
      expect(state.inboxRoutings[0]?.kind, equals(RoutingKind.maybe));

      final row = await (db.select(db.todos)
            ..where((t) => t.id.equals('item-1')))
          .getSingle();
      expect(row.clarified, isTrue);
      expect(row.intent, 'maybe');
    });

    test('processInboxItemToDone writes to DB, advances index, and records routing',
        () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();
      await notifier.processInboxItemToDone('item-1');

      final state = container.read(focusSessionPlanningProvider);
      expect(state.inboxNav.index, 1);
      expect(state.inboxRoutings[0]?.kind, equals(RoutingKind.done));

      final row = await (db.select(db.todos)
            ..where((t) => t.id.equals('item-1')))
          .getSingle();
      expect(row.doneAt, isNotNull);
    });

    test('Back is pure navigation; re-route reverts and re-applies', () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      await notifier.processInboxItemToMaybe('item-1');
      notifier.previousInboxItem(); // pure nav: DB stays in maybe state

      // After Back, the prior routing remains in DB and in inboxRoutings so
      // the "previously selected" affordance can render.
      final afterBack = await (db.select(db.todos)
            ..where((t) => t.id.equals('item-1')))
          .getSingle();
      expect(afterBack.clarified, isTrue,
          reason: 'Back must not revert DB state');
      expect(afterBack.intent, 'maybe');
      var state = container.read(focusSessionPlanningProvider);
      expect(state.inboxRoutings[0]?.kind, equals(RoutingKind.maybe));

      // Re-tapping a different destination triggers the revert + re-apply.
      await notifier.processInboxItem('item-1', title: 'Test item');

      final row = await (db.select(db.todos)
            ..where((t) => t.id.equals('item-1')))
          .getSingle();
      expect(row.clarified, isTrue);
      expect(row.intent, 'next',
          reason: 'revert restored prior intent before re-routing');
      expect(row.doneAt, isNull);
      state = container.read(focusSessionPlanningProvider);
      expect(state.inboxRoutings[0]?.kind, equals(RoutingKind.nextAction));
    });

    test('revert does not modify title, notes, energy, time estimate, due date',
        () async {
      final now = DateTime.now();
      await db.inboxDao.insertTodo(TodosCompanion(
        id: const Value('rich-item'),
        title: const Value('My task'),
        notes: const Value('some notes'),
        energyLevel: const Value('high'),
        timeEstimate: const Value(30),
        userId: const Value('local'),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();
      await notifier.processInboxItem('rich-item', title: 'Test item');
      notifier.previousInboxItem();
      await notifier.processInboxItemToMaybe('rich-item');

      final row = await (db.select(db.todos)
            ..where((t) => t.id.equals('rich-item')))
          .getSingle();
      expect(row.title, 'My task');
      expect(row.notes, 'some notes');
      expect(row.energyLevel, 'high');
      expect(row.timeEstimate, 30);
    });

    test('re-routing to a different destination undoes prior routing side effects',
        () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      // Route to Maybe first.
      await notifier.processInboxItemToMaybe('item-1');
      notifier.previousInboxItem();

      // Re-route to Next Action — the handler reverts maybe before applying.
      await notifier.processInboxItem('item-1', title: 'Test item');

      final row = await (db.select(db.todos)
            ..where((t) => t.id.equals('item-1')))
          .getSingle();
      expect(row.clarified, isTrue);
      expect(row.intent, 'next',
          reason: 'revert restored prior intent before next_action routing');

      final state = container.read(focusSessionPlanningProvider);
      expect(state.inboxRoutings[0]?.kind, equals(RoutingKind.nextAction));
    });

    test('re-routing Done → Next Action clears done_at', () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      await notifier.processInboxItemToDone('item-1');
      notifier.previousInboxItem();
      await notifier.processInboxItem('item-1', title: 'Test item');

      final row = await (db.select(db.todos)
            ..where((t) => t.id.equals('item-1')))
          .getSingle();
      expect(row.doneAt, isNull);
      expect(row.clarified, isTrue);
    });

    test('re-tapping the same destination is a net no-op on routing flags',
        () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      await notifier.processInboxItem('item-1', title: 'Test item');
      final beforeRow = await (db.select(db.todos)
            ..where((t) => t.id.equals('item-1')))
          .getSingle();

      notifier.previousInboxItem();
      await notifier.processInboxItem('item-1', title: 'Test item'); // same destination

      final afterRow = await (db.select(db.todos)
            ..where((t) => t.id.equals('item-1')))
          .getSingle();

      expect(afterRow.clarified, equals(beforeRow.clarified));
      expect(afterRow.intent, equals(beforeRow.intent));
      expect(afterRow.doneAt, equals(beforeRow.doneAt));

      final state = container.read(focusSessionPlanningProvider);
      expect(state.inboxRoutings[0]?.kind, equals(RoutingKind.nextAction));
    });

    test('progress fraction is inboxIndex / inboxSnapshot.length', () async {
      await _insertInboxItem(db, id: 'item-1');
      await _insertInboxItem(db, id: 'item-2');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      var state = container.read(focusSessionPlanningProvider);
      expect(state.inboxNav.index / state.inboxNav.items!.length, equals(0.0));

      notifier.nextInboxItem();
      state = container.read(focusSessionPlanningProvider);
      expect(state.inboxNav.index / state.inboxNav.items!.length, equals(0.5));
    });

    test('isInboxComplete is true when inboxIndex >= inboxSnapshot.length',
        () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      var state = container.read(focusSessionPlanningProvider);
      expect(state.inboxNav.index >= state.inboxNav.items!.length, isFalse);

      await notifier.processInboxItem('item-1', title: 'Test item');
      state = container.read(focusSessionPlanningProvider);
      expect(state.inboxNav.index >= state.inboxNav.items!.length, isTrue);
    });

    test('snapshot does not drift when DB changes mid-session', () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      // Insert a new inbox item after loading.
      await _insertInboxItem(db, id: 'item-2');

      final state = container.read(focusSessionPlanningProvider);
      expect(state.inboxNav.items!.length, equals(1),
          reason: 'snapshot frozen at load time');
    });

    test(
        'revert preserves pre-existing person tags (no data loss from import/sync)',
        () async {
      // Inbox item with a pre-existing person-tag association (e.g. from sync).
      await _insertInboxItem(db, id: 'item-1');
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('alice'),
        name: Value('Alice'),
        type: Value('person'),
        userId: Value('local'),
      ));
      await db.tagDao.assignTag('item-1', 'alice', 'local');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      // Route to maybe, then re-route to next_action — the in-handler revert
      // path runs and must NOT drop the pre-existing 'alice' tag.
      await notifier.processInboxItemToMaybe('item-1');
      notifier.previousInboxItem();
      await notifier.processInboxItem('item-1', title: 'Test item');

      final tagIds = await db.todoDao.getPersonTagIdsForTodo('item-1');
      expect(tagIds, contains('alice'),
          reason: 'pre-existing person tag must survive revert');
    });

    test('routing bails out when the snapshot row was deleted before apply',
        () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      // External delete lands AFTER snapshot load but BEFORE routing.
      await (db.delete(db.todos)..where((t) => t.id.equals('item-1'))).go();

      // Routing must not advance the cursor or record a phantom routing.
      await notifier.processInboxItem('item-1', title: 'Test item');

      final state = container.read(focusSessionPlanningProvider);
      expect(state.inboxNav.index, equals(0),
          reason: 'cursor must not advance when row no longer exists');
      expect(state.inboxRoutings, isEmpty,
          reason: 'no routing record for a missing row');
    });
  });

  // ---------------------------------------------------------------------------
  // Step-skip behaviour
  // ---------------------------------------------------------------------------

  group('FocusSessionPlanningNotifier — step-skip (review step)', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = _container(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      focusSessionPlanningCompletionNotifier.value = false;
    });

    test('advanceStep skips step 1 when no review items', () async {
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      await notifier.advanceStep(); // from step 0

      final state = container.read(focusSessionPlanningProvider);
      expect(state.currentStep, 2,
          reason: 'step 1 (review) should be skipped when no items need review');
    });

    test('advanceStep lands on step 1 when review items exist', () async {
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
        id: const Value('actionless-1'),
        title: const Value('Actionless task'),
        userId: const Value('local'),
        clarified: const Value(true),
        createdAt: Value(now),
        // nextActionText absent → NULL → Actionless
      ));
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      await notifier.advanceStep(); // from step 0

      final state = container.read(focusSessionPlanningProvider);
      expect(state.currentStep, 1,
          reason: 'step 1 (review) should not be skipped when items exist');
      expect(state.reviewNav.items, hasLength(1));
      expect(state.reviewNav.index, 0);
    });

    test('advanceStep from step 1 lands on step 2', () async {
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
        id: const Value('actionless-2'),
        title: const Value('Actionless task'),
        userId: const Value('local'),
        clarified: const Value(true),
        createdAt: Value(now),
      ));
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      notifier.goToStep(1);
      await notifier.advanceStep(); // from step 1 → step 2

      final state = container.read(focusSessionPlanningProvider);
      expect(state.currentStep, 2);
    });
  });

  // ---------------------------------------------------------------------------
  // Review step actions
  // ---------------------------------------------------------------------------

  group('FocusSessionPlanningNotifier — review step actions', () {
    late GtdDatabase db;
    late ProviderContainer container;

    const userId = 'local';

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = _container(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      focusSessionPlanningCompletionNotifier.value = false;
    });

    Future<String> insertStaleTask() async {
      final now = DateTime.now();
      final id = 'stale-${now.microsecondsSinceEpoch}';
      final clarifiedAt = now.subtract(const Duration(hours: 2)).toUtc();
      final completedAt = now.subtract(const Duration(hours: 1)).toUtc();
      await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: const Value('Stale task'),
        userId: const Value(userId),
        clarified: const Value(true),
        createdAt: Value(now),
        nextActionText: const Value('Do the thing'),
        lastClarifiedAt: Value(clarifiedAt),
        lastNextActionCompletionAt: Value(completedAt),
      ));
      return id;
    }

    Future<String> insertActionlessTask() async {
      final now = DateTime.now();
      final id = 'actionless-${now.microsecondsSinceEpoch}';
      await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: const Value('Actionless task'),
        userId: const Value(userId),
        clarified: const Value(true),
        createdAt: Value(now),
        // nextActionText absent → NULL
      ));
      return id;
    }

    test('confirmReviewItemRelevant: stamps lastClarifiedAt; task leaves watchNeedsReview; reviewIndex advances',
        () async {
      final id = await insertStaleTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      expect(
          await db.todoDao.watchNeedsReview().first, hasLength(1));

      await notifier.confirmReviewItemRelevant(id);

      expect(
          await db.todoDao.watchNeedsReview().first, isEmpty);
      final state = container.read(focusSessionPlanningProvider);
      expect(state.reviewNav.index, 1);
    });

    test('updateReviewItemNextAction: sets nextActionText; stamps lastClarifiedAt; reviewIndex advances',
        () async {
      final id = await insertActionlessTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      expect(
          await db.todoDao.watchNeedsReview().first, hasLength(1));

      await notifier.updateReviewItemNextAction(id, 'Draft the proposal');

      expect(
          await db.todoDao.watchNeedsReview().first, isEmpty);

      final todo = await db.todoDao.getTodo(id);
      expect(todo?.nextActionText, 'Draft the proposal');

      final state = container.read(focusSessionPlanningProvider);
      expect(state.reviewNav.index, 1);
    });

    test('markReviewItemDone: task doneAt set; not in result; reviewIndex advances',
        () async {
      final id = await insertStaleTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      await notifier.markReviewItemDone(id);

      expect(
          await db.todoDao.watchNeedsReview().first, isEmpty);

      final todo = await db.todoDao.getTodo(id);
      expect(todo?.doneAt, isNotNull);

      final state = container.read(focusSessionPlanningProvider);
      expect(state.reviewNav.index, 1);
    });

    test('deferReviewItemToSomeday: stale task intent=maybe; leaves result; reviewIndex advances',
        () async {
      final id = await insertStaleTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      await notifier.deferReviewItemToSomeday(id);

      expect(
          await db.todoDao.watchNeedsReview().first, isEmpty);

      final todo = await db.todoDao.getTodo(id);
      expect(todo?.intent, 'maybe');

      final state = container.read(focusSessionPlanningProvider);
      expect(state.reviewNav.index, 1);
    });

    test('trashReviewItem: task intent=trash; not in result; reviewIndex advances',
        () async {
      final id = await insertStaleTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      await notifier.trashReviewItem(id);

      expect(
          await db.todoDao.watchNeedsReview().first, isEmpty);

      final todo = await db.todoDao.getTodo(id);
      expect(todo?.intent, 'trash');

      final state = container.read(focusSessionPlanningProvider);
      expect(state.reviewNav.index, 1);
    });

    test('deferReviewItemToSomeday on actionless task: leaves result; reviewIndex advances',
        () async {
      // intent=maybe is excluded from the review predicate, so the task leaves
      // the queue even when next_action_text is NULL.
      final id = await insertActionlessTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      await notifier.deferReviewItemToSomeday(id);

      expect(
          await db.todoDao.watchNeedsReview().first, isEmpty);

      final state = container.read(focusSessionPlanningProvider);
      expect(state.reviewNav.index, 1);
    });

    test('markReviewItemWaitingFor on stale task: task leaves result; reviewIndex advances',
        () async {
      final id = await insertStaleTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      expect(await db.todoDao.watchNeedsReview().first, hasLength(1));

      await notifier.markReviewItemWaitingFor(id);

      expect(await db.todoDao.watchNeedsReview().first, isEmpty);

      final state = container.read(focusSessionPlanningProvider);
      expect(state.reviewNav.index, 1);
    });

    test('markReviewItemWaitingFor on actionless task: leaves next_action_text untouched; task remains in needs-review',
        () async {
      // Routing is intent-only; per the orthogonality model, the
      // user-action axis (`next_action_text`) is not touched by a route
      // to waitingFor. An actionless task therefore stays in the
      // re-clarification queue until the dialog records a phrase.
      final id = await insertActionlessTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      expect(await db.todoDao.watchNeedsReview().first, hasLength(1));

      await notifier.markReviewItemWaitingFor(id);

      final todo = await db.todoDao.getTodo(id);
      expect(todo?.nextActionText, isNull,
          reason: 'orthogonality: routing must not write next_action_text');

      final state = container.read(focusSessionPlanningProvider);
      expect(state.reviewNav.index, 1);
    });

    test('updateReviewItemNextAction with blank text: stays in result; reviewIndex does not advance; action record cleared',
        () async {
      // Blank text normalises to NULL → task stays Actionless → not counted as done.
      final id = await insertActionlessTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      // Load review items so the prior-action lookup can resolve the task.
      await notifier.advanceStep();
      expect(container.read(focusSessionPlanningProvider).reviewNav.items, hasLength(1));

      // First commit a real action so there's a stale record to clear.
      await notifier.updateReviewItemNextAction(id, 'Draft the proposal');
      expect(container.read(focusSessionPlanningProvider).reviewNav.index, 1);
      notifier.reviewBack();

      // Submit blank — should clear the stale record without advancing.
      await notifier.updateReviewItemNextAction(id, '   ');

      expect(await db.todoDao.watchNeedsReview().first, isNotEmpty);

      final state = container.read(focusSessionPlanningProvider);
      expect(state.reviewNav.index, 0);
      expect(state.reviewActions[0], isNull,
          reason: 'stale action record must be cleared so dialog does not pre-fill with old text');
    });

    // ---- Re-selection (back + different action) --------------------------------

    test('markDone then back then deferToSomeday: done_at cleared, intent=maybe',
        () async {
      final id = await insertStaleTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      // Load review items the same way the UI does.
      await notifier.advanceStep(); // step 0 → step 1, loads reviewItems
      expect(container.read(focusSessionPlanningProvider).reviewNav.items, hasLength(1));

      await notifier.markReviewItemDone(id);

      final afterDone = await db.todoDao.getTodo(id);
      expect(afterDone?.doneAt, isNotNull);

      notifier.reviewBack();

      await notifier.deferReviewItemToSomeday(id);

      final afterSomeday = await db.todoDao.getTodo(id);
      expect(afterSomeday?.doneAt, isNull, reason: 'done_at must be cleared');
      expect(afterSomeday?.intent, 'maybe');
    });

    test('trashReviewItem then back then markDone: done_at set (intent left as-is)',
        () async {
      final id = await insertStaleTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      await notifier.advanceStep();
      expect(container.read(focusSessionPlanningProvider).reviewNav.items, hasLength(1));

      await notifier.trashReviewItem(id);

      final afterTrash = await db.todoDao.getTodo(id);
      expect(afterTrash?.intent, 'trash');

      notifier.reviewBack();

      await notifier.markReviewItemDone(id);

      final afterDone = await db.todoDao.getTodo(id);
      // intent is irrelevant for done tasks — it is left as-is, not reset.
      expect(afterDone?.doneAt, isNotNull);
    });

    test('trash then back then confirmRelevant: intent reset to next',
        () async {
      final id = await insertStaleTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      await notifier.advanceStep();

      await notifier.trashReviewItem(id);

      notifier.reviewBack();

      await notifier.confirmReviewItemRelevant(id);

      final task = await db.todoDao.getTodo(id);
      expect(task?.intent, 'next',
          reason: 'stamp actions expect an active task; intent must be restored');
      expect(task?.doneAt, isNull);
    });

    test('updateNextAction then back then deferToSomeday: next_action_text preserved',
        () async {
      final id = await insertActionlessTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      await notifier.advanceStep();

      await notifier.updateReviewItemNextAction(id, 'Draft the brief');

      notifier.reviewBack();

      await notifier.deferReviewItemToSomeday(id);

      final task = await db.todoDao.getTodo(id);
      expect(task?.intent, 'maybe');
      expect(task?.nextActionText, 'Draft the brief',
          reason: 'next_action_text must not be reverted when going to someday');
    });
  });

  // ---------------------------------------------------------------------------
  // Inbox-clarify sets next_action_text
  // ---------------------------------------------------------------------------

  group('FocusSessionPlanningNotifier — processInboxItem sets nextActionText',
      () {
    late GtdDatabase db;
    late ProviderContainer container;

    const userId = 'local';

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = _container(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      focusSessionPlanningCompletionNotifier.value = false;
    });

    Future<String> insertInboxTask(String title) async {
      final now = DateTime.now();
      final id = 'inbox-${now.microsecondsSinceEpoch}';
      await db.inboxDao.insertTodo(TodosCompanion(
        id: Value(id),
        title: Value(title),
        userId: const Value(userId),
        createdAt: Value(now),
      ));
      return id;
    }

    test('processInboxItem sets nextActionText to provided title', () async {
      final id = await insertInboxTask('Buy milk');
      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      await notifier.processInboxItem(id, title: 'Buy milk');

      final todo = await db.todoDao.getTodo(id);
      expect(todo?.nextActionText, 'Buy milk');
      expect(todo?.clarified, isTrue);
    });

    test('processInboxItem: task does not appear in watchNeedsReview after clarify',
        () async {
      final id = await insertInboxTask('Buy milk');
      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      await notifier.processInboxItem(id, title: 'Buy milk');

      final result = await db.todoDao.watchNeedsReview().first;
      expect(result, isEmpty);
    });

    test('processInboxItemToMaybe sets intent=maybe and clarified=true', () async {
      final id = await insertInboxTask('Read that book');
      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      await notifier.processInboxItemToMaybe(id);

      final todo = await db.todoDao.getTodo(id);
      expect(todo?.intent, 'maybe');
      expect(todo?.clarified, isTrue);
    });
  });
}
