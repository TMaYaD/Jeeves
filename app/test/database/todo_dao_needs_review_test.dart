import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

const _userId = 'test-user';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

/// Inserts a clarified, non-done next-action task and returns its id.
Future<String> _insertClarifiedTask(
  GtdDatabase db, {
  String? nextActionText,
  DateTime? lastNextActionCompletionAt,
  DateTime? lastClarifiedAt,
  String intent = 'next',
}) async {
  final now = DateTime.now();
  final id = 'task-${now.microsecondsSinceEpoch}';
  await db.into(db.todos).insert(TodosCompanion(
    id: Value(id),
    title: Value('Task $id'),
    userId: Value(_userId),
    clarified: const Value(true),
    intent: Value(intent),
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

void main() {
  setUpAll(configureSqliteForTests);

  group('TodoDao.watchNeedsReview and getNeedsReviewCount', () {
    late GtdDatabase db;

    setUp(() {
      db = _openInMemory();
    });

    tearDown(() => db.close());

    // Fixture 1: Fresh task processed through inbox-clarify does not surface.
    test('1: task with next_action_text set, no session history — not in result',
        () async {
      await _insertClarifiedTask(
        db,
        nextActionText: 'Buy milk',
        lastNextActionCompletionAt: null,
      );

      final result = await db.todoDao.watchNeedsReview().first;
      expect(result, isEmpty);
      expect(await db.todoDao.getNeedsReviewCount(), 0);
    });

    // Fixture 2: Stale task (session closed after last clarification).
    test('2: stale task (lastNextActionCompletionAt > lastClarifiedAt) — in result with updatedSinceClarified hint',
        () async {
      final clarifiedAt =
          DateTime.now().subtract(const Duration(hours: 2)).toUtc();
      final completedAt =
          DateTime.now().subtract(const Duration(hours: 1)).toUtc();
      final id = await _insertClarifiedTask(
        db,
        nextActionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
      );

      final result = await db.todoDao.watchNeedsReview().first;
      expect(result, hasLength(1));
      expect(result.first.id, id);
      expect(result.first.nextActionText, isNotNull);
      expect(await db.todoDao.getNeedsReviewCount(), 1);
    });

    // Fixture 3: Stale task with no next_action_text — Actionless + Stale.
    test('3: stale task with next_action_text NULL — in result with noNextAction hint (both branches)',
        () async {
      final clarifiedAt =
          DateTime.now().subtract(const Duration(hours: 2)).toUtc();
      final completedAt =
          DateTime.now().subtract(const Duration(hours: 1)).toUtc();
      final id = await _insertClarifiedTask(
        db,
        nextActionText: null,
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
      );

      final result = await db.todoDao.watchNeedsReview().first;
      expect(result, hasLength(1));
      expect(result.first.id, id);
      expect(result.first.nextActionText, isNull);
    });

    // Fixture 4: Non-person (organising) tag added — does not affect timestamps.
    test('4: stale task after non-person tag added — still in result', () async {
      final clarifiedAt =
          DateTime.now().subtract(const Duration(hours: 2)).toUtc();
      final completedAt =
          DateTime.now().subtract(const Duration(hours: 1)).toUtc();
      final id = await _insertClarifiedTask(
        db,
        nextActionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
      );

      // Add a context tag (organising — does not stamp last_clarified_at).
      await db.into(db.tags).insert(TagsCompanion(
        id: const Value('ctx-tag'),
        name: const Value('Work'),
        type: const Value('context'),
        userId: Value(_userId),
      ));
      await db.into(db.todoTags).insert(TodoTagsCompanion(
        id: const Value('tt-1'),
        todoId: Value(id),
        tagId: const Value('ctx-tag'),
        userId: Value(_userId),
      ));

      final result = await db.todoDao.watchNeedsReview().first;
      expect(result.any((t) => t.id == id), isTrue);
    });

    // Fixture 5: "Still relevant" on a stale task — no longer in result.
    test('5: "still relevant" stamps lastClarifiedAt — task leaves result',
        () async {
      final clarifiedAt =
          DateTime.now().subtract(const Duration(hours: 2)).toUtc();
      final completedAt =
          DateTime.now().subtract(const Duration(hours: 1)).toUtc();
      final id = await _insertClarifiedTask(
        db,
        nextActionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
      );

      expect(await db.todoDao.watchNeedsReview().first, hasLength(1));

      await db.todoDao.stampLastClarifiedAt(id);

      final result = await db.todoDao.watchNeedsReview().first;
      expect(result, isEmpty);
    });

    // Fixture 6: "Update next action" on an Actionless task — leaves result.
    test('6: setNextActionText on actionless task — task leaves result', () async {
      final id = await _insertClarifiedTask(
        db,
        nextActionText: null,
        lastNextActionCompletionAt: null,
      );

      expect(await db.todoDao.watchNeedsReview().first, hasLength(1));

      await db.todoDao.setNextActionText(id,'Draft proposal');

      final result = await db.todoDao.watchNeedsReview().first;
      expect(result, isEmpty);
    });

    // Fixture 7: Done task does not surface.
    test('7: done task — not in result', () async {
      final id = await _insertClarifiedTask(db, nextActionText: null);
      await db.todoDao.markDone(id);

      final result = await db.todoDao.watchNeedsReview().first;
      expect(result, isEmpty);
    });

    // Fixture 8: Trashed task does not surface.
    test('8: trashed task — not in result', () async {
      final id = await _insertClarifiedTask(db, nextActionText: null);
      await db.customUpdate(
        "UPDATE todos SET intent = 'trash' WHERE id = ? AND user_id = ?",
        variables: [Variable(id), Variable(_userId)],
        updates: {db.todos},
      );

      final result = await db.todoDao.watchNeedsReview().first;
      expect(result, isEmpty);
    });

    // Fixture 9: Inbox item (clarified = false) does not surface.
    test('9: inbox item (clarified = false) — not in result', () async {
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
        id: const Value('inbox-task'),
        title: const Value('Unclarified'),
        userId: Value(_userId),
        clarified: const Value(false),
        createdAt: Value(now),
      ));

      final result = await db.todoDao.watchNeedsReview().first;
      expect(result, isEmpty);
    });

    // Fixture 10: Pure Actionless without any session history — DOES surface.
    test('10: actionless task (next_action_text NULL, no session) — in result',
        () async {
      final id = await _insertClarifiedTask(
        db,
        nextActionText: null,
        lastNextActionCompletionAt: null,
        lastClarifiedAt: null,
      );

      final result = await db.todoDao.watchNeedsReview().first;
      expect(result, hasLength(1));
      expect(result.first.id, id);
      expect(result.first.nextActionText, isNull);
      expect(await db.todoDao.getNeedsReviewCount(), 1);
    });

    // markDone stamps last_clarified_at — task leaves result.
    test('markDone stamps lastClarifiedAt — task leaves result', () async {
      final clarifiedAt =
          DateTime.now().subtract(const Duration(hours: 2)).toUtc();
      final completedAt =
          DateTime.now().subtract(const Duration(hours: 1)).toUtc();
      final id = await _insertClarifiedTask(
        db,
        nextActionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
      );

      expect(await db.todoDao.watchNeedsReview().first, hasLength(1));
      await db.todoDao.markDone(id);

      final result = await db.todoDao.watchNeedsReview().first;
      expect(result, isEmpty);
    });

    // deferTaskToMaybe stamps last_clarified_at — stale task leaves result.
    test('deferTaskToMaybe stamps lastClarifiedAt — stale task leaves result',
        () async {
      final clarifiedAt =
          DateTime.now().subtract(const Duration(hours: 2)).toUtc();
      final completedAt =
          DateTime.now().subtract(const Duration(hours: 1)).toUtc();
      final id = await _insertClarifiedTask(
        db,
        nextActionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
      );

      expect(await db.todoDao.watchNeedsReview().first, hasLength(1));
      await db.todoDao.deferTaskToMaybe(id);

      final result = await db.todoDao.watchNeedsReview().first;
      expect(result, isEmpty);
    });

    // Deferred Actionless task does NOT re-surface — maybe tasks are excluded.
    test('deferred actionless task leaves result after deferTaskToMaybe', () async {
      final id = await _insertClarifiedTask(
        db,
        nextActionText: null,
        lastNextActionCompletionAt: null,
      );

      await db.todoDao.deferTaskToMaybe(id);

      // After deferring, intent = 'maybe'. The predicate requires intent = 'next',
      // so the task is excluded regardless of the Actionless branch.
      final result = await db.todoDao.watchNeedsReview().first;
      expect(result.any((t) => t.id == id), isFalse);
    });

    // updateFields title change stamps last_clarified_at — stale task leaves result.
    test('updateFields title change stamps lastClarifiedAt — stale task leaves result',
        () async {
      final clarifiedAt =
          DateTime.now().subtract(const Duration(hours: 2)).toUtc();
      final completedAt =
          DateTime.now().subtract(const Duration(hours: 1)).toUtc();
      final id = await _insertClarifiedTask(
        db,
        nextActionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
      );

      expect(await db.todoDao.watchNeedsReview().first, hasLength(1));

      await db.todoDao.updateFields(id,title: 'Renamed task');

      final result = await db.todoDao.watchNeedsReview().first;
      expect(result, isEmpty);
    });

    // updateFields notes-only change does NOT remove a stale task.
    test('updateFields notes-only change does not remove stale task', () async {
      final clarifiedAt =
          DateTime.now().subtract(const Duration(hours: 2)).toUtc();
      final completedAt =
          DateTime.now().subtract(const Duration(hours: 1)).toUtc();
      final id = await _insertClarifiedTask(
        db,
        nextActionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
      );

      await db.todoDao.updateFields(id,notes: 'Added a note');

      final result = await db.todoDao.watchNeedsReview().first;
      expect(result.any((t) => t.id == id), isTrue);
    });

    // isNeedsReview returns correct values.
    test('isNeedsReview returns true for actionless task, false after fix', () async {
      final id = await _insertClarifiedTask(db, nextActionText: null);

      expect(await db.todoDao.isNeedsReview(id), isTrue);

      await db.todoDao.setNextActionText(id,'Do something');

      expect(await db.todoDao.isNeedsReview(id), isFalse);
    });
  });
}
