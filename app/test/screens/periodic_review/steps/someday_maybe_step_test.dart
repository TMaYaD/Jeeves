/// Widget tests for the Weekly Review wizard's Someday/Maybe step (#293).
///
/// Promoting a Someday/Maybe item to Next must capture a phrase via
/// [NextActionDialog] (the default-on `nextActionDialog` modifier) so the
/// freshly-promoted task does not land actionless on the Next list.
///
/// Drives the real [PeriodicReviewNotifier] over an in-memory [GtdDatabase].
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/periodic_review_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/screens/periodic_review/steps/someday_maybe_step.dart';
import 'package:jeeves/widgets/next_action_dialog.dart';

import '../../../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

/// Inserts a clarified, non-done, intent='maybe' todo — the shape
/// `watchMaybe` surfaces into the Someday/Maybe step.
Future<String> _insertSomedayTodo(
  GtdDatabase db, {
  required String id,
  String title = 'Someday idea',
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        clarified: const Value(true),
        intent: const Value('maybe'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  return id;
}

Widget _harness(
  GtdDatabase db, {
  /// See `waiting_for_step_test.dart` for the rationale — overrides the
  /// todo/tag providers for the listed IDs so the inner ClarifyCard rendered
  /// by the `reclarify` sub-flow does not subscribe to drift's `watchTodo` or
  /// tag `watch()` queries (whose timers never settle in `pumpAndSettle`).
  List<String> reclarifyIds = const [],
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      for (final id in reclarifyIds) ...[
        taskDetailTodoProvider(id).overrideWith((ref) async* {
          yield await db.todoDao.getTodo(id);
        }),
        taskTagsProvider(id).overrideWith((_) => Stream.value(const <Tag>[])),
      ],
      if (reclarifyIds.isNotEmpty) ...[
        contextTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
        projectTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
      ],
    ],
    child: const MaterialApp(
      home: Scaffold(body: SomedayMaybeStep()),
    ),
  );
}

Future<ProviderContainer> _enterStep(
  WidgetTester tester,
  GtdDatabase db, {
  List<String> reclarifyIds = const [],
}) async {
  await tester.pumpWidget(_harness(db, reclarifyIds: reclarifyIds));
  final container = ProviderScope.containerOf(
    tester.element(find.byType(SomedayMaybeStep)),
  );
  await container.read(periodicReviewProvider.notifier).loadSomedaySnapshot();
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUpAll(configureSqliteForTests);

  group('SomedayMaybeStep — promote to Next captures a phrase (#293)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'phrase + Save routes to Next, sets the current Action, records a '
        'Someday routing, and advances', (tester) async {
      await _insertSomedayTodo(db, id: 'sm1');
      final container = await _enterStep(tester, db);

      await tester.tap(find.text('Next Action…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(NextActionDialog),
          matching: find.byType(TextField),
        ),
        'Sketch the first draft',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('sm1');
      expect(row?.intent, 'next');
      expect((await db.actionDao.getCurrentAction('sm1'))?.actionText,
          'Sketch the first draft');

      // The whole point of #293: a phrase-backed promotion does not land
      // the task actionless on the Next list, so it stays out of the daily
      // re-clarification queue.
      final needsReview = await db.todoDao.getNeedsReview();
      expect(needsReview.map((t) => t.id), isNot(contains('sm1')));

      final state = container.read(periodicReviewProvider);
      expect(state.somedayRoutings[0], RoutingKind.nextAction);
      expect(state.somedayNav.isComplete, isTrue);
    });

    testWidgets(
        'promoting a queued planned Action routes the item to Next (the '
        '_commit leg), makes it current, records nextAction, and advances '
        '(#723)', (tester) async {
      await _insertSomedayTodo(db, id: 'sm2');
      // A planned Action queued on the Someday item, no current Action.
      await seedPlannedAction(
        db,
        outcomeId: 'sm2',
        text: 'Draft the first section',
        userId: _userId,
        id: 'sp1',
        position: 0,
      );
      final container = await _enterStep(tester, db);

      await tester.tap(find.text('Next Action…'));
      await tester.pumpAndSettle();
      // The queue is offered; promote it.
      expect(find.text('Draft the first section'), findsOneWidget);
      await tester.tap(find.text('Draft the first section'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('sm2');
      // The `_commit(nextAction)` leg is what moves the Outcome off Someday —
      // without it a promote would flip the planned row to current while the
      // item stayed on `maybe`. This assertion is what fails if it is skipped.
      expect(row?.intent, 'next');
      expect((await db.actionDao.getCurrentAction('sm2'))?.actionText,
          'Draft the first section');
      expect(await db.actionDao.getPlannedActions('sm2'), isEmpty);

      final state = container.read(periodicReviewProvider);
      expect(state.somedayRoutings[0], RoutingKind.nextAction);
      expect(state.somedayNav.isComplete, isTrue);
    });
  });

  group('SomedayMaybeStep — Done route (#457)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    /// Enlarge the test viewport so all five action-bar buttons (Keep on
    /// Someday, Re-clarify…, Next Action…, Done, Trash) fit on screen for
    /// `tester.tap`.
    Future<void> useTallViewport(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    }

    testWidgets(
        'the action bar offers Done alongside the other Someday routes',
        (tester) async {
      await useTallViewport(tester);
      await _insertSomedayTodo(db, id: 'sm1');
      await _enterStep(tester, db);

      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Keep on Someday'), findsOneWidget);
      expect(find.text('Re-clarify…'), findsOneWidget);
      expect(find.text('Next Action…'), findsOneWidget);
      expect(find.text('Trash'), findsOneWidget);
    });

    testWidgets(
        'tapping Done stamps Completion, leaves intent=maybe, and moves the '
        'item from watchMaybe to watchDone', (tester) async {
      await useTallViewport(tester);
      await _insertSomedayTodo(db, id: 'sm1');
      await _enterStep(tester, db);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('sm1');
      expect(row?.doneAt, isNotNull,
          reason: 'Done stamps the Outcome\'s Completion');
      expect(row?.intent, 'maybe',
          reason: 'Completion ⊥ Intent — Done does not touch intent');

      // The item leaves Someday/Maybe and surfaces on the Done List. Read the
      // drift streams under `runAsync` so their query timers run on the real
      // event loop (they never settle under fake test time, and would
      // otherwise trip the pending-timer check at teardown).
      final (maybeIds, doneIds) = (await tester.runAsync(() async {
        final maybe = await db.todoDao.watchMaybe().first;
        final done = await db.todoDao.watchDone().first;
        return (
          maybe.map((t) => t.id).toList(),
          done.map((t) => t.id).toList(),
        );
      }))!;
      expect(maybeIds, isNot(contains('sm1')));
      expect(doneIds, contains('sm1'));
    });

    testWidgets(
        'tapping Done records a Done routing and advances the cursor',
        (tester) async {
      await useTallViewport(tester);
      await _insertSomedayTodo(db, id: 'sm1');
      final container = await _enterStep(tester, db);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      final state = container.read(periodicReviewProvider);
      expect(state.somedayRoutings[0], RoutingKind.done);
      expect(state.somedayNav.isComplete, isTrue);
    });
  });
}
