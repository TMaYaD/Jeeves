/// Widget tests for the [TaskReviewStep] stale-waiting-for branch (#289).
///
/// Drives the real notifier with an in-memory [GtdDatabase] so the snapshot,
/// person-tag plumbing, and card render exercise the production path.
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

import '../../../test_helpers.dart';

const _userId = 'local';

const _staleTaskClarifiedOffset = Duration(hours: 2);
const _staleTaskCompletedOffset = Duration(hours: 1);

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<String> _insertClarifiedTask(
  GtdDatabase db, {
  String? nextActionText,
  DateTime? lastNextActionCompletionAt,
  DateTime? lastClarifiedAt,
  String title = 'Task',
}) async {
  final now = DateTime.now();
  final id = 'task-${now.microsecondsSinceEpoch}-$title';
  await db.into(db.todos).insert(TodosCompanion(
    id: Value(id),
    title: Value(title),
    userId: const Value(_userId),
    clarified: const Value(true),
    intent: const Value('next'),
    createdAt: Value(now),
    nextActionText:
        nextActionText != null ? Value(nextActionText) : const Value.absent(),
    lastNextActionCompletionAt: lastNextActionCompletionAt != null
        ? Value(lastNextActionCompletionAt)
        : const Value.absent(),
    lastClarifiedAt:
        lastClarifiedAt != null ? Value(lastClarifiedAt) : const Value.absent(),
  ));
  return id;
}

Future<void> _attachPersonTag(
  GtdDatabase db,
  String todoId, {
  required String name,
  required String tagId,
}) async {
  await db.into(db.tags).insert(TagsCompanion(
    id: Value(tagId),
    name: Value(name),
    type: const Value('person'),
    userId: const Value(_userId),
  ));
  await db.into(db.todoTags).insert(TodoTagsCompanion(
    id: Value('tt-$tagId-$todoId'),
    todoId: Value(todoId),
    tagId: Value(tagId),
    userId: const Value(_userId),
  ));
}

Widget _harness(GtdDatabase db) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
    ],
    child: const MaterialApp(
      home: Scaffold(body: TaskReviewStep()),
    ),
  );
}

/// Loads the review snapshot via the real notifier so the card renders against
/// the same plumbing the planning ritual uses in production.
Future<void> _enterReviewStep(WidgetTester tester, GtdDatabase db) async {
  await tester.pumpWidget(_harness(db));
  // Grab the notifier from the running ProviderScope element.
  final container = ProviderScope.containerOf(
    tester.element(find.byType(TaskReviewStep)),
  );
  await container.read(focusSessionPlanningProvider.notifier).advanceStep();
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(configureSqliteForTests);

  group('TaskReviewStep — staleWaitingFor variant (#289)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'stale delegated task renders waiting-for badge with delegate name '
        'and "Still waiting" keep label', (tester) async {
      final clarifiedAt =
          DateTime.now().subtract(_staleTaskClarifiedOffset).toUtc();
      final completedAt =
          DateTime.now().subtract(_staleTaskCompletedOffset).toUtc();
      final id = await _insertClarifiedTask(
        db,
        nextActionText: 'Email Trixy',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
        title: 'Waiting on Trixy',
      );
      await _attachPersonTag(db, id, name: 'Trixy', tagId: 'p-trixy');

      await _enterReviewStep(tester, db);

      expect(find.textContaining('Waiting for Trixy'), findsOneWidget,
          reason: 'badge should name the delegate');
      expect(find.textContaining('still waiting?'), findsOneWidget,
          reason: 'badge should pose the keep prompt');

      // Keep button is relabelled "Still waiting" for the delegated variant.
      expect(find.text('Still waiting'), findsOneWidget);
      expect(find.text('Still relevant'), findsNothing);
    });

    testWidgets(
        'stale non-delegated task still renders "Still relevant" keep label',
        (tester) async {
      final clarifiedAt =
          DateTime.now().subtract(_staleTaskClarifiedOffset).toUtc();
      final completedAt =
          DateTime.now().subtract(_staleTaskCompletedOffset).toUtc();
      await _insertClarifiedTask(
        db,
        nextActionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
        title: 'No delegate stale',
      );

      await _enterReviewStep(tester, db);

      expect(find.text('Still relevant'), findsOneWidget);
      expect(find.text('Still waiting'), findsNothing);
      expect(find.text('Updated since last clarified'), findsOneWidget);
    });

    testWidgets(
        'actionless non-delegated task omits both keep variants',
        (tester) async {
      await _insertClarifiedTask(
        db,
        nextActionText: null,
        title: 'Actionless',
      );

      await _enterReviewStep(tester, db);

      expect(find.text('Still relevant'), findsNothing);
      expect(find.text('Still waiting'), findsNothing);
      expect(find.text('No next action defined'), findsOneWidget);
    });

    testWidgets(
        'recently-clarified delegated task is filtered out of the review queue',
        (tester) async {
      // Same shape as the stale-delegated case, but lastClarifiedAt is AFTER
      // lastNextActionCompletionAt — so the staleness filter must exclude it.
      final completedAt =
          DateTime.now().subtract(_staleTaskCompletedOffset).toUtc();
      final clarifiedAt = DateTime.now().toUtc();
      final id = await _insertClarifiedTask(
        db,
        nextActionText: 'Email Trixy',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
        title: 'Recently re-clarified',
      );
      await _attachPersonTag(db, id, name: 'Trixy', tagId: 'p-trixy');

      await _enterReviewStep(tester, db);

      // Task must not surface in the snapshot — no waiting-for badge, no
      // keep variants, and the empty-state card is shown instead.
      expect(find.textContaining('Waiting for Trixy'), findsNothing);
      expect(find.text('Still waiting'), findsNothing);
      expect(find.text('Still relevant'), findsNothing);
      expect(find.text('All tasks reviewed!'), findsOneWidget);
    });

    testWidgets(
        'stale delegated task with multiple person tags joins names with comma',
        (tester) async {
      final clarifiedAt =
          DateTime.now().subtract(_staleTaskClarifiedOffset).toUtc();
      final completedAt =
          DateTime.now().subtract(_staleTaskCompletedOffset).toUtc();
      final id = await _insertClarifiedTask(
        db,
        nextActionText: 'Sync with team',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
        title: 'Multi-delegate',
      );
      // Tag names are returned ORDER BY name ASC by getPersonTagsForTodos.
      await _attachPersonTag(db, id, name: 'Alice', tagId: 'p-alice');
      await _attachPersonTag(db, id, name: 'Bob', tagId: 'p-bob');

      await _enterReviewStep(tester, db);

      expect(find.textContaining('Waiting for Alice, Bob'), findsOneWidget);
    });
  });
}
