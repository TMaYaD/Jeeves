import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show RoutingKind;
import '../test_helpers.dart';

const _userId = 'test-user';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

/// Inserts a clarified, non-done next-action task and returns its id.
///
/// A non-blank [actionText] seeds a matching `current` Action row, which is
/// what the Actionless predicate reads (ADR-0001 story 3). Blank / whitespace
/// text mints no Action row, mirroring the blank→Actionless normalisation.
Future<String> _insertClarifiedTask(
  GtdDatabase db, {
  String? actionText,
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
    lastNextActionCompletionAt: lastNextActionCompletionAt != null
        ? Value(lastNextActionCompletionAt)
        : const Value.absent(),
    lastClarifiedAt:
        lastClarifiedAt != null ? Value(lastClarifiedAt) : const Value.absent(),
  ));
  await seedCurrentAction(
    db,
    outcomeId: id,
    text: actionText,
    userId: _userId,
    createdAt: now,
  );
  return id;
}

/// Inserts a terminal (or extra `current`) Action row directly, for the
/// Stale-widening fixtures that need a specific termination timestamp.
Future<void> _insertAction(
  GtdDatabase db, {
  required String id,
  required String outcomeId,
  required String role,
  String text = 'some action',
  DateTime? createdAt,
  DateTime? updatedAt,
  DateTime? doneAt,
}) async {
  await db.into(db.actions).insert(ActionsCompanion(
        id: Value(id),
        outcomeId: Value(outcomeId),
        userId: Value(_userId),
        actionText: Value(text),
        role: Value(role),
        createdAt: Value(createdAt ?? DateTime.now().toUtc()),
        updatedAt: Value(updatedAt),
        doneAt: Value(doneAt),
      ));
}

/// Inserts a person-typed tag and links it to [todoId]. Returns the tag id.
Future<String> _attachPersonTag(
  GtdDatabase db,
  String todoId, {
  String name = 'Trixy',
}) async {
  final tagId = 'ptag-${DateTime.now().microsecondsSinceEpoch}-$todoId';
  await db.into(db.tags).insert(TagsCompanion(
    id: Value(tagId),
    name: Value(name),
    type: const Value('person'),
    userId: Value(_userId),
  ));
  await db.into(db.todoTags).insert(TodoTagsCompanion(
    id: Value('tt-$tagId-$todoId'),
    todoId: Value(todoId),
    tagId: Value(tagId),
    userId: Value(_userId),
  ));
  return tagId;
}

/// Is [id] currently in the re-clarification queue? Asked through the one
/// surviving production entry point, [TodoDao.getNeedsReview] — the
/// `isNeedsReview` / `getNeedsReviewCount` / `watchNeedsReview` wrappers were
/// dead surface and were removed in #494.
Future<bool> _isNeedsReview(GtdDatabase db, String id) async =>
    (await db.todoDao.getNeedsReview()).any((t) => t.id == id);

