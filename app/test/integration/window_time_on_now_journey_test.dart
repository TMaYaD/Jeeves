/// A picked Outcome keeps its time inside its named window on the Now screen.
///
/// The real Now screen over a real in-memory database: the session opens at
/// 09:00 and an Outcome on a window open 11:00–20:00 is drawn at or after
/// 11:00, the same time the planning timeline gave it, not back at 09:00.
///
/// Harness shape follows `sprint_on_tile_journey_test.dart`.
@TestOn('!browser')
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/action_place_and_time_window.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/time_window_provider.dart';
import 'package:jeeves/screens/focus_screen.dart';
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

const _userId = 'local';

/// Monday 23 November 2026, 09:00 local.
final _sessionStart = DateTime(2026, 11, 23, 9, 0);

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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    for (final entry in {'store': 60, 'plain': 30}.entries) {
      await db.todoDao.insertOutcome(
        id: entry.key,
        title: entry.key,
        userId: _userId,
        timeEstimate: entry.value,
      );
      await seedCurrentAction(
        db,
        outcomeId: entry.key,
        text: 'Do ${entry.key}',
        userId: _userId,
        createdAt: _sessionStart,
      );
    }
    final windowId = await db.timeWindowDao.createTimeWindow(
      name: 'Store hours',
      hours: {
        for (var day = 1; day <= 7; day++)
          day: (startMinute: 11 * 60, endMinute: 20 * 60),
      },
      userId: _userId,
    );
    final actionId = (await db.actionDao.getCurrentAction('store'))!.id;
    await db.actionDao.setTimeWindow(actionId, windowId!);
    await db.focusSessionDao.openSession(
      userId: _userId,
      taskIds: ['plain', 'store'],
      now: _sessionStart,
    );
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(
          () => _sessionStart.add(const Duration(minutes: 5))),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
    router = GoRouter(
      initialLocation: '/focus',
      routes: [
        GoRoute(path: '/focus', builder: (_, _) => const FocusScreen()),
      ],
    );
  });

  tearDown(() async {
    router.dispose();
    await db.close();
  });

  testWidgets('the Now timeline keeps a window Outcome inside its window',
      (tester) async {
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      await _pumpFrames(tester, frames: 20);

      // The plain Outcome has no window and comes first, so its tile marks
      // 09:00; the window Outcome sits at least two hours below it (11:00)
      // and ends by 20:00, instead of directly after it at 09:30.
      double top(String id) => tester
          .getTopLeft(find.byKey(Key('day_timeline_tile_${id}_1')))
          .dy;
      final storeMinute = top('store') - top('plain');
      expect(storeMinute, greaterThanOrEqualTo(120));
      expect(storeMinute + 60, lessThanOrEqualTo(660));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => pumpEventQueue());
      container.dispose();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
    }
  });

  testWidgets('the Now timeline waits for the windows before placing anything',
      (tester) async {
    final windows = StreamController<Map<String, ActionTimeWindow>>();
    final realWindows = (await tester
        .runAsync(() => db.actionDao.getCurrentTimeWindows()))!;
    final held = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(
          () => _sessionStart.add(const Duration(minutes: 5))),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
      currentTimeWindowsProvider.overrideWith((_) => windows.stream),
    ]);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: held,
        child: MaterialApp.router(routerConfig: router),
      ));
      await _pumpFrames(tester, frames: 20);
      // No window data yet: no tile is drawn, so none can start at 09:00.
      expect(find.byKey(const Key('day_timeline_tile_store_1')), findsNothing);

      windows.add(realWindows);
      await _pumpFrames(tester, frames: 20);
      double top(String id) => tester
          .getTopLeft(find.byKey(Key('day_timeline_tile_${id}_1')))
          .dy;
      expect(top('store') - top('plain'), greaterThanOrEqualTo(120));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => pumpEventQueue());
      held.dispose();
      await windows.close();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
    }
  });
}
