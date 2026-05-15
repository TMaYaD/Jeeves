/// Widget tests for the Weekly Review wizard's Waiting For step (#293).
///
/// Promoting a Waiting For item to Next must capture a phrase via
/// [NextActionDialog] (the default-on `nextActionDialog` modifier) so the
/// freshly-promoted task does not land actionless on the Next list.
///
/// Drives the real [PeriodicReviewNotifier] over an in-memory [GtdDatabase]
/// so the snapshot, person-tag plumbing, and card render exercise the
/// production path.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/periodic_review_provider.dart';
import 'package:jeeves/screens/periodic_review/steps/waiting_for_step.dart';
import 'package:jeeves/widgets/next_action_dialog.dart';

import '../../../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

/// Inserts a clarified, non-done, intent='next' todo carrying a single
/// person tag — the exact shape `watchPersonTagged` surfaces into the
/// Waiting For step.
Future<String> _insertWaitingForTodo(
  GtdDatabase db, {
  required String id,
  String title = 'Delegated task',
  String personName = 'Trixy',
  String personTagId = 'p-trixy',
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        clarified: const Value(true),
        intent: const Value('next'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  await db.into(db.tags).insert(TagsCompanion(
        id: Value(personTagId),
        name: Value(personName),
        type: const Value('person'),
        userId: const Value(_userId),
      ));
  await db.into(db.todoTags).insert(TodoTagsCompanion(
        id: Value('tt-$personTagId-$id'),
        todoId: Value(id),
        tagId: Value(personTagId),
        userId: const Value(_userId),
      ));
  return id;
}

Widget _harness(GtdDatabase db) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
    ],
    child: const MaterialApp(
      home: Scaffold(body: WaitingForStep()),
    ),
  );
}

/// Pumps the step and loads the Waiting For snapshot via the real notifier
/// so the card renders against the production plumbing.
Future<ProviderContainer> _enterStep(
    WidgetTester tester, GtdDatabase db) async {
  await tester.pumpWidget(_harness(db));
  final container = ProviderScope.containerOf(
    tester.element(find.byType(WaitingForStep)),
  );
  await container.read(periodicReviewProvider.notifier).loadWaitingForSnapshot();
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUpAll(configureSqliteForTests);

  group('WaitingForStep — promote to Next captures a phrase (#293)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets('tapping "Next Action…" opens NextActionDialog',
        (tester) async {
      await _insertWaitingForTodo(db, id: 'wf1');
      await _enterStep(tester, db);

      expect(find.text('Next Action…'), findsOneWidget);
      await tester.tap(find.text('Next Action…'));
      await tester.pumpAndSettle();

      expect(find.byType(NextActionDialog), findsOneWidget);
    });

    testWidgets(
        'phrase + Save writes next_action_text, keeps the person tag, '
        'records a Next routing, and advances', (tester) async {
      await _insertWaitingForTodo(db, id: 'wf1');
      final container = await _enterStep(tester, db);

      await tester.tap(find.text('Next Action…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(NextActionDialog),
          matching: find.byType(TextField),
        ),
        'Call Trixy for an update',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('wf1');
      expect(row?.nextActionText, 'Call Trixy for an update');
      expect(row?.intent, 'next');

      // intent ⊥ delegate: promoting to Next must not strip the delegate.
      final tagIds = await db.todoDao.getPersonTagIdsForTodo('wf1');
      expect(tagIds, contains('p-trixy'),
          reason: 'promotion to Next must keep the person tag attached');

      // #293: a phrase-backed promotion keeps the task out of the daily
      // re-clarification queue.
      final needsReview = await db.todoDao.getNeedsReview();
      expect(needsReview.map((t) => t.id), isNot(contains('wf1')));

      final state = container.read(periodicReviewProvider);
      expect(state.waitingForRoutings[0], RoutingKind.nextAction);
      expect(state.waitingForNav.isComplete, isTrue,
          reason: 'a phrase-backed promotion advances the cursor');
    });

    testWidgets(
        'blank Save records no routing and the wizard stays on the item',
        (tester) async {
      await _insertWaitingForTodo(db, id: 'wf1');
      final container = await _enterStep(tester, db);

      await tester.tap(find.text('Next Action…'));
      await tester.pumpAndSettle();
      // Save without typing anything — blank phrase.
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final state = container.read(periodicReviewProvider);
      expect(state.waitingForRoutings, isEmpty,
          reason: 'a blank promotion must not record a routing');
      expect(state.waitingForNav.index, 0,
          reason: 'a blank promotion must leave the cursor on the item');
      expect(state.waitingForNav.isComplete, isFalse);

      // The DB row is untouched: a blank promotion neither writes a phrase
      // nor re-routes the item off Waiting For.
      final row = await db.todoDao.getTodo('wf1');
      expect(row?.nextActionText, isNull);
      expect(row?.intent, 'next');
    });

    testWidgets('cancelling the dialog records no routing and does not advance',
        (tester) async {
      await _insertWaitingForTodo(db, id: 'wf1');
      final container = await _enterStep(tester, db);

      await tester.tap(find.text('Next Action…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('wf1');
      expect(row?.nextActionText, isNull);
      final state = container.read(periodicReviewProvider);
      expect(state.waitingForRoutings, isEmpty);
      expect(state.waitingForNav.index, 0);
    });
  });
}
