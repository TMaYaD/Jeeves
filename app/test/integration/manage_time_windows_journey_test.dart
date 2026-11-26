/// Settings → Manage → Time windows (issue #55).
///
/// The user's named time windows: make one, rename it, and delete it — the
/// delete says how many actions lose the window, and they do.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/time_window_hours.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/screens/settings/settings_screen.dart';
import 'package:jeeves/screens/time_window_management/time_window_management_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/widgets/time_window_editor_sheet.dart';

import '../test_helpers.dart';

const _userId = 'local';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<T> _real<T>(WidgetTester tester, Future<T> Function() body) async {
  final result = await tester.runAsync(body);
  return result as T;
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
  });
  tearDown(() async => db.close());

  testWidgets(
      'Settings → Time windows: make a window, rename it, and delete it with '
      'the count of the actions it takes away', (tester) async {
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
        GoRoute(
          path: TimeWindowManagementScreen.routePath,
          builder: (_, _) => const TimeWindowManagementScreen(),
        ),
      ],
    );
    final container = ProviderContainer(overrides: [
      nudgeBoundaryTickProvider.overrideWithValue(0),
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider
          .overrideWithValue(StubNotificationService()),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    try {
      await _settle(tester);
      await tester.scrollUntilVisible(
          find.byKey(const Key('manage_time_windows_tile')), 200);
      await tester.ensureVisible(
          find.byKey(const Key('manage_time_windows_tile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('manage_time_windows_tile')));
      await _settle(tester);

      expect(find.byType(TimeWindowManagementScreen), findsOneWidget);
      // Nothing yet: the empty state speaks.
      expect(find.byKey(const Key('time_window_management_empty')),
          findsOneWidget);

      // Make "Store hours", open Monday to Friday.
      await tester.tap(find.byKey(const Key('time_window_new')));
      await _settle(tester);
      await tester.enterText(
          find.byKey(const Key('time_window_name')), 'Store hours');
      await tester.pumpAndSettle();
      for (final day in [1, 2, 3, 4, 5]) {
        await tester.tap(find.byKey(Key('time_window_day_$day')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('time_window_save')));
      await _settle(tester);

      final windows = await _real(tester, () => db.select(db.timeWindows).get());
      expect(windows, hasLength(1));
      expect(windows.single.name, 'Store hours');
      expect(TimeWindowHours.tryParse(windows.single.hours)?.days, [1, 2, 3, 4, 5]);
      // The row carries the hours in words.
      expect(find.text('Mon–Fri 09:00–17:00'), findsOneWidget);

      // An action uses it: the row counts it.
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
            id: const Value('o1'),
            title: const Value('Outcome o1'),
            userId: const Value(_userId),
            createdAt: Value(now),
            updatedAt: Value(now),
          ));
      await db.into(db.actions).insert(ActionsCompanion(
            id: const Value('a1'),
            outcomeId: const Value('o1'),
            userId: const Value(_userId),
            actionText: const Value('buy hinge screws'),
            role: const Value('current'),
            timeWindowId: Value(windows.single.id),
            createdAt: Value(now),
          ));
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(Key('time_window_row_${windows.single.id}')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );

      // Rename it.
      await tester.tap(find.byKey(Key('time_window_row_${windows.single.id}')));
      await _settle(tester);
      await tester.enterText(
          find.byKey(const Key('time_window_name')), 'Opening hours');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('time_window_save')));
      await _settle(tester);

      expect(find.text('Opening hours'), findsOneWidget);
      expect(find.text('Store hours'), findsNothing);

      // Delete it: the confirm says how many actions lose the window, and they
      // do.
      await tester.tap(find.byKey(Key('time_window_row_${windows.single.id}')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('time_window_delete')));
      await _settle(tester);
      expect(find.text('1 action loses this window.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('time_window_delete_confirm')));
      await _settle(tester);

      expect(await _real(tester, () => db.select(db.timeWindows).get()), isEmpty);
      final action = await _real(
          tester, () => db.select(db.actions).getSingle());
      expect(action.timeWindowId, isNull);
      expect(find.byKey(const Key('time_window_management_empty')),
          findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  testWidgets('the editor offers the same hours on chosen days, or hours by '
      'day', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showTimeWindowEditorSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('time_window_mode_same')), findsOneWidget);
    expect(find.byKey(const Key('time_window_mode_different')), findsOneWidget);

    // The same hours on chosen days: one From/To pair for all of them.
    await tester.tap(find.byKey(const Key('time_window_day_1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('time_window_start')), findsOneWidget);
    expect(find.byKey(const Key('time_window_end')), findsOneWidget);

    // By day: a pair per day, and a day that is closed reads as closed.
    await tester.tap(find.byKey(const Key('time_window_mode_different')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('time_window_day_1_start')), findsOneWidget);
    expect(find.byKey(const Key('time_window_day_2_on')), findsOneWidget);
  });
}
