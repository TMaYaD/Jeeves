import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met within $timeout', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

const _userId = 'test-user';

Future<String> _insertTodo(
  GtdDatabase db, {
  required String id,
  required String title,
  bool clarified = true,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
    id: Value(id),
    title: Value(title),
    clarified: Value(clarified),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
  return id;
}

Future<String> _insertPersonTag(
  GtdDatabase db, {
  required String id,
  required String name,
}) async {
  await db.tagDao.upsertTag(TagsCompanion(
    id: Value(id),
    name: Value(name),
    type: const Value('person'),
    userId: const Value(_userId),
  ));
  return id;
}

void main() {
  setUpAll(configureSqliteForTests);

  group('TodoDao — watchTodosById', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('returns todos matching the given ids', () async {
      await _insertTodo(db, id: 'x1', title: 'Task X1');
      await _insertTodo(db, id: 'x2', title: 'Task X2');
      await _insertTodo(db, id: 'x3', title: 'Task X3');

      final items =
          await db.todoDao.watchTodosById(['x1', 'x3']).first;
      expect(items.map((t) => t.id), containsAll(['x1', 'x3']));
      expect(items.any((t) => t.id == 'x2'), isFalse);
    });

    test('returns empty list for empty ids', () async {
      await _insertTodo(db, id: 'y1', title: 'Task Y1');

      final items = await db.todoDao.watchTodosById([]).first;
      expect(items, isEmpty);
    });
  });

  group('TodoDao — rescheduleTask', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('updates dueDate', () async {
      final todayDt = DateTime(2026, 4, 16);
      final newDate = DateTime(2026, 4, 20);
      await _insertTodo(db, id: 'r1', title: 'Reschedulable task');
      await (db.update(db.todos)..where((t) => t.id.equals('r1')))
          .write(TodosCompanion(dueDate: Value(todayDt)));

      await db.todoDao.rescheduleTask('r1', newDate);

      final row = await db.todoDao.getTodo('r1');
      expect(row?.dueDate, newDate.toUtc());
    });
  });

  group('TodoDao — GTD list watchers', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('watchPersonTagged returns todos linked to a person-typed tag', () async {
      await _insertTodo(db, id: 'w1', title: 'Waiting 1');
      await _insertPersonTag(db, id: 'p1', name: 'Alice');
      await db.tagDao.assignTag('w1', 'p1', _userId);
      // Task without person-tag → not in Waiting For list
      await _insertTodo(db, id: 'w2', title: 'Next action');

      final items = await db.todoDao.watchPersonTagged().first;
      expect(items.length, 1);
      expect(items.first.id, 'w1');
    });

    test('watchPersonTagged excludes tasks where clarified = false', () async {
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
        id: const Value('wc1'),
        title: const Value('Unclarified waiting'),
        clarified: const Value(false),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
      await _insertPersonTag(db, id: 'p2', name: 'Bob');
      await db.tagDao.assignTag('wc1', 'p2', _userId);

      final items = await db.todoDao.watchPersonTagged().first;
      expect(items.any((t) => t.id == 'wc1'), isFalse);
    });

    test('watchPersonTagged excludes done tasks', () async {
      await _insertTodo(db, id: 'wd1', title: 'Done waiting');
      await _insertPersonTag(db, id: 'p3', name: 'Carol');
      await db.tagDao.assignTag('wd1', 'p3', _userId);
      await db.todoDao.markDone('wd1');

      final items = await db.todoDao.watchPersonTagged().first;
      expect(items.any((t) => t.id == 'wd1'), isFalse);
    });

    test('watchPersonTagged excludes tasks with no person-typed tags', () async {
      await _insertTodo(db, id: 'wn1', title: 'No person tag');

      final items = await db.todoDao.watchPersonTagged().first;
      expect(items.any((t) => t.id == 'wn1'), isFalse);
    });

    test(
        'watchPersonTaggedGrouped derives timeSpentMinutes from time_logs and '
        're-emits when a log lands, ignoring the stale '
        'todos.time_spent_minutes column (issue #480)', () async {
      await _insertTodo(db, id: 'wg1', title: 'Grouped waiting');
      await _insertPersonTag(db, id: 'pg1', name: 'Dave');
      await db.tagDao.assignTag('wg1', 'pg1', _userId);
      // Poison the dead cache column; the query must not surface it.
      await db.customStatement(
          'UPDATE todos SET time_spent_minutes = 999 WHERE id = ?', ['wg1']);

      // Subscribe BEFORE inserting the log, so the second emission proves
      // time_logs is in the watcher's readsFrom set — not just that the
      // initial projection derives correctly.
      final timeSpentMinutesEmissions = <int>[];
      final subscription = db.todoDao
          .watchPersonTaggedGrouped()
          .map((grouped) => grouped.values.single.single.timeSpentMinutes)
          .listen(timeSpentMinutesEmissions.add);
      addTearDown(subscription.cancel);

      await _waitUntil(() => timeSpentMinutesEmissions.isNotEmpty);
      expect(timeSpentMinutesEmissions.last, 0,
          reason: 'no logs yet — the poisoned cache column (999) must be '
              'ignored');

      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: const Value('tl-wg1'),
            userId: const Value(_userId),
            taskId: const Value('wg1'),
            startedAt:
                Value(DateTime.utc(2026, 5, 1, 9, 0).toIso8601String()),
            endedAt: Value(DateTime.utc(2026, 5, 1, 9, 25).toIso8601String()),
          ));

      await _waitUntil(() => timeSpentMinutesEmissions.last == 25);
      expect(timeSpentMinutesEmissions.last, 25,
          reason: 'must be SUM(time_logs), not the dead cache column');
    });

    test('watchMaybe returns only intent=maybe todos (not done)', () async {
      await _insertTodo(db, id: 'm1', title: 'Maybe 1');
      await db.todoDao.deferTaskToMaybe('m1');
      await _insertTodo(db, id: 'm2', title: 'Next action');
      await _insertTodo(db, id: 'm3', title: 'Maybe Done');
      await db.todoDao.deferTaskToMaybe('m3');
      await db.todoDao.markDone('m3');

      final items = await db.todoDao.watchMaybe().first;
      expect(items.length, 1);
      expect(items.first.id, 'm1');
    });

    test('task appears in watchPersonTagged after person-tag assignment', () async {
      await _insertTodo(db, id: 's4', title: 'Task S4');
      await _insertPersonTag(db, id: 'p4', name: 'Carol');
      await db.tagDao.assignTag('s4', 'p4', _userId);

      final items = await db.todoDao.watchPersonTagged().first;
      expect(items.any((t) => t.id == 's4'), isTrue);
    });

    test('task leaves watchPersonTagged after person-tag removal', () async {
      await _insertTodo(db, id: 's5', title: 'Task S5');
      await _insertPersonTag(db, id: 'p5', name: 'Dave');
      await db.tagDao.assignTag('s5', 'p5', _userId);
      await (db.delete(db.todoTags)
            ..where((tt) => tt.todoId.equals('s5') & tt.tagId.equals('p5')))
          .go();

      final items = await db.todoDao.watchPersonTagged().first;
      expect(items.any((t) => t.id == 's5'), isFalse);
    });

  });

  group('TodoDao — watchNext (actionless+PersonBlocked exclusion)', () {
    // The Next List membership rule:
    //
    //   Next = intent='next' ∧ clarified ∧ done_at IS NULL ∧
    //          (next_action_text IS NOT NULL ∨ no PersonBlocker on the Outcome)
    //
    // The single excluded quadrant is actionless (next_action_text IS NULL)
    // AND PersonBlocked (carries any Tag(type='person')) — that combination
    // is a pure wait and surfaces only on Waiting For, not on the daily
    // Next List. Cross-reference CONTEXT.md § Next / Waiting For and the
    // refined rule at
    // https://github.com/TMaYaD/Jeeves/pull/315#discussion_r3468901021.
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('Q1: intent=next, has next_action_text, no person-tag → on Next',
        () async {
      await _insertTodo(db, id: 'q1', title: 'Buy milk');
      await db.todoDao.setNextActionText('q1', 'Buy milk');

      final items = await db.todoDao.watchNext().first;
      expect(items.map((t) => t.id), contains('q1'));
    });

    test(
        'Q2: intent=next, has next_action_text, has person-tag → on Next '
        '(actionable+PersonBlocked overlap)', () async {
      // The "call Trixy for a follow up" case: PersonBlocker coexists with a
      // doable current Action, so the Outcome belongs on Next AND on Waiting
      // For. This PR must NOT exclude it from Next.
      await _insertTodo(db, id: 'q2', title: 'Catch up with Trixy');
      await db.todoDao.setNextActionText('q2', 'Call Trixy for a follow up');
      await _insertPersonTag(db, id: 'q2-trixy', name: 'Trixy');
      await db.tagDao.assignTag('q2', 'q2-trixy', _userId);

      final items = await db.todoDao.watchNext().first;
      expect(items.map((t) => t.id), contains('q2'),
          reason: 'actionable+PersonBlocked must remain on Next');
    });

    test(
        'Q3: intent=next, no next_action_text, no person-tag → on Next '
        '(re-clarify candidate; still surfaces)', () async {
      // An actionless Outcome with no PersonBlocker is on Next — the daily
      // re-clarification surface will pick it up via getNeedsReview,
      // but it remains a member of the Next List itself.
      await _insertTodo(db, id: 'q3', title: 'Plan vacation');

      final items = await db.todoDao.watchNext().first;
      expect(items.map((t) => t.id), contains('q3'));
    });

    test(
        'Q4: intent=next, no next_action_text, has person-tag → NOT on Next '
        '(pure wait — surfaces only on Waiting For)', () async {
      // The excluded quadrant this PR introduces. Without a current Action
      // the Outcome offers nothing the user can do today; its cadence
      // belongs to the weekly Waiting For pass, not the daily Next List.
      await _insertTodo(db, id: 'q4', title: 'Hear back from Dave');
      await _insertPersonTag(db, id: 'q4-dave', name: 'Dave');
      await db.tagDao.assignTag('q4', 'q4-dave', _userId);

      final items = await db.todoDao.watchNext().first;
      expect(items.any((t) => t.id == 'q4'), isFalse,
          reason: 'actionless+PersonBlocked must be excluded from Next');
    });

    test(
        'Q4 (tag-filtered): exclusion also applies under context-tag filter',
        () async {
      // The tag-filtered path of watchNext must enforce the same
      // exclusion as the unfiltered path; otherwise the actionless+
      // PersonBlocked Outcome leaks onto Next the moment the user
      // activates a context filter.
      const ctxTagId = 'ctx-home';
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value(ctxTagId),
        name: Value('Home'),
        type: Value('context'),
        userId: Value(_userId),
      ));

      // q4f: actionless + person-tagged + context-tagged → must NOT appear.
      await _insertTodo(db, id: 'q4f', title: 'Hear back from Dave');
      await _insertPersonTag(db, id: 'q4f-dave', name: 'Dave-f');
      await db.tagDao.assignTag('q4f', 'q4f-dave', _userId);
      await db.tagDao.assignTag('q4f', ctxTagId, _userId);

      // q2f: actionable + person-tagged + context-tagged → must appear.
      await _insertTodo(db, id: 'q2f', title: 'Catch up with Trixy');
      await db.todoDao.setNextActionText('q2f', 'Call Trixy');
      await _insertPersonTag(db, id: 'q2f-trixy', name: 'Trixy-f');
      await db.tagDao.assignTag('q2f', 'q2f-trixy', _userId);
      await db.tagDao.assignTag('q2f', ctxTagId, _userId);

      final items =
          await db.todoDao.watchNext(tagIds: {ctxTagId}).first;
      final ids = items.map((t) => t.id).toSet();
      expect(ids, contains('q2f'),
          reason: 'actionable+PersonBlocked stays on filtered Next');
      expect(ids, isNot(contains('q4f')),
          reason: 'actionless+PersonBlocked excluded from filtered Next too');
    });

    test('a whitespace-only cursor leaked in by a direct write mints no Action, '
        'so the Outcome stays actionless', () async {
      // A straggler client can still PATCH todos.next_action_text directly.
      // Membership of Next is decided at the Action grain (an `actions` row
      // with role='current'), so a leaked whitespace cursor must leave the
      // Outcome actionless — blank text is unrepresentable as an Action
      // (ActionDao rejects it), which is the same normalisation
      // setNextActionText applies.
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
        id: const Value('q4w'),
        title: const Value('Whitespace action, person-blocked'),
        clarified: const Value(true),
        userId: const Value(_userId),
        nextActionText: const Value('   '),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
      await _insertPersonTag(db, id: 'q4w-eve', name: 'Eve');
      await db.tagDao.assignTag('q4w', 'q4w-eve', _userId);

      // Positive control, so the exclusion below cannot pass vacuously: the
      // same shape with a real current Action *is* on Next.
      await _insertTodo(db, id: 'q2w', title: 'Real action, person-blocked');
      await db.todoDao.setNextActionText('q2w', 'Call Eve');
      await _insertPersonTag(db, id: 'q2w-eve', name: 'Eve-2');
      await db.tagDao.assignTag('q2w', 'q2w-eve', _userId);

      expect(await db.actionDao.getCurrentAction('q4w'), isNull,
          reason: 'a whitespace cursor mints no Action');

      final ids = (await db.todoDao.watchNext().first).map((t) => t.id).toSet();
      expect(ids, isNot(contains('q4w')),
          reason: 'whitespace cursor + person-tag stays actionless');
      expect(ids, contains('q2w'),
          reason: 'the control proves the exclusion is not vacuous');
    });
  });

  group('TodoDao — getNextExcludingPersonTagged', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('returns clarified, non-done, intent=next todos with no person tag',
        () async {
      await _insertTodo(db, id: 'nx1', title: 'Plain next');

      final items =
          await db.todoDao.getNextExcludingPersonTagged();
      expect(items.map((t) => t.id), ['nx1']);
    });

    test('excludes todos that carry any person-typed tag', () async {
      await _insertTodo(db, id: 'nx2', title: 'Delegated next');
      await _insertPersonTag(db, id: 'pa', name: 'Alice');
      await db.tagDao.assignTag('nx2', 'pa', _userId);

      final items =
          await db.todoDao.getNextExcludingPersonTagged();
      expect(items.any((t) => t.id == 'nx2'), isFalse);
    });

    test('does NOT exclude todos that carry only non-person tags '
        '(project / context)', () async {
      await _insertTodo(db, id: 'nx3', title: 'Project-tagged next');
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('proj-tag'),
        name: Value('Garage'),
        type: Value('project'),
        userId: Value(_userId),
      ));
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('ctx-tag'),
        name: Value('Home'),
        type: Value('context'),
        userId: Value(_userId),
      ));
      await db.tagDao.assignTag('nx3', 'proj-tag', _userId);
      await db.tagDao.assignTag('nx3', 'ctx-tag', _userId);

      final items =
          await db.todoDao.getNextExcludingPersonTagged();
      expect(items.map((t) => t.id), contains('nx3'));
    });

    test('excludes todos that carry both person and non-person tags',
        () async {
      await _insertTodo(db, id: 'nx8', title: 'Delegated + project-tagged');
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('proj-tag-mix'),
        name: Value('Garage'),
        type: Value('project'),
        userId: Value(_userId),
      ));
      await _insertPersonTag(db, id: 'pa-mix', name: 'Alice');
      await db.tagDao.assignTag('nx8', 'proj-tag-mix', _userId);
      await db.tagDao.assignTag('nx8', 'pa-mix', _userId);

      final items =
          await db.todoDao.getNextExcludingPersonTagged();
      expect(items.any((t) => t.id == 'nx8'), isFalse);
    });

    test('excludes unclarified, done, and non-next-intent todos', () async {
      // Unclarified
      await _insertTodo(
          db, id: 'nx4', title: 'Unclarified', clarified: false);
      // Done
      await _insertTodo(db, id: 'nx5', title: 'Done');
      await db.todoDao.markDone('nx5');
      // Maybe-intent
      await _insertTodo(db, id: 'nx6', title: 'Maybe');
      await db.todoDao.deferTaskToMaybe('nx6');
      // Trash-intent
      await _insertTodo(db, id: 'nx7', title: 'Trash');
      await db.todoDao.setIntent('nx7', Intent.trash);

      final items =
          await db.todoDao.getNextExcludingPersonTagged();
      final ids = items.map((t) => t.id).toSet();
      expect(ids, isNot(contains('nx4')));
      expect(ids, isNot(contains('nx5')));
      expect(ids, isNot(contains('nx6')));
      expect(ids, isNot(contains('nx7')));
    });

    test('returns empty list when no matching todos exist', () async {
      final items =
          await db.todoDao.getNextExcludingPersonTagged();
      expect(items, isEmpty);
    });
  });

  group('TodoDao — markDone', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('markDone sets done_at', () async {
      await _insertTodo(db, id: 'md1', title: 'Task MD1');
      final now = DateTime(2024, 6, 1, 12, 0, 0);
      await db.todoDao.markDone('md1', now: now);

      final row = await db.todoDao.getTodo('md1');
      expect(row?.doneAt, isNotNull);
    });

    test('watchDone returns done tasks ordered by done_at DESC', () async {
      await _insertTodo(db, id: 'wd1', title: 'First done');
      await _insertTodo(db, id: 'wd2', title: 'Second done');
      final t1 = DateTime(2024, 6, 1, 10, 0, 0);
      final t2 = DateTime(2024, 6, 2, 10, 0, 0);
      await db.todoDao.markDone('wd1', now: t1);
      await db.todoDao.markDone('wd2', now: t2);

      final items = await db.todoDao.watchDone().first;
      expect(items.length, 2);
      expect(items.first.id, 'wd2'); // most recent first
      expect(items.last.id, 'wd1');
    });

    test('watchNext excludes done tasks', () async {
      await _insertTodo(db, id: 'na1', title: 'Active next action');
      await _insertTodo(db, id: 'na2', title: 'Done next action');
      await db.todoDao.markDone('na2');

      final items = await db.todoDao.watchNext().first;
      expect(items.length, 1);
      expect(items.first.id, 'na1');
    });

    test('watchNext excludes trashed tasks (#278)', () async {
      await _insertTodo(db, id: 'tn1', title: 'Active');
      await _insertTodo(db, id: 'tn2', title: 'Trashed');
      await db.todoDao.setIntent('tn2', Intent.trash);

      final items = await db.todoDao.watchNext().first;
      expect(items.map((t) => t.id), ['tn1']);
    });

    test('watchNext excludes trashed tasks even with tag filter (#278)',
        () async {
      await _insertTodo(db, id: 'tnt1', title: 'Active');
      await _insertTodo(db, id: 'tnt2', title: 'Trashed');
      const tagId = 'ctx-tag';
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value(tagId),
        name: const Value('context'),
        type: const Value('context'),
        userId: const Value(_userId),
      ));
      await db.tagDao.assignTag('tnt1', tagId, _userId);
      await db.tagDao.assignTag('tnt2', tagId, _userId);
      await db.todoDao.setIntent('tnt2', Intent.trash);

      final items = await db.todoDao.watchNext(tagIds: {tagId}).first;
      expect(items.map((t) => t.id), ['tnt1']);
    });

    test('watchDone excludes trashed tasks even when doneAt is set (#278)',
        () async {
      await _insertTodo(db, id: 'td1', title: 'Done');
      await _insertTodo(db, id: 'td2', title: 'Done then trashed');
      await db.todoDao.markDone('td1');
      await db.todoDao.markDone('td2');
      await db.todoDao.setIntent('td2', Intent.trash);

      final items = await db.todoDao.watchDone().first;
      expect(items.map((t) => t.id), ['td1']);
    });
  });

  group('TodoDao — watchTrash', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('returns only intent=trash rows, including completed ones', () async {
      await _insertTodo(db, id: 'tr1', title: 'Trashed');
      await db.todoDao.setIntent('tr1', Intent.trash);
      await _insertTodo(db, id: 'tr2', title: 'Done then trashed');
      await db.todoDao.markDone('tr2');
      await db.todoDao.setIntent('tr2', Intent.trash);
      await _insertTodo(db, id: 'tr3', title: 'Active');
      await _insertTodo(db, id: 'tr4', title: 'Done, not trashed');
      await db.todoDao.markDone('tr4');

      final items = await db.todoDao.watchTrash().first;
      expect(items.map((t) => t.id).toSet(), {'tr1', 'tr2'});
    });

    test(
        'completed-then-trashed surfaces in watchTrash, not watchDone '
        '(#278 mirror — Done and Trash are disjoint)', () async {
      await _insertTodo(db, id: 'tr5', title: 'Done then trashed');
      await db.todoDao.markDone('tr5');
      await db.todoDao.setIntent('tr5', Intent.trash);

      final trash = await db.todoDao.watchTrash().first;
      final done = await db.todoDao.watchDone().first;
      expect(trash.map((t) => t.id), contains('tr5'));
      expect(done.map((t) => t.id), isNot(contains('tr5')));
    });

    test('orders newest-trashed first (last_clarified_at DESC)', () async {
      await _insertTodo(db, id: 'tr6', title: 'Trashed first');
      await _insertTodo(db, id: 'tr7', title: 'Trashed second');
      await db.todoDao
          .setIntent('tr6', Intent.trash, now: DateTime.utc(2026, 6, 1));
      await db.todoDao
          .setIntent('tr7', Intent.trash, now: DateTime.utc(2026, 6, 2));

      final items = await db.todoDao.watchTrash().first;
      expect(items.map((t) => t.id).toList(), ['tr7', 'tr6']);
    });

    test('NULL last_clarified_at falls back to updated_at / created_at',
        () async {
      // Legacy row predating the stamp: trashed via a direct write, no
      // last_clarified_at. Must still sort (by updated_at) instead of
      // clumping at one end.
      await db.into(db.todos).insert(TodosCompanion(
        id: const Value('tr8'),
        title: const Value('Legacy trashed'),
        clarified: const Value(true),
        intent: const Value('trash'),
        userId: const Value(_userId),
        createdAt: Value(DateTime.utc(2026, 5, 1)),
        updatedAt: Value(DateTime.utc(2026, 5, 2)),
      ));
      await _insertTodo(db, id: 'tr9', title: 'Freshly trashed');
      await db.todoDao
          .setIntent('tr9', Intent.trash, now: DateTime.utc(2026, 6, 1));

      final items = await db.todoDao.watchTrash().first;
      expect(items.map((t) => t.id).toList(), ['tr9', 'tr8']);
    });
  });

  group('TodoDao — setIntent / deferTaskToMaybe', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('deferTaskToMaybe sets intent to maybe', () async {
      await _insertTodo(db, id: 'i1', title: 'Task I1');
      await db.todoDao.deferTaskToMaybe('i1');

      final row = await db.todoDao.getTodo('i1');
      expect(row?.intent, 'maybe');
    });

    test('setIntent updates intent and bumps updated_at', () async {
      await _insertTodo(db, id: 'i2', title: 'Task I2');
      final before = (await db.todoDao.getTodo('i2'))?.updatedAt;
      await db.todoDao.setIntent('i2', Intent.trash);

      final row = await db.todoDao.getTodo('i2');
      expect(row?.intent, 'trash');
      // updated_at should be set (may equal or be after before)
      expect(row?.updatedAt, isNotNull);
      if (before != null) {
        expect(row!.updatedAt!.isAfter(before) || row.updatedAt == before, isTrue);
      }
    });

  });

  group('TodoDao — updateFields', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('updates title and notes', () async {
      await _insertTodo(db, id: 'u1', title: 'Original');
      await db.todoDao.updateFields('u1', title: 'Updated', notes: 'Some notes');

      final row = await db.todoDao.getTodo('u1');
      expect(row?.title, 'Updated');
      expect(row?.notes, 'Some notes');
    });

    test('title change stamps lastClarifiedAt', () async {
      await _insertTodo(db, id: 'u2', title: 'Original');
      await db.todoDao.updateFields('u2', title: 'Renamed');

      final row = await db.todoDao.getTodo('u2');
      expect(row?.lastClarifiedAt, isNotNull);
    });

    test('clearDueDate stamps lastClarifiedAt', () async {
      await _insertTodo(db, id: 'u4', title: 'Task');
      // Set then immediately clear due date; both calls should stamp lastClarifiedAt.
      final due = DateTime.now().add(const Duration(days: 1));
      await db.todoDao.updateFields('u4', dueDate: due);
      await db.todoDao.updateFields('u4', clearDueDate: true);

      final row = await db.todoDao.getTodo('u4');
      expect(row?.lastClarifiedAt, isNotNull);
    });
  });

  group('TodoDao — restore via applyRouting', () {
    // Restore has no bespoke DAO method: the task-detail surface routes
    // through applyRouting(nextAction | maybe), whose forward matrix already
    // sets the intent, clears done_at, and stamps last_clarified_at.
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('done → applyRouting(nextAction) restores and stamps lastClarifiedAt',
        () async {
      // Restoring a done/trashed Outcome is an Intent edit (sets
      // intent='next', clears done_at) — a clarifying micro-act.
      await _insertTodo(db, id: 'res1', title: 'Task');
      await db.todoDao.markDone('res1');
      // Wipe the stamp set by markDone so we can verify restore stamps too.
      await (db.update(db.todos)..where((t) => t.id.equals('res1')))
          .write(const TodosCompanion(lastClarifiedAt: Value(null)));

      await db.todoDao.applyRouting('res1', to: RoutingKind.nextAction);

      final row = await db.todoDao.getTodo('res1');
      expect(row?.lastClarifiedAt, isNotNull);
      expect(row?.intent, 'next');
      expect(row?.doneAt, isNull);
    });
  });

  group('TodoDao — stampLastClarifiedAt', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('stamps lastClarifiedAt on the todo', () async {
      await _insertTodo(db, id: 's1', title: 'Task S1');
      await db.todoDao.stampLastClarifiedAt('s1');

      final row = await db.todoDao.getTodo('s1');
      expect(row?.lastClarifiedAt, isNotNull);
    });
  });

  group('TodoDao — applyRouting (forward matrix)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('nextAction: clarified=true, intent=next, done_at=null, '
        'current Action set when provided', () async {
      // Start with an unclarified row to confirm clarified=true is enforced.
      await _insertTodo(db, id: 'r1', title: 'Task', clarified: false);
      await db.todoDao.applyRouting(
        'r1',
        to: RoutingKind.nextAction,
        nextActionText: 'Buy milk',
      );

      final row = await db.todoDao.getTodo('r1');
      expect(row?.clarified, isTrue);
      expect(row?.intent, 'next');
      expect(row?.doneAt, isNull);
      expect((await db.actionDao.getCurrentAction('r1'))?.actionText,
          'Buy milk');
      expect(row?.lastClarifiedAt, isNotNull);
    });

    test('waitingFor: clarified=true, intent=next, done_at=null, '
        'current Action set when provided', () async {
      await _insertTodo(db, id: 'r2', title: 'Task', clarified: false);
      await db.todoDao.applyRouting(
        'r2',
        to: RoutingKind.waitingFor,
        nextActionText: 'Wait for Alice',
      );

      final row = await db.todoDao.getTodo('r2');
      expect(row?.clarified, isTrue);
      expect(row?.intent, 'next');
      expect(row?.doneAt, isNull);
      expect((await db.actionDao.getCurrentAction('r2'))?.actionText,
          'Wait for Alice');
    });

    test('maybe: clarified=true, intent=maybe, done_at=null, '
        'current Action untouched', () async {
      await _insertTodo(db, id: 'r3', title: 'Task', clarified: false);
      await db.todoDao.setNextActionText('r3', 'preserved');

      await db.todoDao.applyRouting(
        'r3',
        to: RoutingKind.maybe,
      );

      final row = await db.todoDao.getTodo('r3');
      expect(row?.clarified, isTrue);
      expect(row?.intent, 'maybe');
      expect(row?.doneAt, isNull);
      expect((await db.actionDao.getCurrentAction('r3'))?.actionText,
          'preserved',
          reason: 'routing to maybe leaves the current Action standing');
    });

    test('done: clarified=true, done_at=now, intent left as-is, and the '
        'completion cascade never touches the legacy cursor', () async {
      await _insertTodo(db, id: 'r4', title: 'Task', clarified: false);
      // Seed a legacy cursor value as a pre-retirement client would have left
      // it, plus a **real current Action** so `done` actually runs the
      // completion cascade. With an Actionless Outcome the "cursor untouched"
      // claim would hold for the wrong reason — no cascade would run at all.
      await (db.update(db.todos)..where((t) => t.id.equals('r4'))).write(
        const TodosCompanion(
          intent: Value('maybe'),
          nextActionText: Value('preserved'),
        ),
      );
      await db.actionDao.setCurrentAction('r4', 'finish it');

      await db.todoDao.applyRouting(
        'r4',
        to: RoutingKind.done,
      );

      final row = await db.todoDao.getTodo('r4');
      expect(row?.clarified, isTrue);
      expect(row?.intent, 'maybe', reason: 'done leaves intent untouched');
      expect(row?.doneAt, isNotNull);
      expect(await db.actionDao.getCurrentAction('r4'), isNull,
          reason: 'the cascade completed the current Action');
      expect(row?.nextActionText, 'preserved',
          reason: 'the retired cursor is neither read nor written (ADR-0022)');
    });

    test('trash: clarified=true, intent=trash, done_at=null', () async {
      await _insertTodo(db, id: 'r5', title: 'Task', clarified: false);
      await db.todoDao.applyRouting(
        'r5',
        to: RoutingKind.trash,
      );

      final row = await db.todoDao.getTodo('r5');
      expect(row?.clarified, isTrue);
      expect(row?.intent, 'trash');
      expect(row?.doneAt, isNull);
    });
  });

  group('TodoDao — applyRouting (cleanup rule: doneAt invariant)', () {
    // Single source of truth for the invariant: any non-Done, non-Trash route
    // clears doneAt if set. Done refreshes; Trash preserves history.
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    Future<void> seedDone(String id) async {
      await _insertTodo(db, id: id, title: 'Task');
      await db.todoDao.applyRouting(id, to: RoutingKind.done);
      expect((await db.todoDao.getTodo(id))?.doneAt, isNotNull);
    }

    test('done → nextAction clears done_at', () async {
      await seedDone('c1');
      await db.todoDao.applyRouting(
        'c1',
        to: RoutingKind.nextAction,
      );
      expect((await db.todoDao.getTodo('c1'))?.doneAt, isNull);
    });

    test('done → trash preserves done_at (Trash is historical, not "undo")',
        () async {
      await seedDone('c4');
      final beforeDone = (await db.todoDao.getTodo('c4'))?.doneAt;
      await db.todoDao.applyRouting(
        'c4',
        to: RoutingKind.trash,
      );
      final row = await db.todoDao.getTodo('c4');
      expect(row?.intent, 'trash');
      expect(row?.doneAt, equals(beforeDone),
          reason: 'trash must not erase the done timestamp');
    });

    test('done → done refreshes done_at to a new timestamp', () async {
      await seedDone('c5');
      final beforeStr = (await db.todoDao.getTodo('c5'))?.doneAt;
      expect(beforeStr, isNotNull);
      final beforeDone = DateTime.parse(beforeStr!);
      final later = beforeDone.add(const Duration(seconds: 1));
      await db.todoDao.applyRouting(
        'c5',
        to: RoutingKind.done,
        now: later,
      );
      final afterStr = (await db.todoDao.getTodo('c5'))?.doneAt;
      expect(afterStr, isNotNull);
      final afterDone = DateTime.parse(afterStr!);
      expect(afterDone.isAfter(beforeDone), isTrue,
          reason: 'done_at should be refreshed to a new timestamp');
    });

    test('routes other than done never set done_at on an undone todo',
        () async {
      Future<void> assertDoneAtNullAfter(String id, RoutingKind to) async {
        await _insertTodo(db, id: id, title: 'Task');
        await db.todoDao.applyRouting(id, to: to);
        expect((await db.todoDao.getTodo(id))?.doneAt, isNull);
      }

      await assertDoneAtNullAfter('u1', RoutingKind.nextAction);
      await assertDoneAtNullAfter('u2', RoutingKind.waitingFor);
      await assertDoneAtNullAfter('u3', RoutingKind.maybe);
      await assertDoneAtNullAfter('u4', RoutingKind.trash);
    });
  });

  group('TodoDao — applyRouting (transitions)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('trash → nextAction resets intent to next', () async {
      await _insertTodo(db, id: 't2', title: 'Task');
      await db.todoDao.applyRouting('t2', to: RoutingKind.trash);
      expect((await db.todoDao.getTodo('t2'))?.intent, 'trash');

      await db.todoDao.applyRouting(
        't2',
        to: RoutingKind.nextAction,
      );

      final row = await db.todoDao.getTodo('t2');
      expect(row?.intent, 'next');
      expect(row?.doneAt, isNull);
    });

    test('trash → maybe sets intent, clears done_at, stamps last_clarified_at',
        () async {
      // Restore-to-Someday/Maybe of a completed-then-trashed Outcome: the
      // cleanup invariant clears done_at so the row projects onto the Maybe
      // List (whose predicate requires done_at IS NULL), not onto Done.
      await _insertTodo(db, id: 't2m', title: 'Task');
      await db.todoDao.markDone('t2m');
      await db.todoDao.applyRouting('t2m', to: RoutingKind.trash);
      expect((await db.todoDao.getTodo('t2m'))?.doneAt, isNotNull,
          reason: 'trash preserves the completion record');

      await db.todoDao.applyRouting('t2m', to: RoutingKind.maybe);

      final row = await db.todoDao.getTodo('t2m');
      expect(row?.intent, 'maybe');
      expect(row?.doneAt, isNull);
      expect(row?.lastClarifiedAt, isNotNull);
      final maybe = await db.todoDao.watchMaybe().first;
      expect(maybe.map((t) => t.id), contains('t2m'));
    });

    test('trash → nextAction preserves person tags (orthogonality)',
        () async {
      // A delegated Outcome restored out of Trash keeps its PersonBlocker,
      // so it correctly resurfaces on Waiting For too.
      await _insertTodo(db, id: 't2p', title: 'Delegated, trashed');
      await _insertPersonTag(db, id: 't2p-trixy', name: 'Trixy');
      await db.tagDao.assignTag('t2p', 't2p-trixy', _userId);
      await db.todoDao.applyRouting('t2p', to: RoutingKind.trash);

      await db.todoDao.applyRouting('t2p', to: RoutingKind.nextAction);

      expect(await db.todoDao.getPersonTagIdsForTodo('t2p'),
          contains('t2p-trixy'));
    });

    test(
        'restored actionless PersonBlocked Outcome lands on Waiting For, '
        'not Next (excluded quadrant — intended, not a restore bug)',
        () async {
      await _insertTodo(db, id: 't2w', title: 'Hear back from Dave');
      await _insertPersonTag(db, id: 't2w-dave', name: 'Dave');
      await db.tagDao.assignTag('t2w', 't2w-dave', _userId);
      await db.todoDao.applyRouting('t2w', to: RoutingKind.trash);

      await db.todoDao.applyRouting('t2w', to: RoutingKind.nextAction);

      final next = await db.todoDao.watchNext().first;
      final waiting = await db.todoDao.watchPersonTagged().first;
      expect(next.any((t) => t.id == 't2w'), isFalse,
          reason: 'actionless+PersonBlocked stays off Next after restore');
      expect(waiting.map((t) => t.id), contains('t2w'));
    });

    test('maybe → nextAction resets intent to next', () async {
      await _insertTodo(db, id: 't3', title: 'Task');
      await db.todoDao.applyRouting('t3', to: RoutingKind.maybe);

      await db.todoDao.applyRouting(
        't3',
        to: RoutingKind.nextAction,
        nextActionText: 'Do it',
      );

      final row = await db.todoDao.getTodo('t3');
      expect(row?.intent, 'next');
      expect((await db.actionDao.getCurrentAction('t3'))?.actionText, 'Do it');
    });

    test('waitingFor → nextAction preserves person tags (orthogonality)',
        () async {
      // Person tags are independent of intent — a delegated task can have
      // an action route applied to it without losing its delegate. The
      // picker is the only path that mutates person tags.
      await _insertTodo(db, id: 't4', title: 'Task');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      await db.tagDao.assignTag('t4', 'alice', _userId);

      await db.todoDao.applyRouting(
        't4',
        to: RoutingKind.waitingFor,
      );
      expect(await db.todoDao.getPersonTagIdsForTodo('t4'),
          contains('alice'));

      // Transitioning to nextAction without explicit `personTagIds` leaves
      // the delegate intact.
      await db.todoDao.applyRouting(
        't4',
        to: RoutingKind.nextAction,
      );

      final tagIds = await db.todoDao.getPersonTagIdsForTodo('t4');
      expect(tagIds, contains('alice'),
          reason: 'person tags survive an intent-only transition');
    });

    test('waitingFor → waitingFor overwrites person tags when provided',
        () async {
      await _insertTodo(db, id: 't5', title: 'Task');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      await _insertPersonTag(db, id: 'bob', name: 'Bob');
      await db.tagDao.assignTag('t5', 'alice', _userId);

      await db.todoDao.applyRouting(
        't5',
        to: RoutingKind.waitingFor,
        nextActionText: 'Ping Bob',
        personTagIds: {'bob'},
        userId: _userId,
      );

      final tagIds = await db.todoDao.getPersonTagIdsForTodo('t5');
      expect(tagIds, equals({'bob'}));
      expect(
          (await db.actionDao.getCurrentAction('t5'))?.actionText, 'Ping Bob');
    });

    test('non-waitingFor transitions leave person tags untouched', () async {
      // Pre-existing person tag from import / sync.
      await _insertTodo(db, id: 't6', title: 'Task');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      await db.tagDao.assignTag('t6', 'alice', _userId);

      // maybe → nextAction must not drop pre-existing person tags.
      await db.todoDao.applyRouting('t6', to: RoutingKind.maybe);
      await db.todoDao.applyRouting(
        't6',
        to: RoutingKind.nextAction,
      );

      expect(await db.todoDao.getPersonTagIdsForTodo('t6'), contains('alice'));
    });

    test('idempotent: applying same kind twice is a net no-op', () async {
      await _insertTodo(db, id: 't8', title: 'Task');
      await db.todoDao.applyRouting('t8', to: RoutingKind.maybe);
      final after1 = await db.todoDao.getTodo('t8');

      await db.todoDao.applyRouting(
        't8',
        to: RoutingKind.maybe,
      );
      final after2 = await db.todoDao.getTodo('t8');

      expect(after2?.intent, after1?.intent);
      expect(after2?.clarified, after1?.clarified);
      expect(after2?.doneAt, after1?.doneAt);
      expect(after2?.nextActionText, after1?.nextActionText);
    });
  });

  group('TodoDao — setPersonTagsForTodo', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('only touches person-typed tags, leaves other tags untouched',
        () async {
      await _insertTodo(db, id: 'p1', title: 'Task');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      // Non-person tag attached to the same todo.
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('ctx'),
        name: Value('Office'),
        type: Value('context'),
        userId: Value(_userId),
      ));
      await db.tagDao.assignTag('p1', 'ctx', _userId);
      await db.tagDao.assignTag('p1', 'alice', _userId);

      // Clear person tags.
      await db.todoDao.setPersonTagsForTodo('p1', const <String>{}, _userId);

      // Person tag gone, non-person tag preserved.
      expect(await db.todoDao.getPersonTagIdsForTodo('p1'), isEmpty);
      final allLinks = await (db.select(db.todoTags)
            ..where((tt) => tt.todoId.equals('p1')))
          .get();
      expect(allLinks.map((r) => r.tagId), contains('ctx'));
    });

    test('replaces existing person tags with a non-empty target set, '
        'preserves non-person tags', () async {
      await _insertTodo(db, id: 'p2', title: 'Task');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      await _insertPersonTag(db, id: 'bob', name: 'Bob');
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('ctx2'),
        name: Value('Home'),
        type: Value('context'),
        userId: Value(_userId),
      ));
      await db.tagDao.assignTag('p2', 'ctx2', _userId);
      await db.tagDao.assignTag('p2', 'alice', _userId);

      // Replace person tags: drop alice, add bob.
      await db.todoDao.setPersonTagsForTodo('p2', {'bob'}, _userId);

      expect(await db.todoDao.getPersonTagIdsForTodo('p2'), equals({'bob'}));
      final allLinks = await (db.select(db.todoTags)
            ..where((tt) => tt.todoId.equals('p2')))
          .get();
      final tagIds = allLinks.map((r) => r.tagId).toSet();
      expect(tagIds, contains('ctx2'),
          reason: 'non-person tag must be preserved');
      expect(tagIds, contains('bob'),
          reason: 'new person tag must be added');
      expect(tagIds, isNot(contains('alice')),
          reason: 'replaced person tag must be removed');
    });
  });
}
