import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show RoutingKind;
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/services/notification_service.dart';
import '../test_helpers.dart';

/// Pumps the event loop until [predicate] holds or [timeout] elapses. Async
/// preloads scheduled from a notifier's build() (the rollover pre-selection DAO
/// read) can take more than one microtask to settle, so a single
/// `Future.delayed(Duration.zero)` races them — poll for the expected state.
Future<void> _settleUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

// Minimal stub — avoids hitting NotificationService platform channels in unit tests.
class _StubFocusSessionPlanningNotifier extends FocusSessionPlanningNotifier {
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
        notificationServiceProvider
            .overrideWithValue(StubNotificationService()),
        focusSessionPlanningProvider
            .overrideWith(() => _StubFocusSessionPlanningNotifier()),
      ],
    );

/// An Inbox item is a Capture with `clarified_at IS NULL` (ADR-0006).
Future<void> _insertInboxItem(
  GtdDatabase db, {
  required String id,
  DateTime? createdAt,
}) async {
  final now = createdAt ?? DateTime.now();
  await db.captureDao.insertCapture(CapturesCompanion(
    id: Value(id),
    title: Value('Item $id'),
    userId: const Value('local'),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
}

/// The Outcome a Capture was clarified into, or null if it produced none
/// (a discard). Clarifying creates a *new* row, so assertions read through
/// the provenance link rather than re-reading the Capture's id.
Future<Todo?> _outcomeOf(GtdDatabase db, String captureId) async {
  final ids = await db.captureDao.outcomeIdsForCapture(captureId);
  if (ids.isEmpty) return null;
  return db.todoDao.getTodo(ids.single);
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

  // Banner-dismissal tests removed: dismiss state now lives in the Nudge
  // module's NudgeState (synced-prefs `<prefix>_nudge_dismissed_at`) and is
  // covered by nudge_provider_test.dart's visibility-predicate tests.

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
    });

    test('processInboxItem twice concurrently updates DB only once',
        () async {
      // The re-entrancy guard is routing-agnostic: exercising it through the
      // Next Action path covers the Maybe/Done/WaitingFor paths, which share it.
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      // Fire both without awaiting the first so they race.
      final first = notifier.processInboxItem('item-1', title: 'Test item');
      final second = notifier.processInboxItem('item-1', title: 'Test item');
      await Future.wait([first, second]);

      final state = container.read(focusSessionPlanningProvider);
      expect(state.inboxRoutings[0], equals(RoutingKind.nextAction),
          reason: 'Routing recorded exactly once for index 0');
      expect(state.inboxNav.index, equals(1),
          reason: 'Index advanced exactly once');

      expect(await db.captureDao.outcomeIdsForCapture('item-1'), hasLength(1),
          reason: 'a raced double-tap must not carve two Outcomes');
      final row = (await _outcomeOf(db, 'item-1'))!;
      expect(row.clarified, isTrue);
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

      expect(await _outcomeOf(db, 'item-1'), isNull,
          reason: 'skip must not mint an Outcome');
      expect((await db.captureDao.getCapture('item-1'))!.clarifiedAt, isNull,
          reason: 'skip leaves the Capture in the Inbox');
    });

    test('processInboxItem writes to DB, advances index, and records routing',
        () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();
      await notifier.processInboxItem('item-1', title: 'Test item');

      final state = container.read(focusSessionPlanningProvider);
      expect(state.inboxNav.index, 1);
      expect(state.inboxRoutings[0], equals(RoutingKind.nextAction));

      final row = (await _outcomeOf(db, 'item-1'))!;
      expect(row.clarified, isTrue);
      expect((await db.actionDao.getCurrentAction(row.id))?.actionText,
          'Test item',
          reason: 'the routed title becomes the Outcome next action');
    });

    test('processInboxItemToMaybe writes to DB, advances index, and records routing',
        () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();
      await notifier.processInboxItemToMaybe('item-1');

      final state = container.read(focusSessionPlanningProvider);
      expect(state.inboxNav.index, 1);
      expect(state.inboxRoutings[0], equals(RoutingKind.maybe));

      final row = (await _outcomeOf(db, 'item-1'))!;
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
      expect(state.inboxRoutings[0], equals(RoutingKind.done));

      final row = (await _outcomeOf(db, 'item-1'))!;
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
      final afterBack = (await _outcomeOf(db, 'item-1'))!;
      expect(afterBack.clarified, isTrue,
          reason: 'Back must not revert DB state');
      expect(afterBack.intent, 'maybe');
      var state = container.read(focusSessionPlanningProvider);
      expect(state.inboxRoutings[0], equals(RoutingKind.maybe));

      // Re-tapping a different destination triggers the revert + re-apply.
      await notifier.processInboxItem('item-1', title: 'Test item');

      final row = (await _outcomeOf(db, 'item-1'))!;
      expect(row.clarified, isTrue);
      expect(row.intent, 'next',
          reason: 'revert restored prior intent before re-routing');
      expect(row.doneAt, isNull);
      state = container.read(focusSessionPlanningProvider);
      expect(state.inboxRoutings[0], equals(RoutingKind.nextAction));
    });

    test('revert does not modify the Capture-carried title and notes',
        () async {
      final now = DateTime.now();
      await db.captureDao.insertCapture(CapturesCompanion(
        id: const Value('rich-item'),
        title: const Value('My task'),
        notes: const Value('some notes'),
        userId: const Value('local'),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();
      await notifier.processInboxItem('rich-item', title: 'Test item');
      notifier.previousInboxItem();
      await notifier.processInboxItemToMaybe('rich-item');

      final row = (await _outcomeOf(db, 'rich-item'))!;
      expect(row.title, 'My task');
      expect(row.notes, 'some notes');
      // Energy and time estimate are deliberately absent: they are Outcome
      // attributes a Capture has no column for (ADR-0006). The clarify card
      // supplies them in its draft; this provider-level path carries only
      // what the Capture itself holds.
    });

    test('re-routing Done → Next Action clears done_at', () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      await notifier.processInboxItemToDone('item-1');
      notifier.previousInboxItem();
      await notifier.processInboxItem('item-1', title: 'Test item');

      final row = (await _outcomeOf(db, 'item-1'))!;
      expect(row.doneAt, isNull);
      expect(row.clarified, isTrue);
    });

    test('re-tapping the same destination is a net no-op on routing flags',
        () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      await notifier.processInboxItem('item-1', title: 'Test item');
      final beforeRow = (await _outcomeOf(db, 'item-1'))!;

      notifier.previousInboxItem();
      await notifier.processInboxItem('item-1', title: 'Test item'); // same destination

      final afterRow = (await _outcomeOf(db, 'item-1'))!;

      expect(afterRow.clarified, equals(beforeRow.clarified));
      expect(afterRow.intent, equals(beforeRow.intent));
      expect(afterRow.doneAt, equals(beforeRow.doneAt));

      final state = container.read(focusSessionPlanningProvider);
      expect(state.inboxRoutings[0], equals(RoutingKind.nextAction));
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
        'a person tag hint survives re-routing (no data loss from import/sync)',
        () async {
      // A Nirvana import records a WAITINGFOR person as a Capture tag *hint*
      // (REQUIREMENTS.md), so the delegate must ride through clarification —
      // and through a re-route, which discards the first Outcome and carves a
      // fresh one.
      await _insertInboxItem(db, id: 'item-1');
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('alice'),
        name: Value('Alice'),
        type: Value('person'),
        userId: Value('local'),
      ));
      await db.captureDao.assignTagHint('item-1', 'alice', 'local');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      await notifier.processInboxItemToMaybe('item-1');
      notifier.previousInboxItem();
      await notifier.processInboxItem('item-1', title: 'Test item');

      // Read through the provenance link: the re-route minted a new Outcome,
      // so asserting against the Capture's id would pass without testing
      // anything.
      final outcome = (await _outcomeOf(db, 'item-1'))!;
      final tagIds = await db.todoDao.getPersonTagIdsForTodo(outcome.id);
      expect(tagIds, contains('alice'),
          reason: 'the delegate hint must survive onto the re-routed Outcome');
    });

    test('Waiting For carries the picker\'s delegates onto the new Outcome',
        () async {
      await _insertInboxItem(db, id: 'item-1');
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('bob'),
        name: Value('Bob'),
        type: Value('person'),
        userId: Value('local'),
      ));

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();
      await notifier.processInboxItemToWaitingFor(
        'item-1',
        title: 'Chase the invoice',
        personTagIds: {'bob'},
      );

      // No Outcome exists before this call, so the delegates cannot have been
      // assigned beforehand — routing without them would land the Outcome on
      // Next and never on Waiting For.
      final outcome = (await _outcomeOf(db, 'item-1'))!;
      expect(await db.todoDao.getPersonTagIdsForTodo(outcome.id),
          contains('bob'));
      expect(outcome.intent, 'next');
    });

    test('routing bails out when the snapshot row was deleted before apply',
        () async {
      await _insertInboxItem(db, id: 'item-1');

      final notifier = container.read(focusSessionPlanningProvider.notifier);
      await notifier.loadInboxSnapshot();

      // External delete lands AFTER snapshot load but BEFORE routing
      // (simulates a sync-download removing the row).
      await (db.delete(db.captures)..where((c) => c.id.equals('item-1'))).go();

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
  // Step advancement — no auto-skip, no double-advance (issue #180, Gap 3)
  // ---------------------------------------------------------------------------

  group('FocusSessionPlanningNotifier — step advancement (review step)', () {
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

    test(
        'advanceStep lands on Review Tasks (step 2) with an empty snapshot '
        'when no items need review (steps do not auto-skip, CONTEXT.md '
        '§ Wizard)', () async {
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      await notifier.advanceStep(); // intro (0) → Clarify Inbox (1)
      await notifier.advanceStep(); // Clarify Inbox (1) → Review Tasks (2)

      final state = container.read(focusSessionPlanningProvider);
      expect(state.currentStep, 2,
          reason: 'the step always renders; an empty snapshot shows the '
              'empty-state view and the user clicks Next to advance');
      expect(state.reviewNav.isLoaded, isTrue);
      expect(state.reviewNav.isEmpty, isTrue);
    });

    test('concurrent double-invocation of advanceStep from step 0 advances '
        'exactly one step', () async {
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      final first = notifier.advanceStep();
      final second = notifier.advanceStep();
      await Future.wait([first, second]);

      final state = container.read(focusSessionPlanningProvider);
      expect(state.currentStep, 1,
          reason: 'the re-entrant guard drops the overlapping call');
    });

    test('rapid double-invocation on the synchronous branch advances exactly '
        'one step', () async {
      final notifier = container.read(focusSessionPlanningProvider.notifier);
      notifier.goToStep(2);

      // Two calls in the same synchronous burst — a double-tap.
      final first = notifier.advanceStep();
      final second = notifier.advanceStep();
      await Future.wait([first, second]);

      final state = container.read(focusSessionPlanningProvider);
      expect(state.currentStep, 3,
          reason: 'the re-entrant guard drops the second call of the burst');
    });

    test('sequential awaited advanceStep calls each advance one step',
        () async {
      final notifier = container.read(focusSessionPlanningProvider.notifier);
      notifier.goToStep(2);

      await notifier.advanceStep();
      await notifier.advanceStep();

      final state = container.read(focusSessionPlanningProvider);
      expect(state.currentStep, 4,
          reason: 'intentional sequential advances are not debounced');
    });

    test('advanceStep lands on Review Tasks (step 2) when review items exist',
        () async {
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
        id: const Value('actionless-1'),
        title: const Value('Actionless task'),
        userId: const Value('local'),
        clarified: const Value(true),
        createdAt: Value(now),
        // no Action row seeded → Actionless
      ));
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      await notifier.advanceStep(); // intro (0) → Clarify Inbox (1)
      await notifier.advanceStep(); // Clarify Inbox (1) → Review Tasks (2)

      final state = container.read(focusSessionPlanningProvider);
      expect(state.currentStep, 2,
          reason: 'Review Tasks should not be skipped when items exist');
      expect(state.reviewNav.items, hasLength(1));
      expect(state.reviewNav.index, 0);
    });

    test(
        'Review Tasks (step 2) snapshot excludes an inbox item clarified '
        'with a next action during Clarify Inbox (step 1), but still '
        'surfaces a genuinely actionless task — the snapshot is loaded on '
        'entry into step 2, never earlier', () async {
      final now = DateTime.now();
      // Genuinely needs-review: Actionless (no current Action, no person
      // tag). Never touched during Clarify Inbox — must still surface, so
      // this test cannot pass vacuously.
      await db.into(db.todos).insert(TodosCompanion(
        id: const Value('actionless-1'),
        title: const Value('Actionless task'),
        userId: const Value('local'),
        clarified: const Value(true),
        createdAt: Value(now),
        // no Action row seeded → Actionless
      ));
      // An inbox Capture that, clarified without a next action, would also
      // land in needs-review (Actionless). It is clarified *with* a next
      // action below, during Clarify Inbox — it must never surface here.
      await _insertInboxItem(db, id: 'cap-1', createdAt: now);

      final notifier = container.read(focusSessionPlanningProvider.notifier);

      await notifier.advanceStep(); // intro (0) → Clarify Inbox (1)
      await notifier.loadInboxSnapshot();
      await notifier.processInboxItem('cap-1', title: 'Draft the proposal');
      await notifier.advanceStep(); // Clarify Inbox (1) → Review Tasks (2)

      final state = container.read(focusSessionPlanningProvider);
      expect(state.currentStep, 2);

      final clarifiedOutcome = (await _outcomeOf(db, 'cap-1'))!;
      expect(
          (await db.actionDao.getCurrentAction(clarifiedOutcome.id))?.actionText,
          'Draft the proposal',
          reason: 'sanity check: the capture really was clarified with a '
              'next action before Review Tasks was entered');

      final reviewIds =
          state.reviewNav.items!.map((todo) => todo.id).toSet();
      expect(reviewIds, contains('actionless-1'),
          reason: 'a genuinely actionless task not touched during Clarify '
              'Inbox must still surface in the Review Tasks snapshot');
      expect(reviewIds, isNot(contains(clarifiedOutcome.id)),
          reason: 'an item clarified with a next action during Clarify '
              'Inbox must not appear in the Review Tasks snapshot, which is '
              'taken on entry into that step, not earlier');
    });

    test('advanceStep from Review Tasks (step 2) lands on Energy (step 3)',
        () async {
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
        id: const Value('actionless-2'),
        title: const Value('Actionless task'),
        userId: const Value('local'),
        clarified: const Value(true),
        createdAt: Value(now),
      ));
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      notifier.goToStep(2);
      await notifier.advanceStep(); // from Review Tasks (2) → Energy (3)

      final state = container.read(focusSessionPlanningProvider);
      expect(state.currentStep, 3);
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
        lastClarifiedAt: Value(clarifiedAt),
        lastNextActionCompletionAt: Value(completedAt),
      ));
      // The Action row is the grain the re-clarify predicate reads
      // (ADR-0001 story 3).
      await seedCurrentAction(
        db,
        outcomeId: id,
        text: 'Do the thing',
        userId: userId,
        createdAt: now,
      );
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
        // no Action row seeded → Actionless
      ));
      return id;
    }

    test('confirmReviewItemRelevant: stamps lastClarifiedAt; task leaves the needs-review queue; reviewIndex advances',
        () async {
      final id = await insertStaleTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      expect(
          await db.todoDao.getNeedsReview(), hasLength(1));

      await notifier.confirmReviewItemRelevant(id);

      expect(
          await db.todoDao.getNeedsReview(), isEmpty);
      final state = container.read(focusSessionPlanningProvider);
      expect(state.reviewNav.index, 1);
    });

    test('updateReviewItemNextAction: sets the current Action; stamps lastClarifiedAt; reviewIndex advances',
        () async {
      final id = await insertActionlessTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      expect(
          await db.todoDao.getNeedsReview(), hasLength(1));

      await notifier.updateReviewItemNextAction(id, 'Draft the proposal');

      expect(
          await db.todoDao.getNeedsReview(), isEmpty);

      expect((await db.actionDao.getCurrentAction(id))?.actionText,
          'Draft the proposal');

      final state = container.read(focusSessionPlanningProvider);
      expect(state.reviewNav.index, 1);
    });

    test('markReviewItemDone: task doneAt set; not in result; reviewIndex advances',
        () async {
      final id = await insertStaleTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      await notifier.markReviewItemDone(id);

      expect(
          await db.todoDao.getNeedsReview(), isEmpty);

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
          await db.todoDao.getNeedsReview(), isEmpty);

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
          await db.todoDao.getNeedsReview(), isEmpty);

      final todo = await db.todoDao.getTodo(id);
      expect(todo?.intent, 'trash');

      final state = container.read(focusSessionPlanningProvider);
      expect(state.reviewNav.index, 1);
    });

    test('deferReviewItemToSomeday on actionless task: leaves result; reviewIndex advances',
        () async {
      // intent=maybe is excluded from the review predicate, so the task leaves
      // the queue even when the Outcome is Actionless.
      final id = await insertActionlessTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      await notifier.deferReviewItemToSomeday(id);

      expect(
          await db.todoDao.getNeedsReview(), isEmpty);

      final state = container.read(focusSessionPlanningProvider);
      expect(state.reviewNav.index, 1);
    });

    test('markReviewItemWaitingFor on stale task: task leaves result; reviewIndex advances',
        () async {
      final id = await insertStaleTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      expect(await db.todoDao.getNeedsReview(), hasLength(1));

      await notifier.markReviewItemWaitingFor(id);

      expect(await db.todoDao.getNeedsReview(), isEmpty);

      final state = container.read(focusSessionPlanningProvider);
      expect(state.reviewNav.index, 1);
    });

    test('markReviewItemWaitingFor on actionless task: mints no Action; task remains in needs-review',
        () async {
      // Routing is intent-only; per the orthogonality model, the
      // user-action axis (the current Action) is not touched by a route
      // to waitingFor. An actionless task therefore stays in the
      // re-clarification queue until the dialog records a phrase.
      final id = await insertActionlessTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      expect(await db.todoDao.getNeedsReview(), hasLength(1));

      await notifier.markReviewItemWaitingFor(id);

      expect(await db.actionDao.getCurrentAction(id), isNull,
          reason: 'orthogonality: routing must not mint a current Action');

      final state = container.read(focusSessionPlanningProvider);
      expect(state.reviewNav.index, 1);
    });

    test('updateReviewItemNextAction with blank text: stays in result; reviewIndex does not advance; action record cleared',
        () async {
      // Blank text normalises to NULL → task stays Actionless → not counted as done.
      final id = await insertActionlessTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      // Load review items so the prior-action lookup can resolve the task
      // (intro → Clarify Inbox → Review Tasks).
      await notifier.advanceStep();
      await notifier.advanceStep();
      expect(container.read(focusSessionPlanningProvider).reviewNav.items, hasLength(1));

      // First commit a real action so there's a stale record to clear.
      await notifier.updateReviewItemNextAction(id, 'Draft the proposal');
      expect(container.read(focusSessionPlanningProvider).reviewNav.index, 1);
      notifier.reviewBack();

      // Submit blank — should clear the stale record without advancing.
      await notifier.updateReviewItemNextAction(id, '   ');

      expect(await db.todoDao.getNeedsReview(), isNotEmpty);

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
      await notifier.advanceStep(); // intro (0) → Clarify Inbox (1)
      await notifier.advanceStep(); // Clarify Inbox (1) → Review Tasks (2)
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

      await notifier.advanceStep(); // intro (0) → Clarify Inbox (1)
      await notifier.advanceStep(); // Clarify Inbox (1) → Review Tasks (2)
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

      await notifier.advanceStep(); // intro (0) → Clarify Inbox (1)
      await notifier.advanceStep(); // Clarify Inbox (1) → Review Tasks (2)

      await notifier.trashReviewItem(id);

      notifier.reviewBack();

      await notifier.confirmReviewItemRelevant(id);

      final task = await db.todoDao.getTodo(id);
      expect(task?.intent, 'next',
          reason: 'stamp actions expect an active task; intent must be restored');
      expect(task?.doneAt, isNull);
    });

    test('updateNextAction then back then deferToSomeday: the Action is preserved',
        () async {
      final id = await insertActionlessTask();
      final notifier = container.read(focusSessionPlanningProvider.notifier);

      await notifier.advanceStep(); // intro (0) → Clarify Inbox (1)
      await notifier.advanceStep(); // Clarify Inbox (1) → Review Tasks (2)

      await notifier.updateReviewItemNextAction(id, 'Draft the brief');

      notifier.reviewBack();

      await notifier.deferReviewItemToSomeday(id);

      final task = await db.todoDao.getTodo(id);
      expect(task?.intent, 'maybe');
      expect((await db.actionDao.getCurrentAction(id))?.actionText,
          'Draft the brief',
          reason: 'the current Action must not be reverted going to someday');
    });
  });

  // ---------------------------------------------------------------------------
  // 'rollover' Disposition → next-session pre-selection
  //
  // CONTEXT.md (Engagement, Disposition):
  //   rollover — pre-select this Outcome for the next FocusSession's
  //   Planning (user can deselect there).
  //
  // The build() of FocusSessionPlanningNotifier schedules a microtask that
  // reads the most-recently-closed session's rollover task IDs and prepends
  // them to pendingSelectedTaskIds.
  // ---------------------------------------------------------------------------

  group("FocusSessionPlanningNotifier — 'rollover' pre-selection", () {
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

    Future<void> insertTodo(String id) async {
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Task $id'),
        clarified: const Value(true),
        userId: const Value('local'),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
    }

    test(
        'pendingSelectedTaskIds includes IDs from the most-recently-closed '
        "session's 'rollover' disposition", () async {
      await insertTodo('X');
      await insertTodo('Y');

      // Close a session with X dispositioned 'rollover'; Y dispositioned 'leave'.
      final sid = await db.focusSessionDao.openSession(
        userId: 'local',
        taskIds: ['X', 'Y'],
        now: DateTime(2026, 5, 1, 9, 0),
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sid,
        dispositions: {'X': 'rollover', 'Y': 'leave'},
        now: DateTime(2026, 5, 1, 17, 0),
      );

      // Read the provider — build() schedules the rollover preload via a
      // microtask that awaits a DAO read. Poll for the expected state so we
      // don't assert before the async preload settles.
      container.read(focusSessionPlanningProvider);
      await _settleUntil(() => container
          .read(focusSessionPlanningProvider)
          .pendingSelectedTaskIds
          .contains('X'));

      final state = container.read(focusSessionPlanningProvider);
      expect(state.pendingSelectedTaskIds, contains('X'),
          reason:
              "rollover-dispositioned Outcomes pre-select for the next session's Planning.");
      expect(state.pendingSelectedTaskIds, isNot(contains('Y')),
          reason: 'leave-dispositioned Outcomes do not pre-select.');
    });

    test(
        'pendingSelectedTaskIds is empty when the prior session had no '
        'rollover dispositions', () async {
      await insertTodo('Y');
      final sid = await db.focusSessionDao.openSession(
        userId: 'local',
        taskIds: ['Y'],
        now: DateTime(2026, 5, 1, 9, 0),
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sid,
        dispositions: {'Y': 'leave'},
        now: DateTime(2026, 5, 1, 17, 0),
      );

      // Empty is also the initial state, so there's no positive signal to poll
      // for; drain the event queue fully to let the preload run, then assert.
      container.read(focusSessionPlanningProvider);
      await pumpEventQueue();

      final state = container.read(focusSessionPlanningProvider);
      expect(state.pendingSelectedTaskIds, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Rollover pre-selection is recomputed on every planning ENTRY, not once per
  // notifier build (#461).
  //
  // build()'s microtask fires once per process. Every in-process replan path —
  // the sequenced Shutdown → Planning gate (reEnterPlanning) and a warm-process
  // return to the planning screen (mount hook) — bypassed it, so carried-over
  // tasks arrived unselected. ensureRolloverPreload() closes the gap: idempotent,
  // skipped while a session is open, and its merge respects both the pending and
  // the reviewed lists so a deselected task is never resurrected.
  // ---------------------------------------------------------------------------

  group("FocusSessionPlanningNotifier — rollover preload on replan", () {
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

    Future<void> insertTodo(String id) async {
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Task $id'),
        clarified: const Value(true),
        userId: const Value('local'),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
    }

    test(
        'reEnterPlanning pre-selects the just-closed session\'s rollover tasks '
        '(same-process replan — primary repro)', () async {
      await insertTodo('A');
      await insertTodo('B');

      // Open a session (A, B). build()'s preload skips while it is open.
      final sid = await db.focusSessionDao.openSession(
        userId: 'local',
        taskIds: ['A', 'B'],
        now: DateTime(2026, 5, 1, 9, 0),
      );
      container.read(focusSessionPlanningProvider);
      await pumpEventQueue();
      expect(
        container.read(focusSessionPlanningProvider).pendingSelectedTaskIds,
        isEmpty,
        reason: 'no rollover preload while a session is open',
      );

      // Close it with A rollover, B leave — the sequenced-gate close.
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sid,
        dispositions: {'A': 'rollover', 'B': 'leave'},
        now: DateTime(2026, 5, 1, 17, 0),
      );

      // The in-process replan path. build() will NOT run again this process.
      await container
          .read(focusSessionPlanningProvider.notifier)
          .reEnterPlanning();

      final state = container.read(focusSessionPlanningProvider);
      expect(state.pendingSelectedTaskIds, contains('A'),
          reason:
              'carried-over tasks arrive pre-selected on the in-process replan (AC1).');
      expect(state.pendingSelectedTaskIds, isNot(contains('B')),
          reason: 'leave-dispositioned tasks do not pre-select.');
    });

    test(
        'a cold start with a session open does not preload a prior period\'s '
        'rollovers; the next replan preloads the correct session', () async {
      await insertTodo('X');
      await insertTodo('Y');
      await insertTodo('Z');

      // Period 1: close a session carrying X over.
      final s1 = await db.focusSessionDao.openSession(
        userId: 'local',
        taskIds: ['X'],
        now: DateTime(2026, 5, 1, 9, 0),
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: s1,
        dispositions: {'X': 'rollover'},
        now: DateTime(2026, 5, 1, 17, 0),
      );
      // Period 2: a session is now open (the plan built from X already consumed
      // that rollover; Y is a fresh member of this plan).
      final s2 = await db.focusSessionDao.openSession(
        userId: 'local',
        taskIds: ['X', 'Y', 'Z'],
        now: DateTime(2026, 5, 2, 9, 0),
      );

      // Fresh cold start while s2 is open: build()'s preload must NOT drag X's
      // stale rollover into the draft.
      container.read(focusSessionPlanningProvider);
      await pumpEventQueue();
      expect(
        container.read(focusSessionPlanningProvider).pendingSelectedTaskIds,
        isEmpty,
        reason: 'the skip-while-open guard prevents a stale preload.',
      );

      // Close s2 carrying Y over; the replan preloads s2 (Y), not s1 (X).
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: s2,
        dispositions: {'X': 'leave', 'Z': 'leave', 'Y': 'rollover'},
        now: DateTime(2026, 5, 2, 17, 0),
      );
      await container
          .read(focusSessionPlanningProvider.notifier)
          .reEnterPlanning();

      final state = container.read(focusSessionPlanningProvider);
      expect(state.pendingSelectedTaskIds, ['Y'],
          reason: 'only the most-recently-closed session\'s rollovers preload.');
    });

    test(
        'ensureRolloverPreload is idempotent and respects the reviewed list '
        '(warm-process mount hook + deselect + undo)', () async {
      await insertTodo('A');

      // build() runs while there is no closed session → empty preload.
      final notifier =
          container.read(focusSessionPlanningProvider.notifier);
      await pumpEventQueue();
      expect(
        container.read(focusSessionPlanningProvider).pendingSelectedTaskIds,
        isEmpty,
      );

      // A session closes carrying A over — WITHOUT routing through
      // reEnterPlanning (the warm-process return-to-screen case).
      final sid = await db.focusSessionDao.openSession(
        userId: 'local',
        taskIds: ['A'],
        now: DateTime(2026, 5, 1, 9, 0),
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sid,
        dispositions: {'A': 'rollover'},
        now: DateTime(2026, 5, 1, 17, 0),
      );

      // The mount hook fires ensureRolloverPreload() directly.
      await notifier.ensureRolloverPreload();
      expect(
        container.read(focusSessionPlanningProvider).pendingSelectedTaskIds,
        ['A'],
        reason: 'the mount hook pre-selects the rollover on a warm process.',
      );

      // Idempotent — a repeated call adds no duplicate.
      await notifier.ensureRolloverPreload();
      expect(
        container.read(focusSessionPlanningProvider).pendingSelectedTaskIds,
        ['A'],
      );

      // Deselect A (skipTask records it as reviewed). A later preload must not
      // resurrect a task the user deliberately skipped.
      notifier.skipTask('A');
      expect(
        container.read(focusSessionPlanningProvider).pendingSelectedTaskIds,
        isNot(contains('A')),
      );
      await notifier.ensureRolloverPreload();
      expect(
        container.read(focusSessionPlanningProvider).pendingSelectedTaskIds,
        isNot(contains('A')),
        reason: 'the reviewed-ids merge guard keeps a skipped task out (AC2).',
      );

      // Undo the review: undoTaskReview clears A from BOTH lists, returning it
      // to the unreviewed pool. A subsequent preload then legitimately restores
      // it as the rollover default — the intended default-restoration edge.
      notifier.undoTaskReview('A');
      await notifier.ensureRolloverPreload();
      expect(
        container.read(focusSessionPlanningProvider).pendingSelectedTaskIds,
        ['A'],
        reason:
            'undoTaskReview returns A to the unreviewed pool, so the rollover '
            'default is restored on the next preload.',
      );
    });

    test(
        'cold start with no open session preloads the last closed session\'s '
        'rollover (characterization — works-case pinned)', () async {
      await insertTodo('X');
      final sid = await db.focusSessionDao.openSession(
        userId: 'local',
        taskIds: ['X'],
        now: DateTime(2026, 5, 1, 9, 0),
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sid,
        dispositions: {'X': 'rollover'},
        now: DateTime(2026, 5, 1, 17, 0),
      );

      // Fresh container, no open session: build()'s microtask preloads X.
      container.read(focusSessionPlanningProvider);
      await _settleUntil(() => container
          .read(focusSessionPlanningProvider)
          .pendingSelectedTaskIds
          .contains('X'));

      expect(
        container.read(focusSessionPlanningProvider).pendingSelectedTaskIds,
        contains('X'),
      );
    });

    test(
        'overlapping ensureRolloverPreload calls pre-select each rollover '
        'exactly once', () async {
      await insertTodo('A');
      final sid = await db.focusSessionDao.openSession(
        userId: 'local',
        taskIds: ['A'],
        now: DateTime(2026, 5, 1, 9, 0),
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sid,
        dispositions: {'A': 'rollover'},
        now: DateTime(2026, 5, 1, 17, 0),
      );

      // The real overlap: reading the notifier schedules build()'s microtask
      // preload, and the planning screen's mount hook fires its own
      // ensureRolloverPreload() without awaiting. Fire both explicit calls
      // unawaited so all three interleave over the async DAO reads.
      final notifier = container.read(focusSessionPlanningProvider.notifier);
      final first = notifier.ensureRolloverPreload();
      final second = notifier.ensureRolloverPreload();
      await Future.wait([first, second]);
      // Let build()'s microtask preload land too.
      await _settleUntil(() => container
          .read(focusSessionPlanningProvider)
          .pendingSelectedTaskIds
          .contains('A'));

      expect(
        container.read(focusSessionPlanningProvider).pendingSelectedTaskIds,
        ['A'],
        reason:
            'the merge reads pendingSelectedTaskIds and commits in the same '
            'synchronous run after the last await, so overlapping preloads '
            'cannot double-insert a rollover id.',
      );
    });
  });
}
