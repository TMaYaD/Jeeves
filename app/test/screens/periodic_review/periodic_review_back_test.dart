/// Widget tests for the ceremony back-navigation contract on the Weekly
/// Review (issue #180, Gap 2). Shares the contract pinned in detail by
/// `focus_session_planning_back_test.dart`: system back mirrors the footer
/// Back affordance; when Back is unavailable it exits to the execution home
/// screen (`/focus`).
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/ceremony_in_progress_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/periodic_review_provider.dart';
import 'package:jeeves/screens/periodic_review/periodic_review_screen.dart';

import '../../test_helpers.dart';

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

(Widget, ProviderContainer) _app(GtdDatabase db) {
  final container = ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(db)],
  );
  final router = GoRouter(
    initialLocation: '/periodic-review',
    routes: [
      GoRoute(
        path: '/focus',
        builder: (_, _) => const Scaffold(body: Text('execution home')),
      ),
      GoRoute(
        path: '/periodic-review',
        builder: (_, _) => const PeriodicReviewScreen(),
      ),
    ],
  );
  final widget = UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  );
  return (widget, container);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pumpAndSettle();
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Weekly Review — system back contract', () {
    late GtdDatabase db;

    setUp(() => db = GtdDatabase(NativeDatabase.memory()));
    tearDown(() async => db.close());

    testWidgets(
        'system back at step 0, first item exits to the execution home and '
        'abandons the performance', (tester) async {
      final (widget, container) = _app(db);
      addTearDown(container.dispose);
      await tester.pumpWidget(widget);
      await _settle(tester);

      expect(
        container.read(ceremonyInProgressProvider),
        contains(RitualId.weeklyReview),
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('execution home'), findsOneWidget);
      expect(
        container.read(ceremonyInProgressProvider),
        isNot(contains(RitualId.weeklyReview)),
        reason: 'back-exit abandons the performance (ADR-0009 hygiene)',
      );

      await _dispose(tester);
    });

    testWidgets(
        'system back mid-step mirrors footer Back: retreats the item cursor '
        'and keeps the step', (tester) async {
      await _insertInbox(db, 'i1');
      await _insertInbox(db, 'i2');
      final (widget, container) = _app(db);
      addTearDown(container.dispose);
      await tester.pumpWidget(widget);
      await _settle(tester);

      final notifier = container.read(periodicReviewProvider.notifier);
      notifier.advanceInbox();
      await tester.pumpAndSettle();
      expect(container.read(periodicReviewProvider).inboxNav.index, 1);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      final state = container.read(periodicReviewProvider);
      expect(state.inboxNav.index, 0,
          reason: 'system back retreats the per-item cursor like footer Back');
      expect(state.currentStep, 0,
          reason: 'no step change while the cursor can retreat');
      expect(find.byType(PeriodicReviewScreen), findsOneWidget,
          reason: 'the ceremony stays open — no route change');
      expect(
        container.read(ceremonyInProgressProvider),
        contains(RitualId.weeklyReview),
        reason: 'the performance stays in progress while inside the wizard',
      );

      await _dispose(tester);
    });

    testWidgets('system back on a later step retreats to the previous step',
        (tester) async {
      final (widget, container) = _app(db);
      addTearDown(container.dispose);
      await tester.pumpWidget(widget);
      await _settle(tester);

      await container.read(periodicReviewProvider.notifier).goToStep(1);
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(container.read(periodicReviewProvider).currentStep, 0,
          reason: 'system back mirrors the footer Back step retreat');
      expect(find.byType(PeriodicReviewScreen), findsOneWidget);

      await _dispose(tester);
    });

    testWidgets(
        'system back on the Review Complete summary exits to the execution home',
        (tester) async {
      final (widget, container) = _app(db);
      addTearDown(container.dispose);
      await tester.pumpWidget(widget);
      await _settle(tester);

      await container.read(periodicReviewProvider.notifier).goToStep(4);
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('execution home'), findsOneWidget);

      await _dispose(tester);
    });
  });
}
