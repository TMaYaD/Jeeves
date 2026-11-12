import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/settings/settings_screen.dart';
import 'package:jeeves/screens/tag_management/tag_management_screen.dart';
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
          for (final kind in TagManagementKind.values)
            GoRoute(
              path: kind.routePath,
              builder: (_, _) => TagManagementScreen(kind: kind),
            ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            notificationServiceProvider
                .overrideWithValue(_StubNotificationService()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      try {
        await _settle(tester);
        await tester.scrollUntilVisible(
            find.byKey(const Key('manage_people_tile')), 200);
        await tester.tap(find.byKey(const Key('manage_people_tile')));
        await _settle(tester);
        expect(find.byType(TagManagementScreen), findsOneWidget);
        expect(find.text('Alise'), findsOneWidget);
        expect(find.text('Alice'), findsOneWidget);

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

        // Delete it: the Outcomes and the Capture stay, the entry goes.
        await tester.tap(find.byKey(const Key('tag_management_row_alice')));
        await _settle(tester);
        await tester.tap(find.widgetWithText(ListTile, 'Delete'));
        await _settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await _settle(tester);

        expect(find.byKey(const Key('tag_management_empty')), findsOneWidget);
        junctions = await _real(tester, () => db.select(db.todoTags).get());
        expect(junctions, isEmpty);
        expect(await _real(tester, () => db.select(db.captureTags).get()),
            isEmpty);
        expect(await _real(tester, () => db.select(db.todos).get()),
            hasLength(2));
        expect(await _real(tester, () => db.select(db.captures).get()),
            hasLength(1));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );
}
