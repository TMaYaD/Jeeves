import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/tag_filter_provider.dart';
import 'package:jeeves/screens/settings/settings_screen.dart';
import 'package:jeeves/screens/tag_management/tag_management_screen.dart';
import 'package:jeeves/screens/task_detail/task_detail_screen.dart';
import 'package:jeeves/screens/waiting_for/waiting_for_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

class _StubNotificationService extends NotificationService {
  _StubNotificationService() : super.forTesting();

  @override
  Future<void> scheduleRitualReminder(RitualId ritual, TimeOfDay time) async {}
  @override
  Future<void> cancelRitualReminder(RitualId ritual) async {}
  @override
  Future<void> cancelRecurringRitualReminder(RitualId ritual) async {}
  @override
  Future<void> snoozeRitualReminder(RitualId ritual, int minutes) async {}
  @override
  Future<void> skipTodayRitualReminder(RitualId ritual) async {}
  @override
  Future<void> cancelReminder(int id) async {}
  @override
  Future<void> cancelAll() async {}
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// Reads through a real-async turn: a Drift query awaited inside `testWidgets`
/// would otherwise wait on a clock that never ticks (docs/TESTING.md).
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
    final now = DateTime.now();
    for (final id in ['o1', 'o2']) {
      await db.into(db.todos).insert(TodosCompanion(
            id: Value(id),
            title: Value('Outcome $id'),
            clarified: const Value(true),
            userId: const Value('local'),
            createdAt: Value(now),
            updatedAt: Value(now),
          ));
    }
    await db.captureDao.insertCapture(CapturesCompanion(
      id: const Value('c1'),
      title: const Value('A thought'),
      captureSource: const Value('manual'),
      userId: const Value('local'),
      createdAt: Value(now),
      updatedAt: Value(now),
    ));
    await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('alise'),
        name: Value('Alise'),
        type: Value('person'),
        userId: Value('local')));
    await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('alice'),
        name: Value('Alice'),
        type: Value('person'),
        userId: Value('local')));
    await db.tagDao.assignTag('o1', 'alise', 'local');
    await db.tagDao.assignTag('o2', 'alice', 'local');
    await db.captureDao.assignTagHint('c1', 'alise', 'local');
  });
  tearDown(() async => db.close());

  testWidgets(
    'Settings → People: merge a misspelt person, rename the survivor, delete it',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/settings',
        routes: [
          GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
          GoRoute(
              path: '/waiting-for',
              builder: (_, _) => const WaitingForScreen()),
          GoRoute(
            path: '/task/:id',
            builder: (_, state) =>
                TaskDetailScreen(todoId: state.pathParameters['id']!),
          ),
          for (final kind in TagManagementKind.values)
            GoRoute(
              path: kind.routePath,
              builder: (_, _) => TagManagementScreen(kind: kind),
            ),
        ],
      );
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider
            .overrideWithValue(_StubNotificationService()),
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
            find.byKey(const Key('manage_people_tile')), 200);
        await tester.ensureVisible(find.byKey(const Key('manage_people_tile')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('manage_people_tile')));
        await _settle(tester);
        expect(find.byType(TagManagementScreen), findsOneWidget);
        expect(find.text('Alise'), findsOneWidget);
        expect(find.text('Alice'), findsOneWidget);

        // The misspelt person is in the sticky tag filter when it is merged.
        container.read(tagFilterProvider.notifier).toggle('alise');

        // Merge Alise into Alice.
        await tester.tap(find.byKey(const Key('tag_management_row_alise')));
        await _settle(tester);
        await tester.tap(find.widgetWithText(ListTile, 'Merge into…'));
        await _settle(tester);
        await tester.tap(find.widgetWithText(ListTile, 'Alice').last);
        await _settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Merge'));
        await _settle(tester);

        expect(find.text('Alise'), findsNothing);
        expect(find.text('Alice'), findsOneWidget);
        var junctions = await _real(tester, () => db.select(db.todoTags).get());
        expect(junctions.map((r) => r.tagId).toSet(), {'alice'});
        expect(junctions, hasLength(2));
        final hints = await _real(tester, () => db.select(db.captureTags).get());
        expect(hints.single.tagId, 'alice');
        // The filter follows the merge instead of pointing at a removed id.
        expect(container.read(tagFilterProvider), {'alice'});

        // Waiting For: one Alice group holding both Outcomes, no Alise.
        router.go('/waiting-for');
        await _settle(tester);
        expect(find.text('Alice'), findsOneWidget);
        expect(find.text('Alise'), findsNothing);
        expect(find.text('Outcome o1'), findsOneWidget);
        expect(find.text('Outcome o2'), findsOneWidget);
        router.go(TagManagementKind.people.routePath);
        await _settle(tester);

        // Rename the survivor.
        await tester.tap(find.byKey(const Key('tag_management_row_alice')));
        await _settle(tester);
        await tester.tap(find.widgetWithText(ListTile, 'Rename'));
        await _settle(tester);
        await tester.enterText(find.byType(TextField), 'Alicia');
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await _settle(tester);
        expect(find.text('Alicia'), findsOneWidget);
        expect(find.text('Alice'), findsNothing);

        // The renamed header on Waiting For, and the Outcome detail status.
        router.go('/waiting-for');
        await _settle(tester);
        expect(find.text('Alicia'), findsOneWidget);
        expect(find.text('Alice'), findsNothing);
        await tester.tap(find.text('Outcome o1'));
        await _settle(tester);
        expect(find.text('Waiting For Alicia'), findsOneWidget);
        router.go(TagManagementKind.people.routePath);
        await _settle(tester);

        // Delete it: the Outcomes and the Capture stay, the entry goes.
        await tester.tap(find.byKey(const Key('tag_management_row_alice')));
        await _settle(tester);
        await tester.tap(find.widgetWithText(ListTile, 'Delete'));
        await _settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await _settle(tester);

        expect(find.byKey(const Key('tag_management_empty')), findsOneWidget);
        // The filter drops the deleted id.
        expect(container.read(tagFilterProvider), isEmpty);
        junctions = await _real(tester, () => db.select(db.todoTags).get());
        expect(junctions, isEmpty);
        expect(await _real(tester, () => db.select(db.captureTags).get()),
            isEmpty);
        expect(await _real(tester, () => db.select(db.todos).get()),
            hasLength(2));
        expect(await _real(tester, () => db.select(db.captures).get()),
            hasLength(1));

        // Both Outcomes left Waiting For and are no longer waiting on anyone.
        router.go('/waiting-for');
        await _settle(tester);
        expect(find.text('Outcome o1'), findsNothing);
        expect(find.text('Outcome o2'), findsNothing);
        expect(find.text('Nothing waiting on anyone'), findsOneWidget);
        router.go('/task/o1');
        await _settle(tester);
        expect(find.text('Next Actions'), findsWidgets);
        expect(find.text('Waiting For Alicia'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );
}
