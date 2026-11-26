/// The time page (issue #55).
///
/// Every Outcome that carries a time is listed here, hidden or not: the
/// Outcomes the clock is holding back are off Next, and here they are not.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/models/time_window_hours.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/screens/task_detail/task_detail_screen.dart';
import 'package:jeeves/screens/time_page/time_page_screen.dart';

import '../test_helpers.dart';

const _userId = 'local';

final _workHours = <int, DayHours>{
  for (var day = 1; day <= 5; day++)
    day: (startMinute: 9 * 60, endMinute: 17 * 60),
};

final _storeHours = <int, DayHours>{
  for (var day = 1; day <= 5; day++)
    day: (startMinute: 11 * 60, endMinute: 20 * 60),
};

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<String> _seedOutcome(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        intent: const Value('next'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  await seedCurrentAction(
      db, outcomeId: id, text: 'work on $id', userId: _userId);
  return (await db.actionDao.getCurrentAction(id))!.id;
}

/// The ids on the Next list, polled until the list has answered.
Future<Set<String>> _nextIds(
    WidgetTester tester, ProviderContainer container) async {
  final sub = container.listen(nextProvider, (_, _) {});
  addTearDown(sub.close);
  for (var i = 0; i < 100; i++) {
    final value = sub.read();
    if (value.hasValue) {
      return {for (final t in value.value ?? const <Todo>[]) t.id};
    }
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
  return {};
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    // Wednesday 2026-11-11, 10:00: "Work hours" is open, "Store hours" is
    // not.
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWith((ref) => () => DateTime(2026, 11, 11, 10)),
      nudgeBoundaryTickProvider.overrideWithValue(0),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
  });

  tearDown(() async => db.close());

  testWidgets('every Outcome with a time is listed, hidden or not',
      (tester) async {
    final workId = await db.timeWindowDao.createTimeWindow(
      name: 'Work hours',
      hours: _workHours,
      userId: _userId,
    );
    final storeId = await db.timeWindowDao.createTimeWindow(
      name: 'Store hours',
      hours: _storeHours,
      userId: _userId,
    );
    expect(workId, isNotNull);
    expect(storeId, isNotNull);

    final workAction = await _seedOutcome(db, 'o1');
    final storeAction = await _seedOutcome(db, 'o2');
    final laterAction = await _seedOutcome(db, 'o3');
    await db.actionDao.setTimeWindow(workAction, workId);
    await db.actionDao.setTimeWindow(storeAction, storeId);
    await db.actionDao.setTimeContext(
      laterAction,
      TimeContext.create(fromDate: DateTime(2026, 11, 30)),
    );

    final router = GoRouter(
      initialLocation: '/time',
      routes: [
        GoRoute(path: '/time', builder: (_, _) => const TimePageScreen()),
        GoRoute(
          path: '/task/:id',
          builder: (_, state) =>
              TaskDetailScreen(todoId: state.pathParameters['id']!),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    try {
      await _settle(tester);

      // The three Outcomes are on the page.
      expect(find.text('Outcome o1'), findsOneWidget);
      expect(find.text('Outcome o2'), findsOneWidget);
      expect(find.text('Outcome o3'), findsOneWidget);

      // Under the right headers, with the hours in the header.
      expect(find.text('Work hours'), findsOneWidget);
      expect(find.text('Store hours'), findsOneWidget);
      expect(find.text('Mon–Fri 09:00–17:00'), findsOneWidget);
      expect(find.text('Mon–Fri 11:00–20:00'), findsOneWidget);
      expect(find.text('One-time'), findsOneWidget);

      // With the right markers.
      expect(find.text('On Next'), findsOneWidget);
      expect(find.text('opens 11:00'), findsOneWidget);
      expect(find.text('after Nov 30'), findsOneWidget);

      // The two whose time is closed are off Next; the open one is on it.
      expect(await _nextIds(tester, container), {'o1'});

      // Tapping a row opens the Outcome.
      await tester.tap(find.text('Outcome o2'));
      await _settle(tester);
      expect(find.byType(TaskDetailScreen), findsOneWidget);
    } finally {
      // The time boundary arms a timer; the container's disposal cancels it,
      // and the widget tree goes with it.
      container.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  }, timeout: const Timeout(Duration(seconds: 120)));

  testWidgets('a long window name lays out in the group header', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // A name at the length the store allows: ninety-seven characters.
    final name = List.filled(7, 'Opening hours').join(' ');
    expect(name.length, lessThanOrEqualTo(100));
    final workId = await db.timeWindowDao.createTimeWindow(
      name: name,
      hours: _workHours,
      userId: _userId,
    );
    expect(workId, isNotNull);
    final workAction = await _seedOutcome(db, 'o1');
    await db.actionDao.setTimeWindow(workAction, workId);

    final router = GoRouter(
      initialLocation: '/time',
      routes: [
        GoRoute(path: '/time', builder: (_, _) => const TimePageScreen()),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    try {
      await _settle(tester);

      expect(find.text(name), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: 'the group header lays out clean at 320dp');
    } finally {
      container.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  }, timeout: const Timeout(Duration(seconds: 120)));
}
