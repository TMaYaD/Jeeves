/// Journey tests for the blank next-action save on the daily planning ritual's
/// Task Review step (issue #691).
///
/// Saving [NextActionDialog] empty means "the title is the action": the item
/// resolves to Next, the Outcome's own title stands in as the current Action,
/// and the review advances. Cancelling is the distinct act that leaves the item
/// unresolved — the two must never collapse into one another.
///
/// Drives the real notifier over an in-memory [GtdDatabase] so the snapshot,
/// routing write and Action mirror all exercise the production path.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/planning/steps/task_review_step.dart';
import 'package:jeeves/widgets/next_action_dialog.dart';

import '../../../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

/// Inserts a clarified, Actionless, `intent='next'` Outcome — the shape the
/// re-clarification queue surfaces as "No next action defined".
///
/// [createdAt] fixes the snapshot order (`getNeedsReview` sorts by
/// `created_at`), so a two-item journey knows which card it is looking at.
Future<String> _insertActionlessTask(
  GtdDatabase db, {
  required String id,
  required String title,
  required DateTime createdAt,
}) async {
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        userId: const Value(_userId),
        clarified: const Value(true),
        intent: const Value('next'),
        createdAt: Value(createdAt),
        updatedAt: Value(createdAt),
      ));
  return id;
}

Widget _harness(GtdDatabase db) => ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(
        home: Scaffold(body: TaskReviewStep()),
      ),
    );

/// Loads the review snapshot via the real notifier: intro (0) → Clarify Inbox
/// (1) → Review Tasks (2).
Future<void> _enterReviewStep(WidgetTester tester, GtdDatabase db) async {
  await tester.pumpWidget(_harness(db));
  final container = ProviderScope.containerOf(
    tester.element(find.byType(TaskReviewStep)),
  );
  final notifier = container.read(focusSessionPlanningProvider.notifier);
  await notifier.advanceStep();
  await notifier.advanceStep();
  await tester.pumpAndSettle();
}

Future<void> _openNextActionDialog(WidgetTester tester) async {
  await tester.tap(find.text('Update next action…'));
  await tester.pumpAndSettle();
  expect(find.byType(NextActionDialog), findsOneWidget);
}

void main() {
  setUpAll(configureSqliteForTests);

  group('TaskReviewStep — blank next-action save (#691)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'blank Save resolves the item to Next with the title as its Action '
        'and advances to the next item', (tester) async {
      final base = DateTime.now().toUtc().subtract(const Duration(days: 1));
      await _insertActionlessTask(
        db,
        id: 'r1',
        title: 'Call the dentist',
        createdAt: base,
      );
      await _insertActionlessTask(
        db,
        id: 'r2',
        title: 'Renew the parking permit',
        createdAt: base.add(const Duration(minutes: 1)),
      );

      await _enterReviewStep(tester, db);
      expect(find.text('Call the dentist'), findsOneWidget);

      await _openNextActionDialog(tester);
      // Save with the field untouched — the blank save under test.
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Advanced: the card now renders the second item.
      expect(find.text('Renew the parking permit'), findsOneWidget);
      expect(find.text('Call the dentist'), findsNothing);

      // Resolved: routed to Next, clarified, stamped.
      final row = await db.todoDao.getTodo('r1');
      expect(row?.intent, 'next');
      expect(row?.clarified, isTrue);
      expect(row?.lastClarifiedAt, isNotNull);

      // Not actionless: the Outcome title stands in as the current Action.
      expect((await db.actionDao.getCurrentAction('r1'))?.actionText,
          'Call the dentist');
    });

    testWidgets(
        'a resolved item leaves the re-clarification queue and does not '
        're-arm', (tester) async {
      await _insertActionlessTask(
        db,
        id: 'r1',
        title: 'Call the dentist',
        createdAt: DateTime.now().toUtc().subtract(const Duration(days: 1)),
      );

      await _enterReviewStep(tester, db);
      expect(await db.todoDao.getNeedsReview(), hasLength(1));

      await _openNextActionDialog(tester);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(await db.todoDao.getNeedsReview(), isEmpty,
          reason: 'the Actionless branch of _needsReviewWhere has no freshness '
              'gate, so an item left Actionless would re-surface on the same '
              'card every day — the stall this issue removes');
    });

    testWidgets('cancelling leaves the item unresolved and does not advance',
        (tester) async {
      await _insertActionlessTask(
        db,
        id: 'r1',
        title: 'Call the dentist',
        createdAt: DateTime.now().toUtc().subtract(const Duration(days: 1)),
      );

      await _enterReviewStep(tester, db);

      await _openNextActionDialog(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Still on the same item.
      expect(find.text('Call the dentist'), findsOneWidget);

      final row = await db.todoDao.getTodo('r1');
      expect(row?.lastClarifiedAt, isNull,
          reason: 'cancel writes nothing at all');
      expect(await db.actionDao.getCurrentAction('r1'), isNull);
      expect(await db.todoDao.getNeedsReview(), hasLength(1));
    });

    testWidgets(
        'a non-blank Save writes the phrase and advances (unchanged)',
        (tester) async {
      final base = DateTime.now().toUtc().subtract(const Duration(days: 1));
      await _insertActionlessTask(
        db,
        id: 'r1',
        title: 'Call the dentist',
        createdAt: base,
      );
      await _insertActionlessTask(
        db,
        id: 'r2',
        title: 'Renew the parking permit',
        createdAt: base.add(const Duration(minutes: 1)),
      );

      await _enterReviewStep(tester, db);
      await _openNextActionDialog(tester);
      await tester.enterText(
        find.descendant(
          of: find.byType(NextActionDialog),
          matching: find.byType(TextField),
        ),
        'Look up the surgery number',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Renew the parking permit'), findsOneWidget);
      expect((await db.actionDao.getCurrentAction('r1'))?.actionText,
          'Look up the surgery number',
          reason: 'a typed phrase always wins over the title fallback');
      expect((await db.todoDao.getTodo('r1'))?.intent, 'next');
    });
  });
}
