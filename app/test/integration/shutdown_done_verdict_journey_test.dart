/// Journey: Evening Shutdown's "Resolve Unfinished" step offers Done, which
/// floats the session screen's verdict sheet (#822). Real screen, real
/// in-memory store; only the database provider is overridden.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/evening_shutdown_provider.dart';
import 'package:jeeves/screens/shutdown/shutdown_ritual_screen.dart';

import '../helpers/settle.dart';
import '../test_helpers.dart';

const _userId = 'local';

Future<void> _insertOutcome(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        clarified: const Value(true),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await settleWithRealAsync(tester);
}

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late GtdDatabase db;
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, List<String> ids) async {
    for (final id in ids) {
      await _insertOutcome(db, id);
    }
    await db.focusSessionDao.openSession(userId: _userId, taskIds: ids);
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: '/shutdown',
      routes: [
        GoRoute(
          path: '/focus',
          builder: (_, _) => const Scaffold(body: Text('execution home')),
        ),
        GoRoute(
          path: '/shutdown',
          builder: (_, _) => const ShutdownRitualScreen(),
        ),
      ],
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await settleWithRealAsync(tester);
    container.read(eveningShutdownProvider.notifier).goToStep(1);
    await settleWithRealAsync(tester);
  }

  setUp(() => db = GtdDatabase(NativeDatabase.memory()));
  tearDown(() async => db.close());

  testWidgets('Outcome achieved records the Completion and leaves the list',
      (tester) async {
    await pump(tester, ['finished', 'open']);

    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Roll Over to Tomorrow'), findsOneWidget);

    await _tapVisible(tester, find.text('Done'));
    expect(find.text('Outcome achieved'), findsOneWidget);
    expect(find.text('More to do…'), findsOneWidget);
    expect(find.text('Waiting on someone…'), findsOneWidget);
    expect(find.text('Defer to Someday'), findsOneWidget);

    await tester.tap(find.text('Outcome achieved'));
    await settleWithRealAsync(tester);

    final state = container.read(eveningShutdownProvider);
    expect(state.unfinishedNav.items!.map((t) => t.id), ['open']);
    expect(state.dispositions.containsKey('finished'), isFalse);

    final finished = await tester.runAsync(
      () => db.todoDao.getTodo('finished'),
    );
    expect(finished!.doneAt, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('dismissing the sheet leaves the card and every choice in place',
      (tester) async {
    await pump(tester, ['only']);

    await _tapVisible(tester, find.text('Done'));
    expect(find.text('Outcome achieved'), findsOneWidget);

    // System back closes the sheet, not the ritual step.
    await tester.binding.handlePopRoute();
    await settleWithRealAsync(tester);

    expect(find.text('Outcome achieved'), findsNothing);
    final state = container.read(eveningShutdownProvider);
    expect(state.currentStep, 1);
    expect(state.unfinishedNav.items!.map((t) => t.id), ['only']);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Roll Over to Tomorrow'), findsOneWidget);

    final todo = await tester.runAsync(() => db.todoDao.getTodo('only'));
    expect(todo!.doneAt, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('verdict on the only task advances the ritual to Close Day',
      (tester) async {
    await pump(tester, ['only']);

    await _tapVisible(tester, find.text('Done'));
    await tester.tap(find.text('Defer to Someday'));
    await settleWithRealAsync(tester);

    final state = container.read(eveningShutdownProvider);
    expect(state.currentStep, 2);
    expect(state.dispositions['only'], 'leave');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
