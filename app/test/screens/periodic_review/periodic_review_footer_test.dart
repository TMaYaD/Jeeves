/// Widget tests for the Weekly Review wizard footer (#292).
///
/// The footer renders exactly one forward affordance at a time: a secondary
/// **Skip** while the step's item cursor still has items to consume, swapping
/// to a primary **Next step** once the cursor is spent. These tests drive the
/// real [PeriodicReviewNotifier] against an in-memory [GtdDatabase] so the
/// snapshot plumbing and step rendering exercise the production path.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/periodic_review_provider.dart';
import 'package:jeeves/screens/periodic_review/periodic_review_screen.dart';
import 'package:jeeves/services/notification_service.dart';

import '../../helpers/periodic_review_test_helpers.dart';
import '../../test_helpers.dart';

const _skipKey = Key('periodic_review_skip');
const _nextKey = Key('periodic_review_next_step');

/// An Inbox item is a Capture with `clarified_at IS NULL` (ADR-0006).
Future<void> _insertInbox(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.captureDao.insertCapture(CapturesCompanion(
    id: Value(id),
    title: Value('Inbox item $id'),
    userId: const Value('local'),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
}

/// Inserts a clarified next-action delegated to a person — i.e. a row that
/// surfaces in the Waiting For step's snapshot.
Future<void> _insertWaitingFor(
  GtdDatabase db,
  String id, {
  required String personTagId,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Delegated $id'),
        clarified: const Value(true),
        intent: const Value('next'),
        userId: const Value('local'),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  await db.tagDao.upsertTag(TagsCompanion(
    id: Value(personTagId),
    name: Value(personTagId),
    type: const Value('person'),
    userId: const Value('local'),
  ));
  await db.tagDao.assignTag(id, personTagId, 'local');
}

Widget _screen(GtdDatabase db) => ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider
            .overrideWithValue(StubPeriodicReviewNotificationService()),
      ],
      child: const MaterialApp(home: PeriodicReviewScreen()),
    );

PeriodicReviewState _stateOf(WidgetTester tester) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(PeriodicReviewScreen)),
  );
  return container.read(periodicReviewProvider);
}

/// The wizard loads its per-step snapshots through drift watch-streams, which
/// only emit inside the real async zone. Give them a turn under
/// [WidgetTester.runAsync] before settling the frame.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pumpAndSettle();
}

/// Unmounts the screen so the streaming providers behind the review cards
/// dispose — and their drift stream-close timers fire — before the test
/// framework's end-of-test pending-timer invariant check runs.
Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Weekly Review footer — Skip / Next step', () {
    late GtdDatabase db;

    setUp(() => db = GtdDatabase(NativeDatabase.memory()));
    tearDown(() async => db.close());

    testWidgets(
        'Inbox step on the last real item shows Skip; '
        'Next step appears only on the completion placeholder',
        (tester) async {
      await _insertInbox(db, 'only');

      await tester.pumpWidget(_screen(db));
      await _settle(tester);

      // Single item: cursor is on the only real item — footer shows Skip,
      // not Next step. "Next step" appears only after all items are processed.
      expect(find.byKey(_skipKey), findsOneWidget);
      expect(find.byKey(_nextKey), findsNothing);
      expect(
        tester.widget<OutlinedButton>(find.byKey(_skipKey)).onPressed,
        isNotNull,
      );

      await tester.tap(find.byKey(_skipKey));
      await tester.pumpAndSettle();

      // Cursor is now past the end (isComplete) — step body shows completion
      // placeholder and footer swaps to Next step.
      expect(_stateOf(tester).inboxNav.isComplete, isTrue);
      expect(find.byKey(_nextKey), findsOneWidget);
      expect(find.byKey(_skipKey), findsNothing);
      expect(find.text('Next step'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(_nextKey)).onPressed,
        isNotNull,
      );

      await _dispose(tester);
    });

    testWidgets('tapping Skip advances the inbox cursor; '
        'Next step appears only once isComplete', (tester) async {
      await _insertInbox(db, 'i1');
      await _insertInbox(db, 'i2');

      await tester.pumpWidget(_screen(db));
      await _settle(tester);

      expect(_stateOf(tester).inboxNav.index, 0);
      // Cursor on item 0 with items remaining — Skip is the only forward
      // affordance, and it is enabled.
      expect(find.byKey(_skipKey), findsOneWidget);
      expect(find.byKey(_nextKey), findsNothing);
      expect(
        tester.widget<OutlinedButton>(find.byKey(_skipKey)).onPressed,
        isNotNull,
      );

      await tester.tap(find.byKey(_skipKey));
      await tester.pumpAndSettle();

      // Cursor is on the last real item (index=1) — Skip still shows,
      // not Next step. The DPR contract: "Next step" only after isComplete.
      expect(_stateOf(tester).inboxNav.index, 1);
      expect(find.byKey(_skipKey), findsOneWidget);
      expect(find.byKey(_nextKey), findsNothing);

      await tester.tap(find.byKey(_skipKey));
      await tester.pumpAndSettle();

      // Cursor is now past the end (isComplete) — footer swaps to Next step.
      expect(_stateOf(tester).inboxNav.isComplete, isTrue);
      expect(find.byKey(_nextKey), findsOneWidget);
      expect(find.byKey(_skipKey), findsNothing);

      await _dispose(tester);
    });

    testWidgets(
        'tapping Skip on the Waiting For step advances waitingForNav and '
        'leaves the item in the snapshot', (tester) async {
      // Two delegated tasks populate the Waiting For snapshot.
      await _insertWaitingFor(db, 'wf1', personTagId: 'alice');
      await _insertWaitingFor(db, 'wf2', personTagId: 'bob');

      await tester.pumpWidget(_screen(db));
      await _settle(tester);

      // Drive into the Waiting For step explicitly via the notifier so the
      // test controls step position deterministically.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PeriodicReviewScreen)),
      );
      await tester.runAsync(
        () => container
            .read(periodicReviewProvider.notifier)
            .goToStep(PeriodicReviewNotifier.kStepWaitingFor),
      );
      await tester.pumpAndSettle();

      final before = _stateOf(tester);
      expect(before.currentStep, PeriodicReviewNotifier.kStepWaitingFor);
      expect(before.waitingForNav.index, 0);
      expect(before.waitingForNav.length, 2);
      expect(find.byKey(_skipKey), findsOneWidget);

      await tester.tap(find.byKey(_skipKey));
      await tester.pumpAndSettle();

      final after = _stateOf(tester);
      // Skip is pure cursor navigation: the snapshot is untouched, only the
      // index moved forward — routing semantics preserved.
      expect(after.currentStep, PeriodicReviewNotifier.kStepWaitingFor);
      expect(after.waitingForNav.index, 1);
      expect(
        after.waitingForNav.items!.map((t) => t.id).toList(),
        before.waitingForNav.items!.map((t) => t.id).toList(),
      );

      await _dispose(tester);
    });
  });
}
