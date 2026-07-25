/// Screen tests for the Weekly Review duration-estimate intro (#486).
///
/// The intro is step 0 of the wizard, excluded from the progress count. Its
/// estimate is `2 min × (inbox + waiting-for + next + someday counts)` — no
/// flat add — rounded up to the nearest 5 and floored at 5, sourced from the
/// four navs the mount preloads via loadAllSnapshots.
library;

import 'package:drift/drift.dart' show Value;
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
import '../../helpers/settle.dart';
import '../../test_helpers.dart';

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

Future<void> _settle(WidgetTester tester) => settleWithRealAsync(tester);

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Weekly Review intro (#486)', () {
    late GtdDatabase db;
    setUp(() => db = GtdDatabase(NativeDatabase.memory()));
    tearDown(() async => db.close());

    testWidgets('opens on the intro with the neutral "Before we begin" title '
        'and no Skip', (tester) async {
      await _insertInbox(db, 'i1');
      await tester.pumpWidget(_screen(db));
      await _settle(tester);

      expect(_stateOf(tester).currentStep,
          PeriodicReviewNotifier.kStepIntro);
      expect(find.text('Before we begin'), findsOneWidget);
      expect(find.byKey(const Key('periodic_review_skip')), findsNothing);
      // Progress narration is suppressed on the intro (not a numbered step).
      expect(find.textContaining('Step 1 of 4'), findsNothing);

      await _dispose(tester);
    });

    testWidgets('estimate reflects 2×(sum of the four navs), no flat, '
        'rounded up to 5', (tester) async {
      // 3 inbox items, all other lists empty → raw 2×3 = 6 → rounds up to 10.
      await _insertInbox(db, 'i1');
      await _insertInbox(db, 'i2');
      await _insertInbox(db, 'i3');

      await tester.pumpWidget(_screen(db));
      await _settle(tester);

      expect(find.textContaining('about 10 minutes'), findsOneWidget);

      await _dispose(tester);
    });

    testWidgets('all-zero shows the light-day floor "about 5 minutes", '
        'never "0"', (tester) async {
      await tester.pumpWidget(_screen(db));
      await _settle(tester);

      expect(find.textContaining('about 5 minutes'), findsOneWidget);
      expect(find.textContaining('0 minutes'), findsNothing);

      await _dispose(tester);
    });

    testWidgets('proceeding from the intro lands on Process Inbox (Step 1 of 4)',
        (tester) async {
      await _insertInbox(db, 'i1');
      await tester.pumpWidget(_screen(db));
      await _settle(tester);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(PeriodicReviewScreen)),
      );
      await container
          .read(periodicReviewProvider.notifier)
          .advanceStep();
      await tester.pumpAndSettle();

      expect(_stateOf(tester).currentStep,
          PeriodicReviewNotifier.kStepInbox);
      expect(find.text('Process Inbox'), findsOneWidget);
      expect(find.textContaining('Step 1 of 4'), findsOneWidget);

      await _dispose(tester);
    });
  });
}
