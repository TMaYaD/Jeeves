import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/periodic_review_provider.dart';
import 'package:jeeves/providers/periodic_review_settings_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/screens/periodic_review/periodic_review_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jeeves/widgets/process_to_handlers.dart';

import '../helpers/periodic_review_test_helpers.dart';
import '../helpers/settle.dart';
import '../test_helpers.dart';

void main() {
  setUpAll(configureSqliteForTests);
  late Directory storeDirectory;
  late File storeFile;
  late GtdDatabase db;
  late ProviderContainer container;
  late GoRouter router;

  // Real storage setup must run outside testWidgets' FakeAsync zone.
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storeDirectory = await Directory.systemTemp.createTemp('weekly-review-');
    storeFile = File('${storeDirectory.path}/review.sqlite');
    db = GtdDatabase(NativeDatabase(storeFile));
    container = createPeriodicReviewTestContainer(db);
    await container.read(syncedPreferencesProvider.future);
    final createdAt = DateTime.utc(2026, 1, 1);
    await db.captureDao.insertCapture(CapturesCompanion(
      id: const Value('capture'),
      title: const Value('Unprocessed Capture'),
      userId: const Value('local'),
      createdAt: Value(createdAt),
      updatedAt: Value(createdAt),
    ));
    for (var index = 0; index < 12; index++) {
      await db.into(db.todos).insert(TodosCompanion(
        id: Value('outcome-${index.toString().padLeft(2, '0')}'),
        title: Value('Outcome $index'),
        userId: const Value('local'),
        intent: const Value('next'),
        clarified: const Value(true),
        createdAt: Value(createdAt.add(Duration(days: index))),
        updatedAt: Value(createdAt),
      ));
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

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.runAsync(() async {
      await tester.tap(finder);
      await pumpEventQueue();
    });
    await settleWithRealAsync(tester);
  }

  Future<void> skipToSummary(WidgetTester tester) async {
    while (container.read(periodicReviewProvider).currentStep <
        PeriodicReviewNotifier.kStepSummary) {
      final skip = find.byKey(const Key('periodic_review_skip'));
      await tap(tester, skip.evaluate().isNotEmpty
          ? skip
          : find.byKey(const Key('periodic_review_next_step')));
    }
  }

  test('an expired open review includes previously covered Outcomes again', () async {
    final openedAt = DateTime.now().toUtc().subtract(const Duration(days: 8));
    await container.read(syncedPreferencesProvider.notifier).set(
      'periodic_review_open_since', openedAt.toIso8601String());
    await (db.update(db.todos)..where((todo) => todo.id.equals('outcome-00')))
        .write(TodosCompanion(lastClarifiedAt:
            Value(openedAt.add(const Duration(hours: 1)))));
    container.invalidate(periodicReviewProvider);
    await container.read(periodicReviewProvider.notifier).loadAllSnapshots();
    expect(container.read(periodicReviewProvider).nextNav.length, 12);
  });

  testWidgets('a kept Capture remains pending in an open review after restart',
      (tester) async {
    final capture = await tester.runAsync(() async {
      await container.read(syncedPreferencesProvider.notifier).set(
        'periodic_review_open_since', DateTime.now().toUtc().toIso8601String());
      return (db.select(db.captures)..where((c) => c.id.equals('capture')))
          .getSingle();
    });
    var kept = false;
    // Keep exists on the shared handler, but is not offered by the Inbox card.
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: ProcessToHandlers(
        subject: CaptureSubject(
          capture: capture!,
          draft: () => ClarifyDraft(title: capture.title),
        ),
        include: const {ProcessAction.keep},
        onAfterRoute: (action) async {
          expect(action, ProcessAction.keep);
          kept = true;
        },
      ))),
    ));
    await settleWithRealAsync(tester);
    await tap(tester, find.text('Keep'));
    expect(kept, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await settleWithRealAsync(tester);
    await tester.runAsync(() async {
      container.dispose();
      await db.close();
      db = GtdDatabase(NativeDatabase(storeFile));
      container = createPeriodicReviewTestContainer(db);
      await container.read(syncedPreferencesProvider.future);
      await container.read(periodicReviewProvider.notifier).loadAllSnapshots();
    });
    expect(container.read(periodicReviewProvider).inboxNav.items, ['capture']);
  });

  testWidgets('partial review keeps progress through process death, then '
      'Everything completes the review', (tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await settleWithRealAsync(tester);
    await tap(tester, find.text('15 min'));
    await tap(tester, find.byKey(const Key('periodic_review_next_step')));

    final selected = container.read(periodicReviewProvider);
    expect(selected.inboxNav.items, ['capture']);
    expect(selected.nextNav.items!.map((todo) => todo.id).toSet(),
        {for (var index = 0; index < 6; index++) 'outcome-0$index'});
    expect(selected.waitingForNav.length + selected.somedayNav.length, 0);

    // The Inbox card exposes Skip, not Keep. Either leaves it unprocessed.
    await tap(tester, find.byKey(const Key('periodic_review_skip')));
    await tap(tester, find.byKey(const Key('periodic_review_next_step')));
    await tap(tester, find.byKey(const Key('periodic_review_next_step')));
    final keptIds = <String>[];
    for (var index = 0; index < 2; index++) {
      keptIds.add(container.read(periodicReviewProvider).nextNav.current!.id);
      await tap(tester, find.text('Keep'));
    }
    final skippedId = container.read(periodicReviewProvider).nextNav.current!.id;
    await skipToSummary(tester);
    await tap(tester, find.byKey(const Key('periodic_review_done')));
    expect(container.read(periodicReviewLastCompletedProvider), isNull);
    expect(container.read(periodicReviewIsDueProvider), isTrue);
    expect(container.read(syncedPreferencesProvider).requireValue
        .get<String>('periodic_review_open_since'), isNotNull);

    // Close the database and reopen the persisted file, as after process death.
    await tester.pumpWidget(const SizedBox.shrink());
    await settleWithRealAsync(tester);
    await tester.runAsync(() async {
      container.dispose();
      await db.close();
      db = GtdDatabase(NativeDatabase(storeFile));
      container = createPeriodicReviewTestContainer(db);
      await container.read(syncedPreferencesProvider.future);
      await container.read(periodicReviewProvider.notifier).loadAllSnapshots();
    });
    final resumed = container.read(periodicReviewProvider);
    final remainingIds = resumed.nextNav.items!.map((todo) => todo.id).toSet();
    expect(remainingIds.intersection(keptIds.toSet()), isEmpty);
    expect(remainingIds, contains(skippedId));
    expect(remainingIds.length, 10);
    expect(resumed.inboxNav.items, ['capture']);

    router.go('/review');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await settleWithRealAsync(tester);
    // Everything is the default: proceed without choosing a budget.
    await tap(tester, find.byKey(const Key('periodic_review_next_step')));
    await skipToSummary(tester);
    await tap(tester, find.byKey(const Key('periodic_review_done')));
    expect(container.read(periodicReviewLastCompletedProvider), isNotNull);
    expect(container.read(periodicReviewIsDueProvider), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await settleWithRealAsync(tester);
  });
}
