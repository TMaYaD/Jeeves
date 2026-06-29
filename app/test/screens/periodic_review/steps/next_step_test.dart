/// Widget tests for the Weekly Review wizard's Next Actions step.
///
/// Covers the per-item action bar — including the `Re-clarify…` sub-flow
/// added in #294 — over the real [PeriodicReviewNotifier] and an in-memory
/// [GtdDatabase].
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/periodic_review_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/screens/periodic_review/steps/next_step.dart';
import 'package:jeeves/widgets/clarify_card.dart';

import '../../../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

/// Inserts a clarified, non-done, intent='next' todo with no person tag —
/// the shape `getNextExcludingPersonTagged` surfaces into the step.
Future<String> _insertNextActionTodo(
  GtdDatabase db, {
  required String id,
  String title = 'Plain next action',
  String? nextActionText,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        clarified: const Value(true),
        intent: const Value('next'),
        nextActionText:
            nextActionText != null ? Value(nextActionText) : const Value.absent(),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  return id;
}

Widget _harness(
  GtdDatabase db, {
  /// Override `taskDetailTodoProvider` for the listed IDs so the inner
  /// ClarifyCard rendered by the `reclarify` sub-flow does not subscribe
  /// to drift's `watchTodo` (whose recurring timer never settles in
  /// `pumpAndSettle`).
  List<String> reclarifyIds = const [],
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      for (final id in reclarifyIds)
        taskDetailTodoProvider(id).overrideWith((ref) async* {
          yield await db.todoDao.getTodo(id);
        }),
    ],
    child: const MaterialApp(
      home: Scaffold(body: NextStep()),
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
    tester.element(find.byType(NextStep)),
  );
  await container
      .read(periodicReviewProvider.notifier)
      .loadNextSnapshot();
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUpAll(configureSqliteForTests);

  group('NextStep — Re-clarify… sub-flow (#294)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    /// Enlarge the test viewport so the sub-flow's bottom action buttons
    /// (Trash, Done…) fit on screen for `tester.tap`.
    Future<void> useTallViewport(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    }

    testWidgets('Re-clarify… is rendered as a button on the action bar',
        (tester) async {
      await _insertNextActionTodo(db, id: 'na1');
      await _enterStep(tester, db);

      expect(find.text('Re-clarify…'), findsOneWidget);
    });

    testWidgets(
        'tapping Re-clarify… opens the ClarifyCard sub-flow on this item',
        (tester) async {
      await useTallViewport(tester);
      await _insertNextActionTodo(db, id: 'na1');
      await _enterStep(tester, db, reclarifyIds: const ['na1']);

      await tester.tap(find.text('Re-clarify…'));
      await tester.pumpAndSettle();

      expect(find.byType(ClarifyCard), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Re-clarify'), findsOneWidget);
    });

    testWidgets(
        'routing to Someday inside the sub-flow records the routing and '
        'advances the cursor', (tester) async {
      await useTallViewport(tester);
      await _insertNextActionTodo(db, id: 'na1');
      final container =
          await _enterStep(tester, db, reclarifyIds: const ['na1']);

      await tester.tap(find.text('Re-clarify…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Someday'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('na1');
      expect(row?.intent, 'maybe');

      final state = container.read(periodicReviewProvider);
      expect(state.nextRoutings[0], RoutingKind.maybe);
      expect(state.nextNav.isComplete, isTrue);
    });

    testWidgets(
        'backing out of the sub-flow records no routing and advances like keep',
        (tester) async {
      await useTallViewport(tester);
      await _insertNextActionTodo(db, id: 'na1');
      final container =
          await _enterStep(tester, db, reclarifyIds: const ['na1']);

      await tester.tap(find.text('Re-clarify…'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      final state = container.read(periodicReviewProvider);
      expect(state.nextRoutings, isEmpty,
          reason: 'a back-out of the sub-flow records no routing');
      expect(state.nextNav.isComplete, isTrue);
      final row = await db.todoDao.getTodo('na1');
      expect(row?.intent, 'next');
    });

    testWidgets(
        'editing the title in the sub-flow persists via TodoDao on dispose',
        (tester) async {
      await useTallViewport(tester);
      await _insertNextActionTodo(
        db,
        id: 'na1',
        title: 'Old title',
        nextActionText: 'Email Bob',
      );
      await _enterStep(tester, db, reclarifyIds: const ['na1']);

      await tester.tap(find.text('Re-clarify…'));
      await tester.pumpAndSettle();

      // Edit the title field in the sub-flow.
      await tester.enterText(
        find.byType(TextField).first,
        'Updated title',
      );
      // Wait past the autosave debounce so the DAO write commits.
      await tester.pump(const Duration(milliseconds: 600));

      // Back out without routing — autosaved edits must persist.
      await tester.pageBack();
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('na1');
      expect(row?.title, 'Updated title');
      // Mirror guard: existing next_action_text was non-empty, so the
      // ClarifyMode.reclarify back-out (no route) leaves it untouched.
      expect(row?.nextActionText, 'Email Bob');
    });
  });
}
