import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/periodic_review_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/screens/periodic_review/periodic_review_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/periodic_review_test_helpers.dart';
import '../helpers/settle.dart';
import '../test_helpers.dart';

void main() {
  setUpAll(configureSqliteForTests);
  late Directory storeDirectory;
  late GtdDatabase db;
  late ProviderContainer container;
  late GoRouter router;

  // Real storage setup must run outside testWidgets' FakeAsync zone.
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storeDirectory = await Directory.systemTemp.createTemp('weekly-review-ranking-');
    db = GtdDatabase(NativeDatabase(File('${storeDirectory.path}/review.sqlite')));
    container = createPeriodicReviewTestContainer(db);
    await container.read(syncedPreferencesProvider.future);
    final now = DateTime.now().toUtc();
    final baseCreatedAt = DateTime.utc(2026, 1, 1);

    Future<void> outcome(String id, {
      required String intent,
      required int createdDay,
    }) async {
      await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(id),
        userId: const Value('local'),
        intent: Value(intent),
        createdAt: Value(baseCreatedAt.add(Duration(days: createdDay))),
        updatedAt: Value(baseCreatedAt),
      ));
    }

    // Newest row of all, yet Inbox Captures always come first.
    await db.captureDao.insertCapture(CapturesCompanion(
      id: const Value('capture'),
      title: const Value('Unprocessed Capture'),
      userId: const Value('local'),
      createdAt: Value(now),
      updatedAt: Value(now),
    ));
    const recent = Duration(days: 1);
    final clarifiedAgo = <String, Duration>{};
    for (var index = 0; index < 5; index++) {
      await outcome('recent-planless-$index', intent: 'next',
          createdDay: 10 + index);
      clarifiedAgo['recent-planless-$index'] = recent;
    }
    final personId = await db.tagDao.createPersonTag('Alice', 'local');
    for (var index = 0; index < 4; index++) {
      await outcome('recent-waiting-$index', intent: 'next',
          createdDay: 20 + index);
      await db.todoDao.setPersonTagsForTodo('recent-waiting-$index', {personId}, 'local');
      clarifiedAgo['recent-waiting-$index'] = recent;
    }
    await outcome('oldest-planless', intent: 'next', createdDay: 30);
    clarifiedAgo['oldest-planless'] = const Duration(days: 90);
    await outcome('old-with-action', intent: 'next', createdDay: 31);
    await db.actionDao.setCurrentAction('old-with-action', 'Call the plumber');
    clarifiedAgo['old-with-action'] = const Duration(days: 60);
    await outcome('old-someday', intent: 'maybe', createdDay: 32);
    clarifiedAgo['old-someday'] = const Duration(days: 80);
    await outcome('recent-someday', intent: 'maybe', createdDay: 33);
    clarifiedAgo['recent-someday'] = const Duration(hours: 1);

    // Stamp last, so seeding writes above cannot overwrite the intended ages.
    for (final entry in clarifiedAgo.entries) {
      await (db.update(db.todos)..where((t) => t.id.equals(entry.key)))
          .write(TodosCompanion(lastClarifiedAt: Value(now.subtract(entry.value))));
    }
    await container.read(periodicReviewProvider.notifier).loadAllSnapshots();
    router = GoRouter(initialLocation: '/review', routes: [
      GoRoute(path: '/review', builder: (_, _) => const PeriodicReviewScreen()),
      GoRoute(path: '/inbox', builder: (_, _) => const Scaffold(body: Text('Home'))),
    ]);
  });

  tearDown(() async {
    router.dispose();
    container.dispose();
    await db.close();
    await storeDirectory.delete(recursive: true);
  });

  testWidgets('a 15-minute review takes the Capture, then the longest-unclarified '
      'Outcomes from any step', (tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await settleWithRealAsync(tester);
    for (final key in const [null, Key('periodic_review_next_step')]) {
      final finder = key == null ? find.text('15 min') : find.byKey(key);
      await tester.ensureVisible(finder);
      await tester.runAsync(() async {
        await tester.tap(finder);
        await pumpEventQueue();
      });
      await settleWithRealAsync(tester);
    }

    final selected = container.read(periodicReviewProvider);
    expect(selected.inboxNav.items, ['capture']);
    expect(selected.somedayNav.items!.map((t) => t.id), ['old-someday']);
    expect(selected.nextNav.items!.map((t) => t.id).toSet(),
        {'oldest-planless', 'old-with-action',
         'recent-planless-0', 'recent-planless-1', 'recent-planless-2'});
    expect(selected.waitingForNav.items, isEmpty);
  });
}
