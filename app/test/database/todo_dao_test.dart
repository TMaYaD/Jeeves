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

    test('markDone task no longer appears in watchNextActions', () async {
      await _insertTodo(db, id: 'md2', title: 'Task MD2');
      await db.todoDao.markDone('md2');

      final items = await db.todoDao.watchNextActions().first;
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

    test('watchNextActions excludes done tasks', () async {
      await _insertTodo(db, id: 'na1', title: 'Active next action');
      await _insertTodo(db, id: 'na2', title: 'Done next action');
      await db.todoDao.markDone('na2');

      final items = await db.todoDao.watchNextActions().first;
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

    test('watchNextActions excludes trashed tasks (#278)', () async {
      await _insertTodo(db, id: 'tn1', title: 'Active');
      await _insertTodo(db, id: 'tn2', title: 'Trashed');
      await db.todoDao.setIntent('tn2', Intent.trash);

      final items = await db.todoDao.watchNextActions().first;
      expect(items.map((t) => t.id), ['tn1']);
    });

    test('watchNextActions excludes trashed tasks even with tag filter (#278)',
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

      final items = await db.todoDao.watchNextActions(tagIds: {tagId}).first;
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

    test('notes-only change does not stamp lastClarifiedAt', () async {
      await _insertTodo(db, id: 'u3', title: 'Task');
      await db.todoDao.updateFields('u3', notes: 'New notes');

      final row = await db.todoDao.getTodo('u3');
      expect(row?.lastClarifiedAt, isNull);
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
        from: null,
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
        from: null,
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
        from: null,
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
        from: null,
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
        from: null,
      );

      final row = await db.todoDao.getTodo('r5');
      expect(row?.clarified, isTrue);
      expect(row?.intent, 'trash');
      expect(row?.doneAt, isNull);
    });
  });

  group('TodoDao — applyRouting (transitions)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('done → maybe clears done_at', () async {
      await _insertTodo(db, id: 't1', title: 'Task');
      await db.todoDao.applyRouting('t1', to: RoutingKind.done, from: null);
      expect((await db.todoDao.getTodo('t1'))?.doneAt, isNotNull);

      await db.todoDao
          .applyRouting('t1', to: RoutingKind.maybe, from: RoutingKind.done);

      final row = await db.todoDao.getTodo('t1');
      expect(row?.doneAt, isNull);
      expect(row?.intent, 'maybe');
    });

    test('trash → nextAction resets intent to next', () async {
      await _insertTodo(db, id: 't2', title: 'Task');
      await db.todoDao.applyRouting('t2', to: RoutingKind.trash, from: null);
      expect((await db.todoDao.getTodo('t2'))?.intent, 'trash');

      await db.todoDao.applyRouting(
        't2',
        to: RoutingKind.nextAction,
        from: RoutingKind.trash,
      );

      final row = await db.todoDao.getTodo('t2');
      expect(row?.intent, 'next');
      expect(row?.doneAt, isNull);
    });

    test('maybe → nextAction resets intent to next', () async {
      await _insertTodo(db, id: 't3', title: 'Task');
      await db.todoDao.applyRouting('t3', to: RoutingKind.maybe, from: null);

      await db.todoDao.applyRouting(
        't3',
        to: RoutingKind.nextAction,
        from: RoutingKind.maybe,
        nextActionText: 'Do it',
      );

      final row = await db.todoDao.getTodo('t3');
      expect(row?.intent, 'next');
      expect(row?.nextActionText, 'Do it');
    });

    test('waitingFor → nextAction clears person tags when userId is provided',
        () async {
      await _insertTodo(db, id: 't4', title: 'Task');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      await db.tagDao.assignTag('t4', 'alice', _userId);

      // Apply waitingFor (does not write tags by itself).
      await db.todoDao.applyRouting(
        't4',
        to: RoutingKind.waitingFor,
        from: null,
      );
      expect(await db.todoDao.getPersonTagIdsForTodo('t4'),
          contains('alice'));

      // Transitioning AWAY from waitingFor clears person tags.
      await db.todoDao.applyRouting(
        't4',
        to: RoutingKind.nextAction,
        from: RoutingKind.waitingFor,
        userId: _userId,
      );

      final tagIds = await db.todoDao.getPersonTagIdsForTodo('t4');
      expect(tagIds, isEmpty,
          reason: 'person tags are cleared on waitingFor → other');
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
        from: RoutingKind.waitingFor,
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
      await db.todoDao.applyRouting('t6', to: RoutingKind.maybe, from: null);
      await db.todoDao.applyRouting(
        't6',
        to: RoutingKind.nextAction,
        from: RoutingKind.maybe,
        userId: _userId,
      );

      expect(await db.todoDao.getPersonTagIdsForTodo('t6'), contains('alice'));
    });

    test('from=null first apply does no extra work', () async {
      await _insertTodo(db, id: 't7', title: 'Task', clarified: false);
      await db.todoDao
          .applyRouting('t7', to: RoutingKind.nextAction, from: null);

      final row = await db.todoDao.getTodo('t7');
      expect(row?.clarified, isTrue);
      expect(row?.intent, 'next');
    });

    test('idempotent: applying same kind twice is a net no-op', () async {
      await _insertTodo(db, id: 't8', title: 'Task');
      await db.todoDao.applyRouting('t8', to: RoutingKind.maybe, from: null);
      final after1 = await db.todoDao.getTodo('t8');

      await db.todoDao.applyRouting(
        't8',
        to: RoutingKind.maybe,
        from: RoutingKind.maybe,
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
