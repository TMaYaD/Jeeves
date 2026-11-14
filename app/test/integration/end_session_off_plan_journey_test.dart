/// "End Session" must not close past an unfinished off-Plan Outcome (#885).
///
/// The Now screen offers the direct close only when every Outcome on the
/// session's Review surface (the Plan plus anything engaged during the session)
/// has its Completion recorded. Otherwise the footer opens Evening Shutdown so
/// the Outcome gets a Disposition. Everything runs through the real Now screen
/// over a real in-memory store; only the database and the notification service
/// are overridden. Off-Plan engagement is staged through the production seam
/// (`setCurrentTask`), Completion through `completeOutcome`.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/focus_screen.dart';
import 'package:jeeves/services/clarification_service.dart';
import 'package:jeeves/services/notification_service.dart';

import '../helpers/settle.dart';
import '../test_helpers.dart';

const _userId = 'local';

Future<void> _insertOutcome(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        intent: const Value('next'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  await seedCurrentAction(db,
      outcomeId: id, text: 'work on $id', userId: _userId);
}

Widget _nowScreen(GtdDatabase db) {
  final router = GoRouter(
    initialLocation: '/focus',
    routes: [
      GoRoute(path: '/focus', builder: (_, _) => const FocusScreen()),
      GoRoute(
        path: '/focus-session-planning',
        builder: (_, _) => const Scaffold(body: Text('planning')),
      ),
      GoRoute(
        path: '/shutdown',
        builder: (_, _) => const Scaffold(body: Text('shutdown-route')),
      ),
      GoRoute(
        path: '/inbox',
        builder: (_, _) => const Scaffold(body: Text('inbox-route')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

/// Opens a session over [planIds], engages `off` off-Plan, completes every
/// Outcome in [doneIds].
Future<void> _stage(
  GtdDatabase db, {
  required List<String> planIds,
  required List<String> doneIds,
}) async {
  final clarification = DaoClarificationService(db);
  for (final id in [...planIds, 'off']) {
    await _insertOutcome(db, id);
  }
  final sessionId =
      await db.focusSessionDao.openSession(userId: _userId, taskIds: planIds);
  await db.focusSessionDao.setCurrentTask(sessionId: sessionId, taskId: 'off');
  await db.focusSessionDao.setCurrentTask(sessionId: sessionId, taskId: null);
  for (final id in doneIds) {
    await clarification.completeOutcome(id);
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  for (final scenario in {
    'Plan all done': ['plan'],
    'empty Plan': <String>[],
  }.entries) {
    group('${scenario.key}, off-Plan Outcome unfinished', () {
      late GtdDatabase db;

      setUp(() async {
        SharedPreferences.setMockInitialValues({});
        db = GtdDatabase(NativeDatabase.memory());
        await _stage(db,
            planIds: scenario.value, doneIds: [...scenario.value]);
      });
      tearDown(() async => db.close());

      testWidgets('offers Evening Shutdown and leaves the session open',
          (tester) async {
        await tester.pumpWidget(_nowScreen(db));
        await settleWithRealAsync(tester);

        expect(find.text('End Session'), findsNothing);
        expect(find.text('Begin Evening Shutdown'), findsOneWidget);

        await tester.tap(find.text('Begin Evening Shutdown'));
        await settleWithRealAsync(tester);
        expect(find.text('shutdown-route'), findsOneWidget);

        final session = await tester
            .runAsync(() => db.focusSessionDao.getActiveSession());
        expect(session, isNotNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    });
  }

  group('Plan all done, off-Plan Outcome also done', () {
    late GtdDatabase db;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = GtdDatabase(NativeDatabase.memory());
      await _stage(db, planIds: ['plan'], doneIds: ['plan', 'off']);
    });
    tearDown(() async => db.close());

    testWidgets('End Session closes directly, writing no Disposition',
        (tester) async {
      await tester.pumpWidget(_nowScreen(db));
      await settleWithRealAsync(tester);

      expect(find.text('End Session'), findsOneWidget);
      await tester.tap(find.text('End Session'));
      await settleWithRealAsync(tester);
      expect(find.text('inbox-route'), findsOneWidget);

      final active =
          await tester.runAsync(() => db.focusSessionDao.getActiveSession());
      expect(active, isNull);
      final dispositions = await tester.runAsync(
          () => db.select(db.focusSessionDispositions).get());
      expect(dispositions, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  });
}
