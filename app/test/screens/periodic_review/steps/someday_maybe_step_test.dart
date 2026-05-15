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

Widget _harness(GtdDatabase db) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
    ],
    child: const MaterialApp(
      home: Scaffold(body: SomedayMaybeStep()),
    ),
  );
}

Future<ProviderContainer> _enterStep(
    WidgetTester tester, GtdDatabase db) async {
  await tester.pumpWidget(_harness(db));
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

    testWidgets('tapping "Next Action…" opens NextActionDialog',
        (tester) async {
      await _insertSomedayTodo(db, id: 'sm1');
      await _enterStep(tester, db);

      expect(find.text('Next Action…'), findsOneWidget);
      await tester.tap(find.text('Next Action…'));
      await tester.pumpAndSettle();

      expect(find.byType(NextActionDialog), findsOneWidget);
    });

    testWidgets(
        'phrase + Save routes to Next, writes next_action_text, records a '
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
      expect(row?.nextActionText, 'Sketch the first draft');

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
        'blank Save does not route and the wizard stays on the item',
        (tester) async {
      await _insertSomedayTodo(db, id: 'sm1');
      final container = await _enterStep(tester, db);

      await tester.tap(find.text('Next Action…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final state = container.read(periodicReviewProvider);
      expect(state.somedayRoutings, isEmpty,
          reason: 'a blank promotion must not record a routing');
      expect(state.somedayNav.index, 0,
          reason: 'a blank promotion must leave the cursor on the item');
      expect(state.somedayNav.isComplete, isFalse);

      // The DB row is untouched: a blank promotion neither writes a phrase
      // nor re-routes the item off Someday/Maybe.
      final row = await db.todoDao.getTodo('sm1');
      expect(row?.nextActionText, isNull);
      expect(row?.intent, 'maybe');
    });

    testWidgets('cancelling the dialog records no routing and does not advance',
        (tester) async {
      await _insertSomedayTodo(db, id: 'sm1');
      final container = await _enterStep(tester, db);

      await tester.tap(find.text('Next Action…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('sm1');
      expect(row?.nextActionText, isNull);
      expect(row?.intent, 'maybe');
      final state = container.read(periodicReviewProvider);
      expect(state.somedayRoutings, isEmpty);
      expect(state.somedayNav.index, 0);
    });
  });
}
