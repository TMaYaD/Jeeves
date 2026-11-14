/// Bulk writes behind the list multi-select: one transaction per action, the
/// subject-deleted skip inside it, and Organising never touching `todos`.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/tag_dao.dart' show todoTagIdFor;
import 'package:jeeves/database/daos/todo_dao.dart'
    show StalePersonSelectionException;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/routing_kind.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/domain_op_capture.dart';

import '../test_helpers.dart';

const _userId = 'test-user';
final _seedTs = DateTime.utc(2026, 7, 28, 9);
final _bulkTs = DateTime.utc(2026, 7, 29, 9);

void main() {
  setUpAll(configureSqliteForTests);

  late RecordingDomainOpCapture capture;
  late GtdDatabase db;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    capture = RecordingDomainOpCapture();
    db = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
  });
  tearDown(() async => db.close());

  Future<void> seed(Iterable<String> ids) async {
    for (final id in ids) {
      await db.todoDao
          .insertOutcome(id: id, title: id, userId: _userId, now: _seedTs);
    }
    capture.clear();
  }

  Future<Todo> row(String id) =>
      (db.select(db.todos)..where((t) => t.id.equals(id))).getSingle();

  Future<Set<String>> tagIdsOf(String todoId) async {
    final rows = await (db.select(db.todoTags)
          ..where((tt) => tt.todoId.equals(todoId)))
        .get();
    return {for (final r in rows) r.tagId};
  }

  group('Organising batches (TagDao)', () {
    test('assignTagToOutcomes lands on every present id and skips an absent one',
        () async {
      await seed(['a', 'b']);
      final tag = await db.tagDao.findOrCreateTag('home', 'context', _userId);
      capture.clear();

      final written =
          await db.tagDao.assignTagToOutcomes({'a', 'b', 'gone'}, tag, _userId);

      expect(written, {'a', 'b'});
      expect(await tagIdsOf('a'), {tag});
      expect(await tagIdsOf('b'), {tag});
      expect(await tagIdsOf('gone'), isEmpty);
      expect(capture.recorded.map((o) => o.collection).toSet(),
          {todoTagsCollection});
      expect(capture.forCollection(todoTagsCollection), hasLength(2));
    });

    test('Project and Tag batches leave todos untouched', () async {
      await seed(['a', 'b']);
      final before = await row('a');
      final tag = await db.tagDao.findOrCreateTag('home', 'context', _userId);
      final project = await db.tagDao.findOrCreateTag('P', 'project', _userId);

      await db.tagDao.assignTagToOutcomes({'a', 'b'}, tag, _userId);
      await db.tagDao.setProjectForOutcomes({'a', 'b'}, project, _userId);

      final after = await row('a');
      expect(after.lastClarifiedAt, before.lastClarifiedAt);
      expect(after.updatedAt, before.updatedAt);
      expect(capture.forCollection(todosCollection), isEmpty);
    });

    test('setProjectForOutcomes replaces the old Project with a tombstone',
        () async {
      await seed(['a', 'b']);
      final first = await db.tagDao.findOrCreateTag('P1', 'project', _userId);
      final second = await db.tagDao.findOrCreateTag('P2', 'project', _userId);
      await db.tagDao.enforceSingleProject('a', _userId, first);
      capture.clear();

      final written =
          await db.tagDao.setProjectForOutcomes({'a', 'b', 'gone'}, second, _userId);

      expect(written, {'a', 'b'});
      expect(await tagIdsOf('a'), {second});
      expect(await tagIdsOf('b'), {second});
      final byId = {
        for (final op in capture.forCollection(todoTagsCollection))
          op.entityId: op.tombstone,
      };
      expect(byId[todoTagIdFor('a', first)], isTrue);
      expect(byId[todoTagIdFor('a', second)], isFalse);
      expect(byId[todoTagIdFor('b', second)], isFalse);
      expect(byId.containsKey(todoTagIdFor('gone', second)), isFalse);
    });

    test('setProjectForOutcomes writes nothing when the Project is gone',
        () async {
      await seed(['a']);
      final written =
          await db.tagDao.setProjectForOutcomes({'a'}, 'no-such-tag', _userId);
      expect(written, isEmpty);
      expect(capture.recorded, isEmpty);
    });

    test('removeTagFromOutcomes tombstones only junctions that were held',
        () async {
      await seed(['a', 'b']);
      final tag = await db.tagDao.findOrCreateTag('home', 'context', _userId);
      await db.tagDao.assignTag('a', tag, _userId);
      capture.clear();

      final removed =
          await db.tagDao.removeTagFromOutcomes({'a', 'b'}, tag);

      expect(removed, {'a'});
      expect(await tagIdsOf('a'), isEmpty);
      final ops = capture.forCollection(todoTagsCollection);
      expect(ops, hasLength(1));
      expect(ops.single.entityId, todoTagIdFor('a', tag));
      expect(ops.single.tombstone, isTrue);
    });

    test('removeTagFromOutcomes leaves a dangling junction of an absent Outcome',
        () async {
      await seed(['a']);
      final tag = await db.tagDao.findOrCreateTag('home', 'context', _userId);
      await db.into(db.todoTags).insert(TodoTagsCompanion(
            id: Value(todoTagIdFor('gone', tag)),
            todoId: const Value('gone'),
            tagId: Value(tag),
            userId: const Value(_userId),
          ));
      capture.clear();

      final removed =
          await db.tagDao.removeTagFromOutcomes({'a', 'gone'}, tag);

      expect(removed, isEmpty);
      expect(await tagIdsOf('gone'), {tag});
      expect(capture.recorded, isEmpty);
    });

    test('person and project tags are refused by the Tag batches', () async {
      await seed(['a']);
      final person = await db.tagDao.findOrCreateTag('Sam', 'person', _userId);
      final project = await db.tagDao.findOrCreateTag('P', 'project', _userId);
      for (final id in [person, project]) {
        expect(() => db.tagDao.assignTagToOutcomes({'a'}, id, _userId),
            throwsArgumentError);
        expect(() => db.tagDao.removeTagFromOutcomes({'a'}, id),
            throwsArgumentError);
      }
      expect(await tagIdsOf('a'), isEmpty);
    });
  });

  group('applyRoutingToOutcomes', () {
    test('each destination equals applyRouting for the same Outcome', () async {
      for (final to in [
        RoutingKind.nextAction,
        RoutingKind.maybe,
        RoutingKind.done,
        RoutingKind.trash,
      ]) {
        await seed(['bulk', 'single']);
        final landed = await db.todoDao.applyRoutingToOutcomes({'bulk'},
            to: to, personTagIds: to == RoutingKind.nextAction ? {} : null,
            userId: _userId, now: _bulkTs);
        await db.todoDao.applyRouting('single',
            to: to, personTagIds: to == RoutingKind.nextAction ? {} : null,
            userId: _userId, now: _bulkTs);
        expect(landed, {'bulk'});
        final bulk = await row('bulk');
        final single = await row('single');
        expect(bulk.intent, single.intent, reason: '$to');
        expect(bulk.doneAt, single.doneAt, reason: '$to');
        expect(bulk.lastClarifiedAt, _bulkTs, reason: '$to');
        await db.todoDao.deleteOutcome('bulk');
        await db.todoDao.deleteOutcome('single');
      }
    });

    test('authors one todos op per landed Outcome and skips an absent id',
        () async {
      await seed(['a', 'b']);
      final landed = await db.todoDao.applyRoutingToOutcomes({'a', 'b', 'gone'},
          to: RoutingKind.maybe, now: _bulkTs);
      expect(landed, {'a', 'b'});
      expect(
          {for (final op in capture.forCollection(todosCollection)) op.entityId},
          {'a', 'b'});
      expect(capture.forCollection(todosCollection), hasLength(2));
      expect((await row('a')).intent, 'maybe');
    });

    test('Waiting For replaces the person set; Next clears it with tombstones',
        () async {
      await seed(['a']);
      final sam = await db.tagDao.findOrCreateTag('Sam', 'person', _userId);
      final kim = await db.tagDao.findOrCreateTag('Kim', 'person', _userId);
      await db.tagDao.assignTag('a', sam, _userId);
      capture.clear();

      await db.todoDao.applyRoutingToOutcomes({'a'},
          to: RoutingKind.waitingFor,
          personTagIds: {kim},
          userId: _userId,
          now: _bulkTs);
      expect(await tagIdsOf('a'), {kim});

      capture.clear();
      await db.todoDao.applyRoutingToOutcomes({'a'},
          to: RoutingKind.nextAction,
          personTagIds: {},
          userId: _userId,
          now: _bulkTs);
      expect(await tagIdsOf('a'), isEmpty);
      final tomb = capture.forCollection(todoTagsCollection).single;
      expect(tomb.tombstone, isTrue);
      expect(tomb.entityId, todoTagIdFor('a', kim));
    });

    test('a deleted Person refuses the whole Waiting For batch', () async {
      await seed(['a', 'b']);
      final sam = await db.tagDao.findOrCreateTag('Sam', 'person', _userId);
      final kim = await db.tagDao.findOrCreateTag('Kim', 'person', _userId);
      await db.tagDao.assignTag('a', sam, _userId);
      await db.tagDao.deleteTag(kim);
      capture.clear();
      final before = await row('a');

      await expectLater(
        db.todoDao.applyRoutingToOutcomes({'a', 'b'},
            to: RoutingKind.waitingFor,
            personTagIds: {kim},
            userId: _userId,
            now: _bulkTs),
        throwsA(isA<StalePersonSelectionException>()),
      );

      expect(await tagIdsOf('a'), {sam});
      expect((await row('a')).intent, before.intent);
      expect((await row('a')).lastClarifiedAt, before.lastClarifiedAt);
      expect(capture.recorded, isEmpty);
    });

    test('a failure part-way rolls the whole batch back and authors no ops',
        () async {
      await seed(['a', 'b']);
      final sam = await db.tagDao.findOrCreateTag('Sam', 'person', _userId);
      capture.clear();
      final before = await row('a');

      await expectLater(
        db.todoDao.applyRoutingToOutcomes({'a', 'b'},
            to: RoutingKind.waitingFor, personTagIds: {sam}, userId: null,
            now: _bulkTs),
        throwsArgumentError,
      );

      expect((await row('a')).intent, before.intent);
      expect((await row('a')).lastClarifiedAt, before.lastClarifiedAt);
      expect(capture.recorded, isEmpty);
    });
  });
}