void main() {
  setUpAll(configureSqliteForTests);

  group('TodoDao.getNeedsReview', () {
    late GtdDatabase db;

    setUp(() {
      db = _openInMemory();
    });

    tearDown(() => db.close());

    // Fixture 1: Fresh task processed through inbox-clarify does not surface.
    test('1: task with a current Action, no session history — not in result',
        () async {
      await _insertClarifiedTask(
        db,
        actionText: 'Buy milk',
        lastNextActionCompletionAt: null,
      );

      final result = await db.todoDao.getNeedsReview();
      expect(result, isEmpty);
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
        actionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
      );

      final result = await db.todoDao.getNeedsReview();
      expect(result, hasLength(1));
      expect(result.first.id, id);
      expect(await db.actionDao.getCurrentAction(id), isNotNull,
          reason: 'the actionable branch of the predicate, not the Stale one');
    });

    // Fixture 3: Stale task with no current Action — Actionless + Stale.
    test('3: stale Actionless task — in result with noNextAction hint (both branches)',
        () async {
      final clarifiedAt =
          DateTime.now().subtract(const Duration(hours: 2)).toUtc();
      final completedAt =
          DateTime.now().subtract(const Duration(hours: 1)).toUtc();
      final id = await _insertClarifiedTask(
        db,
        actionText: null,
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
      );

      final result = await db.todoDao.getNeedsReview();
      expect(result, hasLength(1));
      expect(result.first.id, id);
      expect(await db.actionDao.getCurrentAction(id), isNull,
          reason: 'Actionless: no current Action row');
    });

    // Fixture 4: Non-person (organising) tag added — does not affect timestamps.
    test('4: stale task after non-person tag added — still in result', () async {
      final clarifiedAt =
          DateTime.now().subtract(const Duration(hours: 2)).toUtc();
      final completedAt =
          DateTime.now().subtract(const Duration(hours: 1)).toUtc();
      final id = await _insertClarifiedTask(
        db,
        actionText: 'Draft email',
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

      final result = await db.todoDao.getNeedsReview();
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
        actionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
      );

      expect(await db.todoDao.getNeedsReview(), hasLength(1));

      await db.todoDao.stampLastClarifiedAt(id);

      final result = await db.todoDao.getNeedsReview();
      expect(result, isEmpty);
    });

    // Fixture 6: "Update next action" on an Actionless task — leaves result.
    test('6: setCurrentActionText on actionless task — task leaves result', () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: null,
        lastNextActionCompletionAt: null,
      );

      expect(await db.todoDao.getNeedsReview(), hasLength(1));

      await db.todoDao.setCurrentActionText(id,'Draft proposal');

      final result = await db.todoDao.getNeedsReview();
      expect(result, isEmpty);
    });

    // Fixture 7: Done task does not surface.
    test('7: done task — not in result', () async {
      final id = await _insertClarifiedTask(db, actionText: null);
      await db.todoDao.markDone(id);

      final result = await db.todoDao.getNeedsReview();
      expect(result, isEmpty);
    });

    // Fixture 8: Trashed task does not surface.
    test('8: trashed task — not in result', () async {
      final id = await _insertClarifiedTask(db, actionText: null);
      await db.customUpdate(
        "UPDATE todos SET intent = 'trash' WHERE id = ? AND user_id = ?",
        variables: [Variable(id), Variable(_userId)],
        updates: {db.todos},
      );

      final result = await db.todoDao.getNeedsReview();
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

      final result = await db.todoDao.getNeedsReview();
      expect(result, isEmpty);
    });

    // Fixture 10: Pure Actionless without any session history — DOES surface.
    test('10: actionless task (no current Action, no session) — in result',
        () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: null,
        lastNextActionCompletionAt: null,
        lastClarifiedAt: null,
      );

      final result = await db.todoDao.getNeedsReview();
      expect(result, hasLength(1));
      expect(result.first.id, id);
      expect(await db.actionDao.getCurrentAction(id), isNull,
          reason: 'Actionless: no current Action row');
    });

    // markDone stamps last_clarified_at — task leaves result.
    test('markDone stamps lastClarifiedAt — task leaves result', () async {
      final clarifiedAt =
          DateTime.now().subtract(const Duration(hours: 2)).toUtc();
      final completedAt =
          DateTime.now().subtract(const Duration(hours: 1)).toUtc();
      final id = await _insertClarifiedTask(
        db,
        actionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
      );

      expect(await db.todoDao.getNeedsReview(), hasLength(1));
      await db.todoDao.markDone(id);

      final result = await db.todoDao.getNeedsReview();
      expect(result, isEmpty);
    });

    // Deferred Actionless task does NOT re-surface — maybe tasks are excluded.
    test('deferred actionless task leaves result after deferTaskToMaybe', () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: null,
        lastNextActionCompletionAt: null,
      );

      await db.todoDao.deferTaskToMaybe(id);

      // After deferring, intent = 'maybe'. The predicate requires intent = 'next',
      // so the task is excluded regardless of the Actionless branch.
      final result = await db.todoDao.getNeedsReview();
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
        actionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
      );

      expect(await db.todoDao.getNeedsReview(), hasLength(1));

      await db.todoDao.updateFields(id,title: 'Renamed task');

      final result = await db.todoDao.getNeedsReview();
      expect(result, isEmpty);
    });

    // Membership flips as the actionless condition is fixed.
    test('actionless task is in the queue, leaves after a next action is set', () async {
      final id = await _insertClarifiedTask(db, actionText: null);

      expect((await db.todoDao.getNeedsReview()).any((t) => t.id == id), isTrue);

      await db.todoDao.setCurrentActionText(id,'Do something');

      expect((await db.todoDao.getNeedsReview()).any((t) => t.id == id), isFalse);
    });

    // ----- Delegated (person-tagged) actionless branch (#289) ----------------

    // Delegated + actionless task does NOT surface — waiting-for cadence
    // belongs to the weekly review, not the daily re-clarification surface.
    test('delegated actionless task — not in result', () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: null,
        lastNextActionCompletionAt: null,
      );
      await _attachPersonTag(db, id);

      final result = await db.todoDao.getNeedsReview();
      expect(result, isEmpty);
    });

    // Delegated + whitespace-only action text — also excluded (guards
    // the TRIM(...) = '' branch).
    test('delegated whitespace-only action text task — not in result',
        () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: '   ',
        lastNextActionCompletionAt: null,
      );
      await _attachPersonTag(db, id);

      final result = await db.todoDao.getNeedsReview();
      expect(result, isEmpty);
    });

    // Delegated + stale (lastNextActionCompletionAt > lastClarifiedAt) DOES
    // surface — the stale branch fires regardless of person-tag presence.
    test('delegated stale task — in result (stale branch unaffected)',
        () async {
      final clarifiedAt =
          DateTime.now().subtract(const Duration(hours: 2)).toUtc();
      final completedAt =
          DateTime.now().subtract(const Duration(hours: 1)).toUtc();
      final id = await _insertClarifiedTask(
        db,
        actionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: completedAt,
      );
      await _attachPersonTag(db, id);

      final result = await db.todoDao.getNeedsReview();
      expect(result, hasLength(1));
      expect(result.first.id, id);
    });
  });

  // ---------------------------------------------------------------------------
  // Stale widened over Action terminations (ADR-0001 story 4, issue #474).
  //
  // Every fixture here attaches a person tag so the Actionless branch is
  // excluded and only the Stale branch can put the Outcome in the result — the
  // widening is what is under test, not the pre-existing Actionless rule.
  // ---------------------------------------------------------------------------
  group('TodoDao.getNeedsReview — Action-termination widening', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    final clarifiedAt = DateTime.parse('2026-07-01T09:00:00.000Z');
    final before = DateTime.parse('2026-07-01T08:00:00.000Z');
    final after = DateTime.parse('2026-07-01T10:00:00.000Z');

    test('a completed Action makes the Outcome stale even with no session '
        'history at all', () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: null,
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: null,
      );
      await _attachPersonTag(db, id);
      await _insertAction(db,
          id: 'a-done', outcomeId: id, role: 'done', doneAt: after);

      expect(await db.todoDao.getNeedsReview(), hasLength(1));
      expect(await db.todoDao.getNeedsReview(), hasLength(1));
      expect(await _isNeedsReview(db, id), isTrue);
    });

    test('a completion the user has already re-clarified past does not surface',
        () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: null,
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: null,
      );
      await _attachPersonTag(db, id);
      await _insertAction(db,
          id: 'a-done', outcomeId: id, role: 'done', doneAt: before);

      expect(await db.todoDao.getNeedsReview(), isEmpty);
      expect(await _isNeedsReview(db, id), isFalse);
    });

    test('a done row missing done_at falls back to updated_at', () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: null,
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: null,
      );
      await _attachPersonTag(db, id);
      await _insertAction(db,
          id: 'a-done', outcomeId: id, role: 'done', updatedAt: after);

      expect(await db.todoDao.getNeedsReview(), hasLength(1));
    });

    test('an app-side supersession is not stale — it stamps with the same '
        'timestamp it writes to the retired row', () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: null,
      );
      await _attachPersonTag(db, id);

      await db.actionDao.clearCurrentAction(id, now: after);

      expect(await db.todoDao.getNeedsReview(), isEmpty,
          reason: 'equality, not `<` — the supersession already clarified');
    });

    test('a repair-only supersession does not fabricate staleness', () async {
      // Multi-current convergence and the startup sweep retire rows *without*
      // stamping; the widening must not read those as engagement (R2).
      final id = await _insertClarifiedTask(
        db,
        actionText: null,
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: null,
      );
      await _attachPersonTag(db, id);
      await _insertAction(db,
          id: 'a-repaired',
          outcomeId: id,
          role: 'superseded',
          updatedAt: after);

      expect(await db.todoDao.getNeedsReview(), isEmpty);
      expect(await _isNeedsReview(db, id), isFalse);
    });

    test('completeCurrentAction puts the Outcome in the result without '
        'stamping, and re-clarifying takes it back out', () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
        lastNextActionCompletionAt: null,
      );
      await _attachPersonTag(db, id);
      expect(await db.todoDao.getNeedsReview(), isEmpty);

      await db.actionDao.completeCurrentAction(id, now: after);

      expect(await db.todoDao.getNeedsReview(), hasLength(1));

      await db.todoDao.setCurrentActionText(id, 'Chase the reply');

      expect(await db.todoDao.getNeedsReview(), isEmpty);
    });
  });

  group('TodoDao.getNeedsReview — the blank-save resolution (#691)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('routing to Next alone leaves an Actionless Outcome in the queue '
        'forever — the Actionless branch has no freshness gate', () async {
      // Why the blank save cannot simply route and leave the row Actionless:
      // a fresh `last_clarified_at` does not suppress this branch, so the item
      // would land back on the identical review card at the next planning,
      // every day. This is the failure mode the title-as-action fallback
      // exists to avoid.
      final id = await _insertClarifiedTask(db);
      expect(await db.todoDao.getNeedsReview(), hasLength(1));

      await db.todoDao.applyRouting(id, to: RoutingKind.nextAction);

      expect((await db.todoDao.getTodo(id))?.lastClarifiedAt, isNotNull);
      expect(await db.todoDao.getNeedsReview(), hasLength(1),
          reason: 'a stamp does not clear the Actionless branch');
    });

    test('route + title mirror takes the Outcome out of the queue', () async {
      // The composition the blank-save path performs: applyRouting with no
      // actionText, then the Actionless-guarded title mirror.
      final id = await _insertClarifiedTask(db);
      final title = (await db.todoDao.getTodo(id))!.title;
      expect(await db.todoDao.getNeedsReview(), hasLength(1));

      await db.todoDao.applyRouting(id, to: RoutingKind.nextAction);
      final wrote =
          await db.todoDao.setCurrentActionTextIfActionless(id, title);

      expect(wrote, isTrue);
      expect((await db.actionDao.getCurrentAction(id))?.actionText, title);
      expect(await db.todoDao.getNeedsReview(), isEmpty,
          reason: 'the resolved Outcome must not re-arm the review queue');
    });

    test('the mirror never clobbers a deliberate phrase', () async {
      final id = await _insertClarifiedTask(db, actionText: 'Book the room');
      final title = (await db.todoDao.getTodo(id))!.title;

      final wrote =
          await db.todoDao.setCurrentActionTextIfActionless(id, title);

      expect(wrote, isFalse);
      expect((await db.actionDao.getCurrentAction(id))?.actionText,
          'Book the room');
    });
  });
}
