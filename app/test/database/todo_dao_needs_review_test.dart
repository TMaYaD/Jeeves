import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/routing_kind.dart';
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
  DateTime? actionTerminatedAt,
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
  if (actionTerminatedAt != null) {
    await _insertAction(db,
        id: 'done-$id',
        outcomeId: id,
        role: 'done',
        doneAt: actionTerminatedAt);
  }
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

/// The queue with the Actionless freshness gate wide open.
Future<List<Todo>> _queue(GtdDatabase db) => db.todoDao
    .getNeedsReview(actionlessReviewCutoff: actionlessGateOpenCutoff);

/// Is [id] currently in the re-clarification queue? Asked through the one
/// surviving production entry point, [TodoDao.getNeedsReview] — the
/// `isNeedsReview` / `getNeedsReviewCount` / `watchNeedsReview` wrappers were
/// dead surface and were removed in #494.
Future<bool> _isNeedsReview(GtdDatabase db, String id) async =>
    (await _queue(db)).any((t) => t.id == id);

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
      );

      final result = await _queue(db);
      expect(result, isEmpty);
    });

    // The retired stamp: a closed day no longer makes anything Stale.
    test('1b: an Outcome carrying a legacy last_next_action_completion_at '
        'newer than lastClarifiedAt — not in result (#695)', () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: 'Buy milk',
        lastClarifiedAt:
            DateTime.now().subtract(const Duration(hours: 2)).toUtc(),
      );
      await (db.update(db.todos)..where((t) => t.id.equals(id))).write(
        TodosCompanion(
          lastNextActionCompletionAt:
              Value(DateTime.now().subtract(const Duration(hours: 1)).toUtc()),
        ),
      );

      expect(await _queue(db), isEmpty,
          reason: 'only an Action termination makes an Outcome Stale');
    });

    // Fixture 2: Stale task (an Action completed after last clarification).
    test('2: stale task (an Action completed after lastClarifiedAt) — in result with updatedSinceClarified hint',
        () async {
      final clarifiedAt =
          DateTime.now().subtract(const Duration(hours: 2)).toUtc();
      final completedAt =
          DateTime.now().subtract(const Duration(hours: 1)).toUtc();
      final id = await _insertClarifiedTask(
        db,
        actionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
        actionTerminatedAt: completedAt,
      );

      final result = await _queue(db);
      expect(result, hasLength(1));
      expect(result.first.id, id);
      expect(await db.actionDao.getCurrentAction(id), isNotNull,
          reason: 'Stale by Action termination while another Action is current');
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
        actionTerminatedAt: completedAt,
      );

      final result = await _queue(db);
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
        actionTerminatedAt: completedAt,
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

      final result = await _queue(db);
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
        actionTerminatedAt: completedAt,
      );

      expect(await _queue(db), hasLength(1));

      await db.todoDao.stampLastClarifiedAt(id);

      final result = await _queue(db);
      expect(result, isEmpty);
    });

    // Fixture 6: "Update next action" on an Actionless task — leaves result.
    test('6: setCurrentActionText on actionless task — task leaves result', () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: null,
      );

      expect(await _queue(db), hasLength(1));

      await db.todoDao.setCurrentActionText(id,'Draft proposal');

      final result = await _queue(db);
      expect(result, isEmpty);
    });

    // Fixture 7: Done task does not surface.
    test('7: done task — not in result', () async {
      final id = await _insertClarifiedTask(db, actionText: null);
      await db.todoDao.markDone(id);

      final result = await _queue(db);
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

      final result = await _queue(db);
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

      final result = await _queue(db);
      expect(result, isEmpty);
    });

    // Fixture 10: Pure Actionless without any session history — DOES surface.
    test('10: actionless task (no current Action, no session) — in result',
        () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: null,
        lastClarifiedAt: null,
      );

      final result = await _queue(db);
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
        actionTerminatedAt: completedAt,
      );

      expect(await _queue(db), hasLength(1));
      await db.todoDao.markDone(id);

      final result = await _queue(db);
      expect(result, isEmpty);
    });

    // Deferred Actionless task does NOT re-surface — maybe tasks are excluded.
    test('deferred actionless task leaves result after deferTaskToMaybe', () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: null,
      );

      await db.todoDao.deferTaskToMaybe(id);

      // After deferring, intent = 'maybe'. The predicate requires intent = 'next',
      // so the task is excluded regardless of the Actionless branch.
      final result = await _queue(db);
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
        actionTerminatedAt: completedAt,
      );

      expect(await _queue(db), hasLength(1));

      await db.todoDao.updateFields(id,title: 'Renamed task');

      final result = await _queue(db);
      expect(result, isEmpty);
    });

    // Membership flips as the actionless condition is fixed.
    test('actionless task is in the queue, leaves after a next action is set', () async {
      final id = await _insertClarifiedTask(db, actionText: null);

      expect((await _queue(db)).any((t) => t.id == id), isTrue);

      await db.todoDao.setCurrentActionText(id,'Do something');

      expect((await _queue(db)).any((t) => t.id == id), isFalse);
    });

    // ----- Delegated (person-tagged) actionless branch (#289) ----------------

    // Delegated + actionless task does NOT surface — waiting-for cadence
    // belongs to the weekly review, not the daily re-clarification surface.
    test('delegated actionless task — not in result', () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: null,
      );
      await _attachPersonTag(db, id);

      final result = await _queue(db);
      expect(result, isEmpty);
    });

    // Delegated + whitespace-only action text — also excluded (guards
    // the TRIM(...) = '' branch).
    test('delegated whitespace-only action text task — not in result',
        () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: '   ',
      );
      await _attachPersonTag(db, id);

      final result = await _queue(db);
      expect(result, isEmpty);
    });

    // Delegated + stale (an Action completed after lastClarifiedAt) DOES
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
        actionTerminatedAt: completedAt,
      );
      await _attachPersonTag(db, id);

      final result = await _queue(db);
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
      );
      await _attachPersonTag(db, id);
      await _insertAction(db,
          id: 'a-done', outcomeId: id, role: 'done', doneAt: after);

      expect(await _queue(db), hasLength(1));
      expect(await _queue(db), hasLength(1));
      expect(await _isNeedsReview(db, id), isTrue);
    });

    test('a completion the user has already re-clarified past does not surface',
        () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: null,
        lastClarifiedAt: clarifiedAt,
      );
      await _attachPersonTag(db, id);
      await _insertAction(db,
          id: 'a-done', outcomeId: id, role: 'done', doneAt: before);

      expect(await _queue(db), isEmpty);
      expect(await _isNeedsReview(db, id), isFalse);
    });

    test('a done row missing done_at falls back to updated_at', () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: null,
        lastClarifiedAt: clarifiedAt,
      );
      await _attachPersonTag(db, id);
      await _insertAction(db,
          id: 'a-done', outcomeId: id, role: 'done', updatedAt: after);

      expect(await _queue(db), hasLength(1));
    });

    test('an app-side supersession is not stale — it stamps with the same '
        'timestamp it writes to the retired row', () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
      );
      await _attachPersonTag(db, id);

      await db.actionDao.clearCurrentAction(id, now: after);

      expect(await _queue(db), isEmpty,
          reason: 'equality, not `<` — the supersession already clarified');
    });

    test('a repair-only supersession does not fabricate staleness', () async {
      // Multi-current convergence and the startup sweep retire rows *without*
      // stamping; the widening must not read those as engagement (R2).
      final id = await _insertClarifiedTask(
        db,
        actionText: null,
        lastClarifiedAt: clarifiedAt,
      );
      await _attachPersonTag(db, id);
      await _insertAction(db,
          id: 'a-repaired',
          outcomeId: id,
          role: 'superseded',
          updatedAt: after);

      expect(await _queue(db), isEmpty);
      expect(await _isNeedsReview(db, id), isFalse);
    });

    test('completeCurrentAction puts the Outcome in the result without '
        'stamping, and re-clarifying takes it back out', () async {
      final id = await _insertClarifiedTask(
        db,
        actionText: 'Draft email',
        lastClarifiedAt: clarifiedAt,
      );
      await _attachPersonTag(db, id);
      expect(await _queue(db), isEmpty);

      await db.actionDao.completeCurrentAction(id, now: after);

      expect(await _queue(db), hasLength(1));

      await db.todoDao.setCurrentActionText(id, 'Chase the reply');

      expect(await _queue(db), isEmpty);
    });
  });

  group('TodoDao.getNeedsReview — the blank-save resolution (#691)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('routing to Next alone only postpones the nag by one review interval',
        () async {
      // Why the blank save cannot simply route and leave the row Actionless:
      // the fresh `last_clarified_at` only holds the Actionless branch off for
      // the review interval, after which the identical card comes back. The
      // title-as-action fallback exists to take the Outcome out of the
      // Actionless state altogether.
      final id = await _insertClarifiedTask(db);
      expect(await _queue(db), hasLength(1));

      await db.todoDao.applyRouting(id, to: RoutingKind.nextAction);

      final stampedAt = (await db.todoDao.getTodo(id))!.lastClarifiedAt!;
      expect(
        await db.todoDao.getNeedsReview(
            actionlessReviewCutoff:
                stampedAt.subtract(const Duration(days: 1))),
        isEmpty,
        reason: 'stamped inside the interval: held back',
      );
      expect(
        await db.todoDao.getNeedsReview(
            actionlessReviewCutoff: stampedAt.add(const Duration(days: 1))),
        hasLength(1),
        reason: 'the stamp is older than the cutoff: it comes back',
      );
    });

    test('route + title mirror takes the Outcome out of the queue', () async {
      // What the blank-save path performs: one applyRouting carrying the
      // Actionless-guarded title mirror.
      final id = await _insertClarifiedTask(db);
      final title = (await db.todoDao.getTodo(id))!.title;
      expect(await _queue(db), hasLength(1));

      await db.todoDao.applyRouting(id,
          to: RoutingKind.nextAction, actionTextIfActionless: title);

      expect((await db.actionDao.getCurrentAction(id))?.actionText, title);
      expect(await _queue(db), isEmpty,
          reason: 'the resolved Outcome must not re-arm the review queue');
    });

    test('the mirror never clobbers a deliberate phrase', () async {
      final id = await _insertClarifiedTask(db, actionText: 'Book the room');
      final title = (await db.todoDao.getTodo(id))!.title;

      await db.todoDao.applyRouting(id,
          to: RoutingKind.nextAction, actionTextIfActionless: title);

      expect((await db.actionDao.getCurrentAction(id))?.actionText,
          'Book the room');
    });
  });

  // ---------------------------------------------------------------------------
  // The Actionless freshness gate (#695): an Outcome clarified at or after the
  // cutoff stays out of the Actionless branch; one never clarified, or last
  // clarified before it, is in.
  // ---------------------------------------------------------------------------
  group('TodoDao.getNeedsReview — Actionless freshness gate', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    final cutoff = DateTime.parse('2026-07-08T18:00:00.000Z');

    test('never clarified — surfaces', () async {
      final id = await _insertClarifiedTask(db);
      final result = await db.todoDao.getNeedsReview(
          actionlessReviewCutoff: cutoff);
      expect(result.map((t) => t.id), [id]);
    });

    test('clarified after the cutoff — suppressed', () async {
      await _insertClarifiedTask(db,
          lastClarifiedAt: DateTime.parse('2026-07-09T08:15:00.000Z'));
      expect(
          await db.todoDao.getNeedsReview(actionlessReviewCutoff: cutoff),
          isEmpty);
    });

    test('clarified before the cutoff — surfaces', () async {
      final id = await _insertClarifiedTask(db,
          lastClarifiedAt: DateTime.parse('2026-07-08T08:15:00.000Z'));
      final result =
          await db.todoDao.getNeedsReview(actionlessReviewCutoff: cutoff);
      expect(result.map((t) => t.id), [id]);
    });

    test('the gate does not hide a Stale Outcome that is also Actionless',
        () async {
      final id = await _insertClarifiedTask(db,
          lastClarifiedAt: DateTime.parse('2026-07-09T08:15:00.000Z'),
          actionTerminatedAt: DateTime.parse('2026-07-09T09:00:00.000Z'));
      final result =
          await db.todoDao.getNeedsReview(actionlessReviewCutoff: cutoff);
      expect(result.map((t) => t.id), [id]);
    });

    test('getActionTerminationStaleIds names only the Action-terminated ones',
        () async {
      final stale = await _insertClarifiedTask(db,
          actionText: 'Draft email',
          lastClarifiedAt: DateTime.parse('2026-07-09T08:00:00.000Z'),
          actionTerminatedAt: DateTime.parse('2026-07-09T09:00:00.000Z'));
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final reclarified = await _insertClarifiedTask(db,
          actionText: 'Draft email',
          lastClarifiedAt: DateTime.parse('2026-07-09T10:00:00.000Z'),
          actionTerminatedAt: DateTime.parse('2026-07-09T09:00:00.000Z'));
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final actionless = await _insertClarifiedTask(db);

      expect(
        await db.todoDao
            .getActionTerminationStaleIds({stale, reclarified, actionless}),
        {stale},
      );
      expect(await db.todoDao.getActionTerminationStaleIds({}), isEmpty);
    });
  });
}
