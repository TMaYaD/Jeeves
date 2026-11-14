/// "End Session" must not close a session on an Outcome list that belongs to
/// an earlier moment (#899).
///
/// Now reads the open session and its Review surface from two independent
/// streams. A frame can pair a newly opened session with the empty list that
/// was on screen before it opened; the direct close must still refuse to close
/// a session that has an unfinished Outcome. Everything runs through the real
/// Now screen over a real in-memory store. A database result only lands when
/// the test drains real async, while `pump()` draws frames without letting any
/// land, so the test decides which results Now has seen when the tap happens.
library;

import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/focus_screen.dart';
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

/// Holds back the completion of exactly one reactive Review-surface statement
/// while [armed]. Every query still runs on real SQLite.
class _SurfaceGate extends QueryInterceptor {
  bool armed = false;
  Completer<void>? _release;

  void arm() {
    armed = true;
    _release = Completer<void>();
  }

  void release() {
    armed = false;
    final release = _release;
    if (release != null && !release.isCompleted) release.complete();
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) async {
    final result = await super.runSelect(executor, statement, args);
    // The reactive statement has no bound arguments; the session-pinned read
    // used by the direct close has three, and must never be held.
    if (armed && statement.contains('surface_order') && args.isEmpty) {
      armed = false;
      await _release!.future;
    }
    return result;
  }
}

class _Harness {
  _Harness(this.db);
  final GtdDatabase db;
  late final GoRouter router;

  Widget app() {
    router = GoRouter(
      initialLocation: '/focus',
      routes: [
        GoRoute(path: '/focus', builder: (_, _) => const FocusScreen()),
        GoRoute(
          path: '/plan',
          builder: (_, _) => Consumer(builder: (context, ref, _) {
            // Stand-in for the planning route: it keeps the open-session
            // stream live while Now is unmounted, as the real one does.
            ref.watch(activeSessionProvider);
            return const Scaffold(body: Text('planning'));
          }),
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
        notificationServiceProvider
            .overrideWithValue(StubNotificationService()),
      ],
      child: MaterialApp.router(routerConfig: router),
    );
  }

  Future<void> tapFooter(WidgetTester tester) async {
    final endSession = find.text('End Session');
    final shutdown = find.text('Begin Evening Shutdown');
    expect(endSession.evaluate().isNotEmpty || shutdown.evaluate().isNotEmpty,
        isTrue,
        reason: 'Now shows a session footer callout');
    await tester
        .tap(endSession.evaluate().isNotEmpty ? endSession : shutdown);
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late _SurfaceGate gate;
  late GtdDatabase db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gate = _SurfaceGate();
    db = GtdDatabase(NativeDatabase.memory().interceptWith(gate));
    await _insertOutcome(db, 'plan');
  });
  tearDown(() async {
    gate.release();
    await db.close();
  });

  testWidgets(
      'Start Day route: back on Now with the new session and the old empty '
      'list, End Session leaves the session open', (tester) async {
    final harness = _Harness(db);
    await tester.pumpWidget(harness.app());
    await settleWithRealAsync(tester);

    // Now with no session; leave it, so its list provider pauses on `[]`.
    harness.router.go('/plan');
    await settleWithRealAsync(tester);
    expect(find.text('planning'), findsOneWidget);

    // Start Day (stand-in): a session opens while Now is unmounted.
    await tester.runAsync(() async {
      await db.focusSessionDao.openSession(userId: _userId, taskIds: ['plan']);
      await pumpEventQueue();
    });
    await tester.pump();

    // Back on Now: draw frames only, so the list re-query cannot land.
    harness.router.go('/focus');
    await tester.pump();
    await tester.pump();

    final container =
        ProviderScope.containerOf(tester.element(find.byType(FocusScreen)));
    expect(container.read(activeSessionProvider).value, isNotNull,
        reason: 'guard: Now already has the new session');
    // CI showed the list provider is NOT stale here: it keeps its subscription
    // while Now is unmounted and has already re-queried (it holds the Plan).
    // The test stays as a pin on the Start Day route.

    await harness.tapFooter(tester);
    await settleWithRealAsync(tester);

    final session =
        await tester.runAsync(() => db.focusSessionDao.getActiveSession());
    expect(session, isNotNull, reason: 'the planned session must stay open');
    expect(find.text('shutdown-route'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
      'a session opens while Now is on screen and its list is late: '
      'End Session leaves the session open', (tester) async {
    final harness = _Harness(db);
    await tester.pumpWidget(harness.app());
    await settleWithRealAsync(tester);

    gate.arm();
    await tester.runAsync(() async {
      await db.focusSessionDao.openSession(userId: _userId, taskIds: ['plan']);
      await pumpEventQueue();
    });
    await tester.pump();
    await tester.pump();

    final container =
        ProviderScope.containerOf(tester.element(find.byType(FocusScreen)));
    expect(container.read(activeSessionReviewSurfaceProvider).value, isEmpty,
        reason: 'guard: the new list has not reached Now');
    expect(container.read(activeSessionProvider).value, isNotNull,
        reason: 'guard: Now already has the new session');

    await harness.tapFooter(tester);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();

    final session =
        await tester.runAsync(() => db.focusSessionDao.getActiveSession());
    expect(session, isNotNull, reason: 'the new session must stay open');
    expect(find.text('shutdown-route'), findsOneWidget);

    gate.release();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
