/// Widget tests for the Daily Planning Ritual footer (#292).
///
/// The footer renders exactly one forward affordance at a time: a secondary
/// **Skip** while the step's item cursor still has items to consume, swapping
/// to a primary **Next step** once the cursor is spent (or the step has no
/// per-item cursor). These tests drive the real [FocusSessionPlanningNotifier]
/// against an in-memory [GtdDatabase] so the snapshot plumbing and step
/// rendering exercise the production path.
///
/// Note on thresholds: DPR's Skip↔Next-step boundary is the screen's existing
/// skip↔advanceStep boundary — `!inboxNav.isComplete`. On the last *real*
/// inbox item the footer still shows Skip; Next step appears only once the
/// cursor has moved past the end. That DPR-vs-Weekly-Review threshold
/// difference is a known, orthogonal inconsistency, out of scope for #292;
/// these tests assert DPR's actual behaviour.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/planning/focus_session_planning_screen.dart';

import '../../test_helpers.dart';

const _skipKey = Key('planning_skip');
const _nextKey = Key('planning_next_step');
const _slotKey = Key('planning_footer_slot');

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

Widget _screen(GtdDatabase db) => ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: FocusSessionPlanningScreen()),
    );

FocusSessionPlanningState _stateOf(WidgetTester tester) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(FocusSessionPlanningScreen)),
  );
  return container.read(focusSessionPlanningProvider);
}

/// The ritual loads its inbox snapshot through a drift watch-stream, which
/// only emits inside the real async zone. Give it a turn under
/// [WidgetTester.runAsync] before settling the frame.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pumpAndSettle();
}

/// Unmounts the screen so the streaming providers behind the step cards
/// dispose — and their drift stream-close timers fire — before the test
/// framework's end-of-test pending-timer invariant check runs.
Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Daily Planning footer — Skip / Next step', () {
    late GtdDatabase db;

    setUp(() => db = GtdDatabase(NativeDatabase.memory()));
    tearDown(() async {
      await db.close();
      focusSessionPlanningCompletionNotifier.value = false;
      focusSessionPlanningBannerDismissedNotifier.value = false;
    });

    testWidgets('Inbox step with items remaining shows Skip, not Next step',
        (tester) async {
      await _insertInbox(db, 'i1');
      await _insertInbox(db, 'i2');

      await tester.pumpWidget(_screen(db));
      await _settle(tester);

      expect(_stateOf(tester).currentStep, 0);
      expect(find.byKey(_skipKey), findsOneWidget);
      expect(find.byKey(_nextKey), findsNothing);
      expect(
        tester.widget<OutlinedButton>(find.byKey(_skipKey)).onPressed,
        isNotNull,
      );

      await _dispose(tester);
    });

    testWidgets(
        'Inbox step shows Next step once the cursor passes the last item',
        (tester) async {
      await _insertInbox(db, 'only');

      await tester.pumpWidget(_screen(db));
      await _settle(tester);

      // DPR threshold: on the last real item the footer still shows Skip.
      expect(find.byKey(_skipKey), findsOneWidget);

      await tester.tap(find.byKey(_skipKey));
      await tester.pumpAndSettle();

      // Cursor is now past the end (isComplete) — footer swaps to Next step.
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

    testWidgets('Step 0 shows a disabled Next step while the inbox is loading',
        (tester) async {
      await _insertInbox(db, 'i1');

      // First frame only — the inbox snapshot has not loaded yet, so the
      // footer shows a disabled Next step (the sole loading state).
      await tester.pumpWidget(_screen(db));

      expect(_stateOf(tester).inboxNav.isLoaded, isFalse);
      expect(find.byKey(_nextKey), findsOneWidget);
      expect(find.byKey(_skipKey), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byKey(_nextKey)).onPressed,
        isNull,
      );

      await _settle(tester);
      await _dispose(tester);
    });

    testWidgets(
        'a step with no per-item cursor shows an enabled Next step',
        (tester) async {
      // Empty inbox auto-advances out of Step 0; with nothing to review the
      // ritual lands on the Energy step (Step 2), which has no per-item cursor.
      await tester.pumpWidget(_screen(db));
      await _settle(tester);

      expect(_stateOf(tester).currentStep, 2);
      expect(find.byKey(_nextKey), findsOneWidget);
      expect(find.byKey(_skipKey), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byKey(_nextKey)).onPressed,
        isNotNull,
      );

      // Crossing into the Time step (also no per-item cursor) still shows
      // Next step — never Skip.
      await tester.tap(find.byKey(_nextKey));
      await tester.pumpAndSettle();

      expect(_stateOf(tester).currentStep, 3);
      expect(find.byKey(_nextKey), findsOneWidget);
      expect(find.byKey(_skipKey), findsNothing);

      await _dispose(tester);
    });

    testWidgets('the footer slot keeps a fixed footprint across the swap',
        (tester) async {
      await _insertInbox(db, 'only');

      await tester.pumpWidget(_screen(db));
      await _settle(tester);

      // Skip is showing.
      final skipSlotSize = tester.getSize(find.byKey(_slotKey));

      await tester.tap(find.byKey(_skipKey));
      await tester.pumpAndSettle();

      // Next step is showing — the OutlinedButton ↔ FilledButton swap must not
      // change the slot's size.
      final nextSlotSize = tester.getSize(find.byKey(_slotKey));
      expect(nextSlotSize, skipSlotSize);

      await _dispose(tester);
    });
  });
}
