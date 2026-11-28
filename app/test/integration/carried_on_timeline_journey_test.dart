/// Carrying on past a Timeboxed limit moves the later suggested times (#1117).
///
/// The real Now screen over a real in-memory database with a fixed clock. The
/// running Outcome is Timeboxed and past its limit; the user taps Start, then
/// "Another sprint, regardless" and "Yes, another sprint". Focus Mode is a
/// plain stub screen, so the notice is looked for on Now only, after going back.
@TestOn('!browser')
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/focus_screen.dart';
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

const _userId = 'local';

final _sessionStart = DateTime.utc(2030, 3, 15, 8, 0);
final _now = _sessionStart.add(const Duration(minutes: 10));

Future<void> _pumpFrames(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;
  late GoRouter router;

  /// A is Timeboxed and past its limit, B follows it, C is set by hand.
  Future<void> seed({bool withLater = true}) async {
    await db.todoDao.insertOutcome(
        id: 'a', title: 'Write the report', userId: _userId, timeEstimate: 30);
    await db.actionDao.setCurrentAction('a', 'Draft the report',
        timeEstimate: 30, now: _sessionStart);
    await db.todoDao.updateFields('a', timeboxed: true, now: _sessionStart);
    await db.timeLogDao.openLog(
        taskId: 'a',
        userId: _userId,
        now: _now.subtract(const Duration(minutes: 55)));
    await db.timeLogDao
        .closeLog(taskId: 'a', now: _now.subtract(const Duration(minutes: 5)));
    final ids = ['a'];
    if (withLater) {
      for (final id in ['b', 'c']) {
        await db.todoDao.insertOutcome(
            id: id, title: 'Outcome $id', userId: _userId, timeEstimate: 30);
        await seedCurrentAction(db,
            outcomeId: id,
            text: 'work on $id',
            userId: _userId,
            createdAt: _sessionStart);
        ids.add(id);
      }
    }
    await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ids,
        pinnedStartByTaskId: {
          if (withLater) 'c': _now.add(const Duration(hours: 3)),
        },
        now: _sessionStart);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => _now),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
    router = GoRouter(
      initialLocation: '/focus',
      routes: [
        GoRoute(path: '/focus', builder: (_, _) => const FocusScreen()),
        GoRoute(
          path: '/focus/active',
          builder: (_, _) => const Scaffold(body: Text('Active focus')),
        ),
      ],
    );
  });

  tearDown(() async {
    router.dispose();
    await db.close();
  });

  Future<void> teardownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => pumpEventQueue());
    container.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  Future<void> openNow(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await _pumpFrames(tester, frames: 20);
  }

  double tileMinute(WidgetTester tester, String outcomeId) =>
      tester
          .getTopLeft(find.byKey(Key('day_timeline_tile_${outcomeId}_1')))
          .dy -
      tester.getTopLeft(find.byType(DragTarget<String>)).dy;

  /// Start A, carry on regardless, confirm; then come back to Now.
  Future<void> carryOnRegardlessAndReturn(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Start').first);
    await _pumpFrames(tester);
    await tester.tap(find.byKey(const Key('timeboxed_gate_regardless')));
    await _pumpFrames(tester);
    await tester.tap(find.byKey(const Key('timeboxed_gate_confirm')));
    await _pumpFrames(tester);
    expect(find.text('Active focus'), findsOneWidget);
    expect(find.byKey(const Key('day_timeline_moved_notice')), findsNothing);
    router.pop();
    await _pumpFrames(tester, frames: 12);
  }

  testWidgets('carrying on moves the later suggested time and says so',
      (tester) async {
    await tester.runAsync(seed);
    try {
      await openNow(tester);
      final bBefore = tileMinute(tester, 'b');
      final cBefore = tileMinute(tester, 'c');

      await carryOnRegardlessAndReturn(tester);

      expect(find.byKey(const Key('day_timeline_moved_notice')),
          findsOneWidget);
      expect(find.text('You carried on, sir, so I have moved one suggested '
          'time.'), findsOneWidget);
      expect(tileMinute(tester, 'b'), greaterThan(bBefore));
      expect(tileMinute(tester, 'c'), cBefore);
      expect(find.bySemanticsLabel(RegExp('You carried on')), findsWidgets);
      for (final key in ['day_timeline_moved_ok', 'day_timeline_moved_undo']) {
        expect(tester.getSize(find.byKey(Key(key))).height,
            greaterThanOrEqualTo(48));
      }

      await tester.tap(find.byKey(const Key('day_timeline_moved_ok')));
      await _pumpFrames(tester);
      expect(find.byKey(const Key('day_timeline_moved_notice')), findsNothing);
      expect(tileMinute(tester, 'b'), greaterThan(bBefore));
    } finally {
      await teardownApp(tester);
    }
  });

  testWidgets('Undo puts the moved suggested time back', (tester) async {
    await tester.runAsync(seed);
    try {
      await openNow(tester);
      final bBefore = tileMinute(tester, 'b');

      await carryOnRegardlessAndReturn(tester);
      expect(tileMinute(tester, 'b'), greaterThan(bBefore));

      await tester.tap(find.byKey(const Key('day_timeline_moved_undo')));
      await _pumpFrames(tester);

      expect(find.byKey(const Key('day_timeline_moved_notice')), findsNothing);
      expect(tileMinute(tester, 'b'), bBefore);
    } finally {
      await teardownApp(tester);
    }
  });

  testWidgets('with nothing after it, carrying on shows no notice',
      (tester) async {
    await tester.runAsync(() => seed(withLater: false));
    try {
      await openNow(tester);
      await carryOnRegardlessAndReturn(tester);
      expect(find.byKey(const Key('day_timeline_moved_notice')), findsNothing);
    } finally {
      await teardownApp(tester);
    }
  });
}
