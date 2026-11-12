/// Journey: Evening Shutdown's "Resolve Unfinished" step offers Done, which
/// floats the session screen's verdict sheet (#822). Real screen, real
/// in-memory store; only the database provider (and the person-tag list the
/// sheet's picker reads) is overridden.
///
/// Per docs/TESTING.md the store is staged in `setUp` — one group per scenario
/// — and read inside a test body only through `tester.runAsync`.
library;

import 'dart:async';

import 'package:drift/drift.dart'
    show QueryExecutor, QueryInterceptor, Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/evening_shutdown_provider.dart';
import 'package:jeeves/providers/tags_provider.dart' show personTagsProvider;
import 'package:jeeves/screens/shutdown/shutdown_ritual_screen.dart';

import '../helpers/settle.dart';
import '../test_helpers.dart';

const _userId = 'local';
const _nextStep = Key('shutdown_next_step');

Future<void> _insertOutcome(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        clarified: const Value(true),
        intent: const Value('next'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  await seedCurrentAction(db,
      outcomeId: id, text: 'work on $id', userId: _userId);
}

/// Holds the first `todos` UPDATE issued after [armed] is set until [release]
/// is called, so a test can dismiss the verdict sheet while the real Completion
/// write is provably still pending. Everything else passes straight through to
/// the real in-memory store.
class _HoldCompletionWrite extends QueryInterceptor {
  bool armed = false;
  final reached = Completer<void>();
  final _gate = Completer<void>();

  void release() => _gate.complete();

  Future<T> _maybeHold<T>(String statement, Future<T> Function() run) async {
    if (armed &&
        !reached.isCompleted &&
        statement.trimLeft().toUpperCase().startsWith('UPDATE') &&
        statement.contains('todos')) {
      reached.complete();
      await _gate.future;
    }
    return run();
  }

  @override
  Future<int> runUpdate(
          QueryExecutor executor, String statement, List<Object?> args) =>
      _maybeHold(statement, () => super.runUpdate(executor, statement, args));

  @override
  Future<void> runCustom(
          QueryExecutor executor, String statement, List<Object?> args) =>
      _maybeHold(statement, () => super.runCustom(executor, statement, args));
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await settleWithRealAsync(tester);
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late String sessionId;
  late ProviderContainer container;
  late _HoldCompletionWrite hold;

  /// Stages [ids] as the session Plan, all unengaged, in `setUp`.
  void scenario(String name, List<String> ids, void Function() body) {
    group(name, () {
      setUp(() async {
        SharedPreferences.setMockInitialValues({});
        hold = _HoldCompletionWrite();
        db = GtdDatabase(NativeDatabase.memory().interceptWith(hold));
        for (final id in ids) {
          await _insertOutcome(db, id);
        }
        await db.tagDao.upsertTag(TagsCompanion(
          id: const Value('alice'),
          name: const Value('Alice'),
          type: const Value('person'),
          userId: const Value(_userId),
        ));
        sessionId =
            await db.focusSessionDao.openSession(userId: _userId, taskIds: ids);
      });
      tearDown(() async => db.close());
      body();
    });
  }

  /// Mounts the real ritual and crosses to "Resolve Unfinished" with the
  /// footer's Next button.
  Future<void> mount(WidgetTester tester) async {
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      personTagsProvider.overrideWith(
        (ref) => Stream.value([
          Tag(id: 'alice', name: 'Alice', type: 'person', userId: _userId),
        ]),
      ),
    ]);
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
        GoRoute(
          path: '/focus-session-planning',
          builder: (_, _) => const Scaffold(body: Text('planning')),
        ),
      ],
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await settleWithRealAsync(tester);
    await tester.tap(find.byKey(_nextStep));
    await settleWithRealAsync(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.runAsync(() async => container.dispose());
  }

  Future<void> closeDay(WidgetTester tester) async {
    expect(container.read(eveningShutdownProvider).currentStep, 2);
    // The button fades in after the moon-rise animation.
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('Close Day'));
    await settleWithRealAsync(tester);
  }

  Future<String?> disposition(WidgetTester tester, String taskId) async {
    final rows = await tester.runAsync(() => db.customSelect(
          'SELECT disposition FROM focus_session_tasks '
          'WHERE focus_session_id = ? AND task_id = ?',
          variables: [Variable<String>(sessionId), Variable<String>(taskId)],
        ).get());
    return rows!.single.read<String?>('disposition');
  }

  Future<List<Map<String, Object?>>> actions(
      WidgetTester tester, String outcomeId) async {
    final rows = await tester.runAsync(() => db.customSelect(
          'SELECT role, text FROM actions WHERE outcome_id = ? '
          'ORDER BY created_at',
          variables: [Variable<String>(outcomeId)],
        ).get());
    return [
      for (final r in rows!)
        {
          'role': r.read<String>('role'),
          'text': r.read<String?>('text'),
        },
    ];
  }

  Future<Todo> todo(WidgetTester tester, String id) async =>
      (await tester.runAsync(() => db.todoDao.getTodo(id)))!;

  Future<void> openSheet(WidgetTester tester) async {
    await _tapVisible(tester, find.text('Done'));
    expect(find.text('Outcome achieved'), findsOneWidget);
    expect(find.text('More to do…'), findsOneWidget);
    expect(find.text('Waiting on someone…'), findsOneWidget);
    expect(find.text('Defer to Someday'), findsOneWidget);
    expect(find.textContaining('Trash'), findsNothing);
  }

  scenario('Outcome achieved', ['finished', 'open'], () {
    testWidgets('records the Completion, groups it in the summary, and Close '
        'Day gives it no Disposition', (tester) async {
      await mount(tester);

      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Roll Over to Tomorrow'), findsOneWidget);

      await openSheet(tester);
      await tester.tap(find.text('Outcome achieved'));
      await settleWithRealAsync(tester);

      final state = container.read(eveningShutdownProvider);
      expect(state.unfinishedNav.items!.map((t) => t.id), ['open']);
      expect(state.dispositions.containsKey('finished'), isFalse);
      expect((await todo(tester, 'finished')).doneAt, isNotNull);
      expect((await actions(tester, 'finished')).single['role'], 'done');

      // Back crosses to the summary, which groups the achieved task.
      await tester.tap(find.text('Back'));
      await settleWithRealAsync(tester);
      expect(container.read(eveningShutdownProvider).currentStep, 0);
      expect(find.text('COMPLETED TODAY (1)'), findsOneWidget);
      expect(find.text('Outcome finished'), findsOneWidget);

      await tester.tap(find.byKey(_nextStep));
      await settleWithRealAsync(tester);
      await _tapVisible(tester, find.text('Roll Over to Tomorrow'));
      await closeDay(tester);

      expect(await disposition(tester, 'open'), 'rollover');
      expect(await disposition(tester, 'finished'), isNull);
      await unmount(tester);
    });
  });

  scenario('More to do…', ['only'], () {
    testWidgets('completes the Action, queues the typed one, and rolls over',
        (tester) async {
      await mount(tester);
      await openSheet(tester);
      await tester.tap(find.text('More to do…'));
      await settleWithRealAsync(tester);
      await tester.enterText(find.byType(TextField).last, 'send the draft');
      await tester.tap(find.text('Save'));
      await settleWithRealAsync(tester);

      final rows = await actions(tester, 'only');
      expect(rows.first['role'], 'done', reason: 'not superseded');
      expect(rows.last, {'role': 'current', 'text': 'send the draft'});
      final row = await todo(tester, 'only');
      expect(row.intent, 'next');
      expect(row.doneAt, isNull);

      // Only task: the ritual went straight to Close Day.
      await closeDay(tester);
      expect(await disposition(tester, 'only'), 'rollover');
      await unmount(tester);
    });
  });

  scenario('Waiting on someone…', ['only'], () {
    testWidgets('tags the person, stays on Next, and leaves at close',
        (tester) async {
      await mount(tester);
      await openSheet(tester);
      await tester.tap(find.text('Waiting on someone…'));
      await settleWithRealAsync(tester);
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await settleWithRealAsync(tester);

      final tagIds = await tester
          .runAsync(() => db.todoDao.getPersonTagIdsForTodo('only'));
      expect(tagIds, contains('alice'));
      expect((await todo(tester, 'only')).intent, 'next');

      await closeDay(tester);
      expect(await disposition(tester, 'only'), 'leave');
      await unmount(tester);
    });
  });

  scenario('Defer to Someday', ['only'], () {
    testWidgets('moves to Someday and Close Day does not re-stamp it',
        (tester) async {
      await mount(tester);
      await openSheet(tester);
      await tester.tap(find.text('Defer to Someday'));
      await settleWithRealAsync(tester);

      final before = await todo(tester, 'only');
      expect(before.intent, 'maybe');
      expect(before.lastClarifiedAt, isNotNull);

      await closeDay(tester);
      expect(await disposition(tester, 'only'), 'leave');
      final after = await todo(tester, 'only');
      expect(after.intent, 'maybe');
      expect(after.lastClarifiedAt, before.lastClarifiedAt);
      await unmount(tester);
    });
  });

  scenario('Dismissed sheet', ['only'], () {
    testWidgets('keeps the card and every choice; the Action stays done',
        (tester) async {
      await mount(tester);
      await openSheet(tester);

      // System back closes the sheet, not the ritual step.
      await tester.binding.handlePopRoute();
      await settleWithRealAsync(tester);

      expect(find.text('Outcome achieved'), findsNothing);
      final state = container.read(eveningShutdownProvider);
      expect(state.currentStep, 1);
      expect(state.unfinishedNav.items!.map((t) => t.id), ['only']);
      expect(state.dispositions, isEmpty);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Roll Over to Tomorrow'), findsOneWidget);

      final row = await todo(tester, 'only');
      expect(row.doneAt, isNull);
      expect(row.lastClarifiedAt, isNull);
      expect((await actions(tester, 'only')).single['role'], 'done');
      await unmount(tester);
    });
  });

  scenario('Sheet dismissed while the verdict write is pending', ['a', 'b'], () {
    testWidgets('the landed Completion still clears an earlier Roll Over',
        (tester) async {
      await mount(tester);
      // Roll Over a, move on to b, come Back to a: the Roll Over is held.
      await _tapVisible(tester, find.text('Roll Over to Tomorrow'));
      await settleWithRealAsync(tester);
      await tester.tap(find.text('Back'));
      await settleWithRealAsync(tester);
      expect(container.read(eveningShutdownProvider).dispositions['a'],
          'rollover');

      await openSheet(tester);
      // Hold the real Completion write at the store, then dismiss the sheet
      // while it is provably pending: dismissal precedes commit by construction.
      hold.armed = true;
      await tester.tap(find.text('Outcome achieved'));
      await tester.runAsync(() => hold.reached.future
          .timeout(const Duration(seconds: 10)));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Outcome achieved'), findsNothing);
      expect((await todo(tester, 'a')).doneAt, isNull,
          reason: 'the write must still be pending when the sheet is gone');
      expect(container.read(eveningShutdownProvider).dispositions['a'],
          'rollover');

      // Let the write land. The verdict must still reach the ritual state.
      hold.release();
      await settleWithRealAsync(tester);
      expect((await todo(tester, 'a')).doneAt, isNotNull);
      final state = container.read(eveningShutdownProvider);
      expect(state.dispositions.containsKey('a'), isFalse);
      expect(state.unfinishedNav.items!.map((t) => t.id), ['b']);

      // Finish the ritual: the achieved Outcome gets no Disposition row.
      await _tapVisible(tester, find.text('Roll Over to Tomorrow'));
      await closeDay(tester);
      expect(await disposition(tester, 'a'), isNull);
      expect(await disposition(tester, 'b'), 'rollover');
      await unmount(tester);
    });
  });

  scenario('Single task achieved', ['only'], () {
    testWidgets('advances the ritual straight to Close Day', (tester) async {
      await mount(tester);
      await openSheet(tester);
      await tester.tap(find.text('Outcome achieved'));
      await settleWithRealAsync(tester);

      expect(container.read(eveningShutdownProvider).currentStep, 2);
      await closeDay(tester);
      expect(await disposition(tester, 'only'), isNull);
      await unmount(tester);
    });
  });
}
