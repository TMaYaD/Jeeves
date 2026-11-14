/// Journey: Start Day always lands on Now (#901).
///
/// Real planning screen, real planning notifier and a live open-session stream
/// over a real in-memory store. Only the database and the notification service
/// are overridden. One case draws a frame while `startDay()` is still awaiting
/// its preference read, an ordering production allows and an ordinary drain
/// never produces (docs/TESTING.md).
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
import 'package:jeeves/screens/planning/focus_session_planning_screen.dart';
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

const _userId = 'local';
const _focusKey = Key('focus_route');

/// Holds back the completion of the next `user_preferences` read of the
/// last-session available-time key once [armed], so a frame can be drawn while
/// `startDay()` is provably still in flight. The statement still runs on the
/// real store.
class _HoldPreferenceRead extends QueryInterceptor {
  bool armed = false;
  final reached = Completer<void>();
  final _gate = Completer<void>();

  /// Safe to call more than once, so cleanup can always release the hold.
  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) async {
    if (armed &&
        !reached.isCompleted &&
        statement.contains('user_preferences') &&
        args.contains(kLastSessionAvailableMinutesKey)) {
      reached.complete();
      await _gate.future;
    }
    return super.runSelect(executor, statement, args);
  }
}

/// A live drift stream is subscribed throughout, so `pumpAndSettle` would spin
/// (docs/TESTING.md): drain real async and pump a bounded number of frames.
Future<void> _pumpFrames(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late _HoldPreferenceRead hold;
  late ProviderContainer container;
  late GoRouter router;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    hold = _HoldPreferenceRead();
    db = GtdDatabase(NativeDatabase.memory().interceptWith(hold));
    final now = DateTime.now();
    await db.into(db.todos).insert(TodosCompanion(
          id: const Value('o1'),
          title: const Value('Outcome o1'),
          intent: const Value('next'),
          userId: const Value(_userId),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
    await seedCurrentAction(db,
        outcomeId: 'o1', text: 'work on o1', userId: _userId);
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
    router = GoRouter(
      initialLocation: '/focus-session-planning',
      routes: [
        GoRoute(
          path: '/focus-session-planning',
          builder: (_, _) => const FocusSessionPlanningScreen(),
        ),
        GoRoute(
            path: '/focus', builder: (_, _) => const SizedBox(key: _focusKey)),
        GoRoute(path: '/shutdown', builder: (_, _) => const SizedBox()),
      ],
    );
  });

  tearDown(() async {
    router.dispose();
    await db.close();
  });

  /// Mounts the real screen and walks to the completion view with one
  /// Outcome selected, then settles so the mount-time pre-fill has finished.
  Future<void> openCompletionView(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await _pumpFrames(tester);
    container.read(focusSessionPlanningProvider.notifier)
      ..selectTask('o1')
      ..goToStep(6);
    await _pumpFrames(tester);
    expect(find.text('Start Day'), findsOneWidget);
  }

  /// Disposing the container cancels the live drift streams, which schedules
  /// a zero-duration timer; it must fire inside the test body.
  Future<void> teardownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => pumpEventQueue());
    container.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  String currentPath() => router.routeInformationProvider.value.uri.path;

  testWidgets('ordinary ordering: Start Day lands on Now', (tester) async {
    try {
      await openCompletionView(tester);

      await tester.tap(find.text('Start Day'));
      await _pumpFrames(tester);

      expect(find.byKey(_focusKey), findsOneWidget);
      expect(currentPath(), '/focus');
    } finally {
      await teardownApp(tester);
    }
  });

  testWidgets('a frame drawn while the start is in flight: still lands on Now',
      (tester) async {
    try {
      await openCompletionView(tester);
      hold.armed = true;

      await tester.tap(find.text('Start Day'));
      // Drain until startDay() is parked on the held preference read; the
      // session is already open and the planning state already reset.
      for (var i = 0; i < 20 && !hold.reached.isCompleted; i++) {
        await tester.runAsync(() => pumpEventQueue());
      }
      expect(hold.reached.isCompleted, isTrue,
          reason: 'startDay() no longer awaits the available-time preference '
              'read after opening the session: move the hold to whatever it '
              'awaits now, or delete this case if nothing is awaited');
      // Let the session stream reach the screen, and draw frames mid-start.
      await _pumpFrames(tester, frames: 2);
      final session =
          await tester.runAsync(db.focusSessionDao.getActiveSession);
      expect(session, isNotNull, reason: 'the session is already open');

      hold.release();
      await _pumpFrames(tester);

      expect(find.text('Close your current session first'), findsNothing,
          reason: 'the user must not be left on the session-open interstitial');
      expect(find.byKey(_focusKey), findsOneWidget);
      expect(currentPath(), '/focus');
    } finally {
      hold.release();
      await teardownApp(tester);
    }
  });
}
