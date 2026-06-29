import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

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

    test('watchMaybe excludes intent=next todos', () async {
      await _insertTodo(db, id: 'n1', title: 'Next action');

      final items = await db.todoDao.watchMaybe().first;
      expect(items, isEmpty);
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

    test('markDone task no longer appears in watchNext', () async {
      await _insertTodo(db, id: 'md2', title: 'Task MD2');
      await db.todoDao.markDone('md2');

      final items = await db.todoDao.watchNext().first;
      expect(items.any((t) => t.id == 'md2'), isFalse);
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

    test('watchMaybe excludes done maybe tasks', () async {
      await _insertTodo(db, id: 'mm1', title: 'Active maybe');
      await _insertTodo(db, id: 'mm2', title: 'Done maybe');
      await db.todoDao.deferTaskToMaybe('mm1');
      await db.todoDao.deferTaskToMaybe('mm2');
      await db.todoDao.markDone('mm2');

      final items = await db.todoDao.watchMaybe().first;
      expect(items.length, 1);
      expect(items.first.id, 'mm1');
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

    test('notes edit stamps lastClarifiedAt', () async {
      // Per CONTEXT.md ~L152: title/notes/Intent/due-date edits are clarifying
      // micro-acts and must stamp last_clarified_at.
      await _insertTodo(db, id: 'u3', title: 'Task');
      await db.todoDao.updateFields('u3', notes: 'New notes');

      final row = await db.todoDao.getTodo('u3');
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

    test('energyLevel edit stamps lastClarifiedAt', () async {
      // energyLevel is an Action cursor-field (ADR-0001). Action mutations
      // count as clarifying micro-acts per CONTEXT.md ~L152.
      await _insertTodo(db, id: 'u5', title: 'Task');
      await db.todoDao.updateFields('u5', energyLevel: 'high');

      final row = await db.todoDao.getTodo('u5');
      expect(row?.lastClarifiedAt, isNotNull);
    });

    test('clearEnergyLevel stamps lastClarifiedAt', () async {
      await _insertTodo(db, id: 'u5c', title: 'Task');
      await db.todoDao.updateFields('u5c', clearEnergyLevel: true);

      final row = await db.todoDao.getTodo('u5c');
      expect(row?.lastClarifiedAt, isNotNull);
    });

    test('timeEstimate edit stamps lastClarifiedAt', () async {
      // timeEstimate is an Action cursor-field (ADR-0001). Action mutations
      // count as clarifying micro-acts per CONTEXT.md ~L152.
      await _insertTodo(db, id: 'u6', title: 'Task');
      await db.todoDao.updateFields('u6', timeEstimate: 30);

      final row = await db.todoDao.getTodo('u6');
      expect(row?.lastClarifiedAt, isNotNull);
    });

    test('clearTimeEstimate stamps lastClarifiedAt', () async {
      await _insertTodo(db, id: 'u6c', title: 'Task');
      await db.todoDao.updateFields('u6c', clearTimeEstimate: true);

      final row = await db.todoDao.getTodo('u6c');
      expect(row?.lastClarifiedAt, isNotNull);
    });
  });

  group('TodoDao — rescheduleTask stamps lastClarifiedAt', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('rescheduleTask stamps lastClarifiedAt', () async {
      // Due-date edit is a clarifying micro-act per CONTEXT.md ~L152.
      await _insertTodo(db, id: 'rs1', title: 'Reschedulable');
      await db.todoDao.rescheduleTask('rs1', DateTime(2026, 5, 1));

      final row = await db.todoDao.getTodo('rs1');
      expect(row?.lastClarifiedAt, isNotNull);
    });
  });

  group('TodoDao — restore stamps lastClarifiedAt', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('restore stamps lastClarifiedAt', () async {
      // Restoring a done/trashed Outcome is an Intent edit (sets
      // intent='next', clears done_at) — a clarifying micro-act.
      await _insertTodo(db, id: 'res1', title: 'Task');
      await db.todoDao.markDone('res1');
      // Wipe the stamp set by markDone so we can verify restore stamps too.
      await (db.update(db.todos)..where((t) => t.id.equals('res1')))
          .write(const TodosCompanion(lastClarifiedAt: Value(null)));

      await db.todoDao.restore('res1');

      final row = await db.todoDao.getTodo('res1');
      expect(row?.lastClarifiedAt, isNotNull);
    });
  });

  group('TodoDao — clearDoneAt stamps lastClarifiedAt', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('clearDoneAt stamps lastClarifiedAt', () async {
      // Reverting a Completion is a structural decision about the Outcome —
      // the dual of marking done, which itself stamps. Per CONTEXT.md ~L152
      // Outcome completion stamps; un-doing it is the same kind of micro-act.
      await _insertTodo(db, id: 'cd1', title: 'Task');
      await db.todoDao.markDone('cd1');
      // Wipe the stamp set by markDone.
      await (db.update(db.todos)..where((t) => t.id.equals('cd1')))
          .write(const TodosCompanion(lastClarifiedAt: Value(null)));

      await db.todoDao.clearDoneAt('cd1');

      final row = await db.todoDao.getTodo('cd1');
      expect(row?.lastClarifiedAt, isNotNull);
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
        'next_action_text set when provided', () async {
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
      expect(row?.nextActionText, 'Buy milk');
      expect(row?.lastClarifiedAt, isNotNull);
    });

    test('waitingFor: clarified=true, intent=next, done_at=null, '
        'next_action_text set when provided', () async {
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
      expect(row?.nextActionText, 'Wait for Alice');
    });

    test('maybe: clarified=true, intent=maybe, done_at=null, '
        'next_action_text untouched', () async {
      await _insertTodo(db, id: 'r3', title: 'Task', clarified: false);
      // Pre-set next_action_text so we can confirm "leave" semantics.
      await (db.update(db.todos)..where((t) => t.id.equals('r3')))
          .write(const TodosCompanion(nextActionText: Value('preserved')));

      await db.todoDao.applyRouting(
        'r3',
        to: RoutingKind.maybe,
      );

      final row = await db.todoDao.getTodo('r3');
      expect(row?.clarified, isTrue);
      expect(row?.intent, 'maybe');
      expect(row?.doneAt, isNull);
      expect(row?.nextActionText, 'preserved');
    });

    test('done: clarified=true, done_at=now, intent left as-is, '
        'next_action_text untouched', () async {
      await _insertTodo(db, id: 'r4', title: 'Task', clarified: false);
      // Seed intent and next_action_text so we can confirm "leave".
      await (db.update(db.todos)..where((t) => t.id.equals('r4'))).write(
        const TodosCompanion(
          intent: Value('maybe'),
          nextActionText: Value('preserved'),
        ),
      );

      await db.todoDao.applyRouting(
        'r4',
        to: RoutingKind.done,
      );

      final row = await db.todoDao.getTodo('r4');
      expect(row?.clarified, isTrue);
      expect(row?.intent, 'maybe', reason: 'done leaves intent untouched');
      expect(row?.doneAt, isNotNull);
      expect(row?.nextActionText, 'preserved');
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

    test('done → waitingFor clears done_at', () async {
      await seedDone('c2');
      await db.todoDao.applyRouting(
        'c2',
        to: RoutingKind.waitingFor,
      );
      expect((await db.todoDao.getTodo('c2'))?.doneAt, isNull);
    });

    test('done → maybe clears done_at', () async {
      await seedDone('c3');
      await db.todoDao.applyRouting(
        'c3',
        to: RoutingKind.maybe,
      );
      final row = await db.todoDao.getTodo('c3');
      expect(row?.doneAt, isNull);
      expect(row?.intent, 'maybe');
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
      expect(row?.nextActionText, 'Do it');
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
      final row = await db.todoDao.getTodo('t5');
      expect(row?.nextActionText, 'Ping Bob');
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

    test('first apply does no extra work', () async {
      await _insertTodo(db, id: 't7', title: 'Task', clarified: false);
      await db.todoDao
          .applyRouting('t7', to: RoutingKind.nextAction);

      final row = await db.todoDao.getTodo('t7');
      expect(row?.clarified, isTrue);
      expect(row?.intent, 'next');
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
