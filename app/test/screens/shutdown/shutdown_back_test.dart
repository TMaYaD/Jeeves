/// Widget tests for the ceremony back-navigation contract on Evening
/// Shutdown (issue #180, Gap 2). Shares the contract pinned in detail by
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
import 'package:jeeves/providers/evening_shutdown_provider.dart';
import 'package:jeeves/screens/shutdown/shutdown_ritual_screen.dart';

import '../../test_helpers.dart';

const _userId = 'local';

Future<void> _insertTodo(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
    id: Value(id),
    title: Value('Task $id'),
    clarified: const Value(true),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
}

(Widget, ProviderContainer) _app(GtdDatabase db) {
  final container = ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(db)],
  );
  final router = GoRouter(
    initialLocation: '/shutdown',
    routes: [
      GoRoute(
        path: '/focus',
        builder: (_, _) => const Scaffold(body: Text('execution home')),
      ),
      GoRoute(
        path: '/shutdown',
        builder: (_, _) => const ShutdownRitualScreen(),
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

  group('Evening Shutdown — system back contract', () {
    late GtdDatabase db;

    setUp(() => db = GtdDatabase(NativeDatabase.memory()));
    tearDown(() async => db.close());

    testWidgets(
        'system back on the first step exits to the execution home and '
        'abandons the performance', (tester) async {
      // An open session with an unfinished task keeps step 1 from
      // auto-advancing later; step 0 renders regardless.
      await _insertTodo(db, 't1');
      await db.focusSessionDao.openSession(userId: _userId, taskIds: ['t1']);

      final (widget, container) = _app(db);
      addTearDown(container.dispose);
      await tester.pumpWidget(widget);
      await _settle(tester);

      expect(
        container.read(ceremonyInProgressProvider),
        contains(RitualId.eveningShutdown),
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('execution home'), findsOneWidget);
      expect(
        container.read(ceremonyInProgressProvider),
        isNot(contains(RitualId.eveningShutdown)),
        reason: 'back-exit abandons the performance (ADR-0009 hygiene)',
      );

      await _dispose(tester);
    });

    testWidgets(
        'system back on Resolve Unfinished at the first item retreats to '
        'step 0, mirroring the footer Back', (tester) async {
      await _insertTodo(db, 't1');
      await db.focusSessionDao.openSession(userId: _userId, taskIds: ['t1']);

      final (widget, container) = _app(db);
      addTearDown(container.dispose);
      await tester.pumpWidget(widget);
      await _settle(tester);

      container.read(eveningShutdownProvider.notifier).goToStep(1);
      await _settle(tester);
      expect(container.read(eveningShutdownProvider).currentStep, 1);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(container.read(eveningShutdownProvider).currentStep, 0,
          reason: 'system back mirrors the BackOnlyFooter step retreat');
      expect(find.byType(ShutdownRitualScreen), findsOneWidget,
          reason: 'the ceremony stays open — no route change');

      await _dispose(tester);
    });

    testWidgets(
        'system back on Resolve Unfinished mid-list retreats the item '
        'cursor and stays on step 1', (tester) async {
      await _insertTodo(db, 't1');
      await _insertTodo(db, 't2');
      await db.focusSessionDao
          .openSession(userId: _userId, taskIds: ['t1', 't2']);

      final (widget, container) = _app(db);
      addTearDown(container.dispose);
      await tester.pumpWidget(widget);
      await _settle(tester);

      final notifier = container.read(eveningShutdownProvider.notifier);
      notifier.goToStep(1);
      await _settle(tester);
      notifier.nextUnfinishedTask();
      await tester.pumpAndSettle();

      expect(container.read(eveningShutdownProvider).unfinishedNav.index, 1);
      expect(
        container.read(eveningShutdownProvider).unfinishedNav.canGoBack,
        isTrue,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      final state = container.read(eveningShutdownProvider);
      expect(state.unfinishedNav.index, 0,
          reason: 'system back retreats the per-item cursor like footer Back');
      expect(state.currentStep, 1,
          reason: 'no step change while the cursor can retreat');
      expect(find.byType(ShutdownRitualScreen), findsOneWidget);

      await _dispose(tester);
    });
  });
}
