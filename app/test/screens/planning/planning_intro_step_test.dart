/// Screen tests for the Daily Planning duration-estimate intro (#486).
///
/// The intro is step 0 of the wizard, excluded from the progress count. Its
/// estimate is `2 min × (inbox + needs-review counts) + 5`, rounded up to the
/// nearest 5 and floored at 5, sourced from
/// [focusSessionPlanningIntroCountsProvider] (count-only reads).
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/planning/focus_session_planning_screen.dart';

import '../../helpers/settle.dart';
import '../../test_helpers.dart';

const _nextKey = Key('planning_next_step');

Future<void> _insertInbox(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.captureDao.insertCapture(CapturesCompanion(
    id: Value(id),
    title: Value('Inbox $id'),
    userId: const Value('local'),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
}

/// A clarified, actionless task — surfaces in the needs-review snapshot.
Future<void> _insertNeedsReview(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Review $id'),
        userId: const Value('local'),
        clarified: const Value(true),
        createdAt: Value(now),
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

Future<void> _settle(WidgetTester tester) => settleWithRealAsync(tester);

/// Drives the transition into Clarify Inbox in real time while draining its
/// lazy snapshot load — a plain pumpAndSettle would hang on the spinner.
Future<void> _settleAcrossTransition(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Daily Planning intro (#486)', () {
    late GtdDatabase db;
    setUp(() => db = GtdDatabase(NativeDatabase.memory()));
    tearDown(() async => db.close());

    testWidgets('opens on the intro with the neutral "Before we begin" title '
        'and no Skip', (tester) async {
      await _insertInbox(db, 'i1');
      await tester.pumpWidget(_screen(db));
      await _settle(tester);

      expect(_stateOf(tester).currentStep, 0);
      expect(find.text('Before we begin'), findsOneWidget);
      expect(find.byKey(const Key('planning_skip')), findsNothing);
      // Progress narration is suppressed on the intro (not a numbered step).
      expect(find.textContaining('Step 1 of 5'), findsNothing);

      await _dispose(tester);
    });

    testWidgets('estimate reflects 2×(inbox + review) + 5, rounded up to 5',
        (tester) async {
      // 2 inbox + 1 review → raw 2×3 + 5 = 11 → rounds up to 15.
      await _insertInbox(db, 'i1');
      await _insertInbox(db, 'i2');
      await _insertNeedsReview(db, 'r1');

      await tester.pumpWidget(_screen(db));
      await _settle(tester);

      expect(find.textContaining('about 15 minutes'), findsOneWidget);

      await _dispose(tester);
    });

    testWidgets('zero items shows the light-day floor "about 5 minutes", '
        'never "0"', (tester) async {
      await tester.pumpWidget(_screen(db));
      await _settle(tester);

      expect(find.textContaining('about 5 minutes'), findsOneWidget);
      expect(find.textContaining('0 minutes'), findsNothing);

      await _dispose(tester);
    });

    testWidgets('proceeding from the intro lands on Clarify Inbox (step 1)',
        (tester) async {
      await _insertInbox(db, 'i1');
      await tester.pumpWidget(_screen(db));
      await _settle(tester);

      await tester.tap(find.byKey(_nextKey));
      await _settleAcrossTransition(tester);

      expect(_stateOf(tester).currentStep, 1);
      expect(find.text('Clarify Inbox'), findsOneWidget);
      expect(find.text('Step 1 of 5 · 0 / 1 processed (skipped 0)'),
          findsOneWidget);

      await _dispose(tester);
    });
  });
}
