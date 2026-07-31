import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart'
    show ApplyInterceptor, InvalidDataException, Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/daos/capture_dao.dart' show captureTagIdFor;
import 'package:jeeves/database/daos/tag_dao.dart' show todoTagIdFor;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/import/nirvana_local_import.dart';
import 'package:jeeves/import/nirvana_parser.dart' show ParseError;
import 'package:jeeves/sync/collection_codecs.dart'
    show
        captureTagsCollection,
        capturesCollection,
        collectionCodecs,
        tagsCollection,
        todoTagsCollection,
        todosCollection;
import 'package:jeeves/sync/domain_op_capture.dart'
    show RecordingDomainOpCapture;

import '../sync/harness/fault_injecting_store.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

/// One-shot list of todos linked to [tagId] via the todo_tags junction.
Future<List<Todo>> _todosLinkedToTag(GtdDatabase db, String tagId) async {
  final links = await (db.select(db.todoTags)
        ..where((tt) => tt.tagId.equals(tagId)))
      .get();
  final ids = links.map((l) => l.todoId).toSet();
  final todos = await db.select(db.todos).get();
  return todos.where((t) => ids.contains(t.id)).toList();
}

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

Uint8List _fixtureBytes(String name) =>
    File('test/fixtures/$name').readAsBytesSync();

const _userId = 'test-user';

void main() {
  setUpAll(configureSqliteForTests);

  group('importNirvanaLocally — CSV', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('imports tasks from sample CSV fixture', () async {
      final result = await importNirvanaLocally(
        bytes: _fixtureBytes('nirvana_sample.csv'),
        filename: 'nirvana_sample.csv',
        format: 'auto',
        userId: _userId,
        db: db,
      );

      expect(result.importedCount, 4); // 4 tasks (project is skipped as task)
      expect(result.skippedCount, 0);
      expect(result.projectTagsCreated, 1);
    });

    test('project tag is created and assigned to child tasks', () async {
      await importNirvanaLocally(
        bytes: _fixtureBytes('nirvana_sample.csv'),
        filename: 'nirvana_sample.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );

      final projectTags =
          await db.tagDao.watchByType('project').first;
      expect(projectTags.length, 1);
      expect(projectTags.first.name, 'Brush up on GTD®');

      final tagId = projectTags.first.id;
      final tasksByProject = await _todosLinkedToTag(db, tagId);
      expect(tasksByProject.length, 2);
    });

    test('context tags are created from the TAGS column', () async {
      await importNirvanaLocally(
        bytes: _fixtureBytes('nirvana_sample.csv'),
        filename: 'nirvana_sample.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );

      final contextTags =
          await db.tagDao.watchByType('context').first;
      final names = contextTags.map((t) => t.name).toSet();
      expect(names, containsAll(['computer', 'Personal', 'anywhere']));
    });

    test('done tasks are stored with doneAt set', () async {
      await importNirvanaLocally(
        bytes: _fixtureBytes('nirvana_sample.csv'),
        filename: 'nirvana_sample.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );

      final done = await db.todoDao.watchDone().first;
      expect(done.length, 2);
    });

    test('non-done tasks are stored with doneAt null', () async {
      await importNirvanaLocally(
        bytes: _fixtureBytes('nirvana_sample.csv'),
        filename: 'nirvana_sample.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );

      final all = await (db.select(db.todos)
            ..where((t) => t.userId.equals(_userId)))
          .get();
      final notDone = all.where((t) => t.doneAt == null).toList();
      expect(notDone.length, 2);
    });

    test('capture_source is set to nirvana_import', () async {
      await importNirvanaLocally(
        bytes: _fixtureBytes('nirvana_sample.csv'),
        filename: 'nirvana_sample.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );

      final all = await (db.select(db.todos)
            ..where((t) => t.userId.equals(_userId)))
          .get();
      expect(all.every((t) => t.captureSource == 'nirvana_import'), isTrue);
    });

    test('re-importing same CSV is idempotent (no duplicates)', () async {
      final bytes = _fixtureBytes('nirvana_sample.csv');

      await importNirvanaLocally(
        bytes: bytes,
        filename: 'nirvana_sample.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );
      await importNirvanaLocally(
        bytes: bytes,
        filename: 'nirvana_sample.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );

      final all = await (db.select(db.todos)
            ..where((t) => t.userId.equals(_userId)))
          .get();
      expect(all.length, 4);
    });

    test('energy level and time estimate are stored', () async {
      await importNirvanaLocally(
        bytes: _fixtureBytes('nirvana_sample.csv'),
        filename: 'nirvana_sample.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );

      final all = await (db.select(db.todos)
            ..where((t) => t.userId.equals(_userId)))
          .get();
      final readBook =
          all.firstWhere((t) => t.title == 'Read the Book');
      expect(readBook.energyLevel, 'medium');
      expect(readBook.timeEstimate, 240);
    });

    test('empty CSV returns zero imported', () async {
      const csv = 'TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n';
      final result = await importNirvanaLocally(
        bytes: _bytes(csv),
        filename: 'empty.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );

      expect(result.importedCount, 0);
      expect(result.projectTagsCreated, 0);
    });

    test('Inbox state → a Capture (not a clarified=false todo), issue #184',
        () async {
      const csv =
          'TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n'
          'Task,Unprocessed idea,Inbox,,a note,work,,,,,\n';
      final result = await importNirvanaLocally(
        bytes: _bytes(csv),
        filename: 'test.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );

      expect(result.importedCount, 1);

      // No todo row is written for an unclarified item.
      final todos = await (db.select(db.todos)
            ..where((t) => t.userId.equals(_userId)))
          .get();
      expect(todos, isEmpty);

      // It lands in the Inbox as a Capture (clarified_at IS NULL).
      final inbox = await db.captureDao.watchInbox().first;
      expect(inbox.map((c) => c.title), ['Unprocessed idea']);
      expect(inbox.first.notes, 'a note');
      expect(inbox.first.clarifiedAt, isNull);
      expect(inbox.first.captureSource, 'nirvana_import');

      // Its TAGS become Capture tag hints (capture_tags), not todo_tags.
      final hints =
          await db.captureDao.tagHintIdsForCapture(inbox.first.id);
      final workTag = (await db.tagDao.watchByType('context').first)
          .firstWhere((t) => t.name == 'work');
      expect(hints, {workTag.id});
    });

    test('unrecognised state also lands as a Capture, issue #184', () async {
      const csv =
          'TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n'
          'Task,Mystery row,SomeUnknownState,,,,,,,,\n';
      await importNirvanaLocally(
        bytes: _bytes(csv),
        filename: 'test.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );

      expect(
        await (db.select(db.todos)..where((t) => t.userId.equals(_userId)))
            .get(),
        isEmpty,
      );
      final inbox = await db.captureDao.watchInbox().first;
      expect(inbox.map((c) => c.title), ['Mystery row']);
    });

    test('re-importing the same Inbox item is idempotent (issue #184)',
        () async {
      const csv =
          'TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n'
          'Task,Unprocessed idea,Inbox,,,work,,,,,\n';
      Future<void> run() => importNirvanaLocally(
            bytes: _bytes(csv),
            filename: 'test.csv',
            format: 'csv',
            userId: _userId,
            db: db,
          );
      await run();
      await run();

      final captureRows = await db.select(db.captures).get();
      expect(captureRows, hasLength(1));
      final hints =
          await db.captureDao.tagHintIdsForCapture(captureRows.first.id);
      expect(hints, hasLength(1));
    });

    test('re-import preserves a Capture already clarified by the user (#184)',
        () async {
      // Enforce FKs so this test pins the real hazard: with cascade active,
      // an INSERT OR REPLACE upsert (delete-then-insert) would wipe the
      // capture_outcomes provenance link asserted at the bottom. The importer
      // must update the existing row in place instead.
      await db.customStatement('PRAGMA foreign_keys = ON');
      const csv =
          'TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n'
          'Task,Unprocessed idea,Inbox,,,,,,,,\n';
      Future<void> run() => importNirvanaLocally(
            bytes: _bytes(csv),
            filename: 'test.csv',
            format: 'csv',
            userId: _userId,
            db: db,
          );

      await run();
      final capture = (await db.select(db.captures).get()).single;

      // The user clarifies it: stamp + carve an Outcome.
      await db.captureDao.stampClarified(capture.id);
      await db.into(db.todos).insert(TodosCompanion(
            id: const Value('outcome-1'),
            title: const Value('Draft outline'),
            userId: const Value(_userId),
            createdAt: Value(DateTime.now()),
          ));
      await db.captureDao.linkOutcome(capture.id, 'outcome-1', _userId);

      // Re-importing the same export must NOT reset clarification.
      await run();

      final after = (await db.captureDao.getCapture(capture.id))!;
      expect(after.clarifiedAt, isNotNull);
      expect(await db.captureDao.watchInbox().first, isEmpty);
      expect(await db.captureDao.outcomeIdsForCapture(capture.id),
          ['outcome-1']);
    });

    test(
        'CSV Scheduled/Repeating → @repeating context tag linked via todo_tags',
        () async {
      const csv =
          'TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n'
          'Task,Repeating task,Scheduled/Repeating,,,,,,,,\n';
      await importNirvanaLocally(
        bytes: _bytes(csv),
        filename: 'test.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );

      final contextTags = await db.tagDao.watchByType('context').first;
      final names = contextTags.map((t) => t.name).toSet();
      expect(names, contains('@repeating'));

      final repeatingTag =
          contextTags.firstWhere((t) => t.name == '@repeating');
      final junctions = await (db.select(db.todoTags)
            ..where((tt) => tt.tagId.equals(repeatingTag.id)))
          .get();
      expect(junctions.length, 1);
    });

    test('re-import preserves createdAt on an already-imported task (#641)',
        () async {
      final bytes = _fixtureBytes('nirvana_sample.csv');
      Future<void> run() => importNirvanaLocally(
            bytes: bytes,
            filename: 'nirvana_sample.csv',
            format: 'csv',
            userId: _userId,
            db: db,
          );

      await run();
      final before = (await db.select(db.todos).get())
          .firstWhere((t) => t.title == 'Read the Book');

      await run();

      final after = (await db.select(db.todos).get())
          .firstWhere((t) => t.title == 'Read the Book');
      expect(after.createdAt, before.createdAt,
          reason: 'an update in place must not re-stamp created_at');
    });

    test('latin-1 bytes are decoded without error', () async {
      // Build a minimal CSV with a latin-1 encoded character (é = 0xE9)
      final latin1Bytes = Uint8List.fromList([
        ...utf8.encode('TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n'),
        ...utf8.encode('Task,Caf'),
        0xE9, // é in latin-1
        ...utf8.encode(',Next,,,,,,,, \n'),
      ]);

      final result = await importNirvanaLocally(
        bytes: latin1Bytes,
        filename: 'latin1.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );

      // Should not throw; at least 1 task imported
      expect(result.importedCount, greaterThanOrEqualTo(1));
    });
  });

  group('importNirvanaLocally — JSON', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('imports tasks from sample JSON fixture', () async {
      final result = await importNirvanaLocally(
        bytes: _fixtureBytes('nirvana_sample.json'),
        filename: 'nirvana_sample.json',
        format: 'auto',
        userId: _userId,
        db: db,
      );

      expect(result.importedCount, 4); // 4 tasks; project not counted
      expect(result.skippedCount, 2); // cancelled + deleted
      expect(result.projectTagsCreated, 1);
    });

    test('parent-child relationship resolved via parentid', () async {
      await importNirvanaLocally(
        bytes: _fixtureBytes('nirvana_sample.json'),
        filename: 'nirvana_sample.json',
        format: 'json',
        userId: _userId,
        db: db,
      );

      final projectTags =
          await db.tagDao.watchByType('project').first;
      expect(projectTags.length, 1);

      final tagId = projectTags.first.id;
      final tasksByProject = await _todosLinkedToTag(db, tagId);
      expect(tasksByProject.length, 2);
      final names = tasksByProject.map((t) => t.title).toSet();
      expect(names, containsAll(['Read the Book', 'Read our Quick Guide']));
    });

    test('project tags are not re-created on second import', () async {
      final bytes = _fixtureBytes('nirvana_sample.json');

      final first = await importNirvanaLocally(
        bytes: bytes,
        filename: 'nirvana_sample.json',
        format: 'json',
        userId: _userId,
        db: db,
      );
      final second = await importNirvanaLocally(
        bytes: bytes,
        filename: 'nirvana_sample.json',
        format: 'json',
        userId: _userId,
        db: db,
      );

      expect(first.projectTagsCreated, 1);
      expect(second.projectTagsCreated, 0);

      final tags = await db.tagDao.watchByType('project').first;
      expect(tags.length, 1);
    });

    test('JSON state=9 (Repeating) → @repeating context tag linked', () async {
      const json =
          '[{"cancelled":0,"deleted":0,"name":"R","type":0,"state":9}]';
      await importNirvanaLocally(
        bytes: _bytes(json),
        filename: 'test.json',
        format: 'json',
        userId: _userId,
        db: db,
      );
      final contextTags = await db.tagDao.watchByType('context').first;
      final names = contextTags.map((t) => t.name).toSet();
      expect(names, contains('@repeating'));

      final repeatingTag =
          contextTags.firstWhere((t) => t.name == '@repeating');
      final junctions = await (db.select(db.todoTags)
            ..where((tt) => tt.tagId.equals(repeatingTag.id)))
          .get();
      expect(junctions.length, 1);
    });

    test('JSON state=2 with waitingfor → person tag linked', () async {
      const json =
          '[{"cancelled":0,"deleted":0,"name":"W","type":0,"state":2,"waitingfor":"Alice"}]';
      await importNirvanaLocally(
        bytes: _bytes(json),
        filename: 'test.json',
        format: 'json',
        userId: _userId,
        db: db,
      );
      final personTags = await db.tagDao.watchByType('person').first;
      final names = personTags.map((t) => t.name).toSet();
      expect(names, contains('Alice'));
    });

    test('re-import with states 3/6/9/10 is idempotent — no dup tags/junctions',
        () async {
      const json = '['
          '{"cancelled":0,"deleted":0,"name":"S","type":0,"state":3,"id":"S-3"},'
          '{"cancelled":0,"deleted":0,"name":"T","type":0,"state":6,"id":"T-6"},'
          '{"cancelled":0,"deleted":0,"name":"R","type":0,"state":9,"id":"R-9"},'
          '{"cancelled":0,"deleted":0,"name":"X","type":0,"state":10,"id":"X-10"}'
          ']';

      await importNirvanaLocally(
        bytes: _bytes(json),
        filename: 'test.json',
        format: 'json',
        userId: _userId,
        db: db,
      );
      await importNirvanaLocally(
        bytes: _bytes(json),
        filename: 'test.json',
        format: 'json',
        userId: _userId,
        db: db,
      );

      final todos = await (db.select(db.todos)
            ..where((t) => t.userId.equals(_userId)))
          .get();
      expect(todos.length, 4);

      final contextTags = await db.tagDao.watchByType('context').first;
      final names = contextTags.map((t) => t.name).toList();
      // No duplicates: each auto-tag must appear exactly once.
      expect(names.where((n) => n == '@scheduled').length, 1);
      expect(names.where((n) => n == '@repeating').length, 1);
      expect(names.where((n) => n == '@reference').length, 1);

      // No duplicate junction rows for any tag.
      final autoTagIds = {
        for (final t in contextTags)
          if ({'@scheduled', '@repeating', '@reference'}.contains(t.name))
            t.id
      };
      for (final tagId in autoTagIds) {
        final junctions = await (db.select(db.todoTags)
              ..where((tt) => tt.tagId.equals(tagId)))
            .get();
        expect(junctions.length, 1, reason: 'tagId $tagId has duplicates');
      }
    });

    test('invalid JSON throws ParseError wrapped in descriptive message', () async {
      expect(
        () => importNirvanaLocally(
          bytes: _bytes('not json'),
          filename: 'bad.json',
          format: 'json',
          userId: _userId,
          db: db,
        ),
        throwsA(isA<ParseError>()),
      );
    });
  });

  // Issue #641 — a re-import repairs the user's data instead of destroying it.
  // Pre-fix the todos write was INSERT OR REPLACE with a companion that omitted
  // four columns, so every re-import snapped them back to their defaults.
  group('importNirvanaLocally — re-import preserves the user\'s later edits',
      () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    /// A single clarified Next task; its CSV id (and so its todo id) is
    /// derived from the name, so a second run lands on the same row.
    const csv =
        'TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n'
        'Task,Ship the thing,Next,,,,,,,,\n';

    Future<void> runImport(GtdDatabase db) => importNirvanaLocally(
          bytes: _bytes(csv),
          filename: 'test.csv',
          format: 'csv',
          userId: _userId,
          db: db,
        );

    /// Imports once and returns the id of the single resulting todo row.
    Future<String> importOnce(GtdDatabase db) async {
      await runImport(db);
      return (await db.select(db.todos).get()).single.id;
    }

    Future<Todo> reloadTodo(GtdDatabase db, String todoId) =>
        (db.select(db.todos)..where((t) => t.id.equals(todoId))).getSingle();

    test('a locally demoted intent survives a re-import', () async {
      final todoId = await importOnce(db);
      expect((await reloadTodo(db, todoId)).intent, 'next');

      // The user demotes it to Someday/Maybe through the real DAO.
      await db.todoDao.deferTaskToMaybe(todoId);

      await runImport(db);

      expect((await reloadTodo(db, todoId)).intent, 'maybe',
          reason: 're-import must not snap intent back to the default');
    });

    test('a locally set priority survives a re-import', () async {
      final todoId = await importOnce(db);

      await (db.update(db.todos)..where((t) => t.id.equals(todoId)))
          .write(const TodosCompanion(priority: Value(3)));

      await runImport(db);

      expect((await reloadTodo(db, todoId)).priority, 3);
    });

    test('a locally set locationId survives a re-import', () async {
      final todoId = await importOnce(db);

      await (db.update(db.todos)..where((t) => t.id.equals(todoId)))
          .write(const TodosCompanion(locationId: Value('location-1')));

      await runImport(db);

      expect((await reloadTodo(db, todoId)).locationId, 'location-1');
    });

    test('a recorded lastNextActionCompletionAt survives a re-import',
        () async {
      final todoId = await importOnce(db);

      // In production the focus-session review stamps this column; the write
      // itself is what a re-import must not undo.
      final stampedAt = DateTime.utc(2026, 7, 30, 9, 15);
      await (db.update(db.todos)..where((t) => t.id.equals(todoId))).write(
        TodosCompanion(lastNextActionCompletionAt: Value(stampedAt)),
      );

      await runImport(db);

      expect((await reloadTodo(db, todoId)).lastNextActionCompletionAt,
          stampedAt);
    });

    test('a re-import still refreshes the columns the export owns', () async {
      final todoId = await importOnce(db);

      // Local drift on an export-owned column is expected to be overwritten:
      // the export is the source of truth for title, notes and the rest.
      await (db.update(db.todos)..where((t) => t.id.equals(todoId)))
          .write(const TodosCompanion(title: Value('stale title')));

      await runImport(db);

      expect((await reloadTodo(db, todoId)).title, 'Ship the thing');
    });

    test('a fresh import sets intent explicitly, not by column default',
        () async {
      final todoId = await importOnce(db);
      expect((await reloadTodo(db, todoId)).intent, 'next');
    });
  });

  // Issue #610 — every imported entity describes itself on the op-log seam, so
  // an import reaches the user's other devices. Pre-fix the `todos`,
  // `todo_tags` and `captures` writes were raw drift statements inside the
  // capturing scope: rows committed, nothing was authored.
  //
  // A batch is the scope, and therefore the transaction: rollback is
  // batch-scoped, not file-scoped. That is deliberate — see the module doc for
  // why one whole-file scope was a data-loss window rather than a guarantee —
  // and the price is a reachable partial import, which a re-run completes
  // because every id is deterministic.
  group('importNirvanaLocally — every imported entity authors an op', () {
    late RecordingDomainOpCapture capture;
    late GtdDatabase db;

    setUp(() {
      capture = RecordingDomainOpCapture();
      db = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
    });
    tearDown(() => db.close());

    test('a clean import authors exactly one op per imported entity', () async {
      // One of each entity kind the import writes: a project (→ project Tag),
      // a clarified child carrying a context tag and a `waitingfor` delegate,
      // and an Inbox row (state 0 → Capture with a tag hint).
      const json = '['
          '{"cancelled":0,"deleted":0,"name":"Proj","type":1,"id":"p1"},'
          '{"cancelled":0,"deleted":0,"name":"Child","type":0,"state":1,'
          '"id":"c1","parentid":"p1","tags":",computer,","waitingfor":"Alice"},'
          '{"cancelled":0,"deleted":0,"name":"Thought","type":0,"state":0,'
          '"id":"i1","tags":",errand,"}'
          ']';
      await importNirvanaLocally(
        bytes: _bytes(json),
        filename: 'test.json',
        format: 'json',
        userId: _userId,
        db: db,
      );

      final childId = (await db.select(db.todos).getSingle()).id;
      final captureId = (await db.select(db.captures).getSingle()).id;
      final tagIdByName = {
        for (final tag in await db.select(db.tags).get()) tag.name: tag.id,
      };
      expect(tagIdByName.keys,
          unorderedEquals(['Proj', 'computer', 'Alice', 'errand']));

      // Asserted as the exact key set, not as non-emptiness: this is what pins
      // coalescing to one op per entity, so a peer applies one create rather
      // than a stream of partial re-assertions.
      expect(
        capture.keys.toSet(),
        {
          '$todosCollection/$childId',
          '$capturesCollection/$captureId',
          for (final name in ['Proj', 'computer', 'Alice', 'errand'])
            '$tagsCollection/${tagIdByName[name]}',
          for (final name in ['Proj', 'computer', 'Alice'])
            '$todoTagsCollection/${todoTagIdFor(childId, tagIdByName[name]!)}',
          '$captureTagsCollection/'
              '${captureTagIdFor(captureId, tagIdByName['errand']!)}',
        },
      );
      expect(capture.keys, hasLength(capture.keys.toSet().length),
          reason: 'an entity was authored more than once in one import');
    });

    test('the create op asserts the whole row, including an explicit intent',
        () async {
      const json = '[{"cancelled":0,"deleted":0,"name":"Child","type":0,'
          '"state":1,"id":"c1"}]';
      await importNirvanaLocally(
        bytes: _bytes(json),
        filename: 'test.json',
        format: 'json',
        userId: _userId,
        db: db,
      );
      final op = capture.forCollection(todosCollection).single;
      expect(op.tombstone, isFalse);
      expect(op.fields['intent'], 'next',
          reason: 'the next/waiting bucket must be stated, not left implicit');
      expect(op.fields['capture_source'], 'nirvana_import');
      // Exactly the synced columns, so a peer can build the row from this op
      // alone and nothing off-contract slips onto the wire.
      expect(op.fields.keys.toSet(),
          collectionCodecs[todosCollection]!.columns.keys.toSet());
    });

    test('a re-import that clears WAITINGFOR authors a junction tombstone',
        () async {
      const withDelegate = '[{"cancelled":0,"deleted":0,"name":"W","type":0,'
          '"state":2,"id":"w1","waitingfor":"Alice"}]';
      const withoutDelegate = '[{"cancelled":0,"deleted":0,"name":"W","type":0,'
          '"state":2,"id":"w1"}]';

      await importNirvanaLocally(
        bytes: _bytes(withDelegate),
        filename: 'test.json',
        format: 'json',
        userId: _userId,
        db: db,
      );
      final todoId = (await db.select(db.todos).getSingle()).id;
      final aliceId = (await db.select(db.tags).getSingle()).id;
      capture.clear();

      await importNirvanaLocally(
        bytes: _bytes(withoutDelegate),
        filename: 'test.json',
        format: 'json',
        userId: _userId,
        db: db,
      );

      // A removal is a tombstone, never row absence: absence is what would let
      // a replayed assignment silently re-attach the delegate on a peer.
      final removal = capture
          .forCollection(todoTagsCollection)
          .singleWhere((op) => op.entityId == todoTagIdFor(todoId, aliceId));
      expect(removal.tombstone, isTrue);
      expect(await db.select(db.todoTags).get(), isEmpty);
    });

    test('a single-batch failure rolls that batch back and authors no op',
        () async {
      // A second task whose title exceeds the 500-char column limit fails
      // drift's insert-time validation — mid-batch, after the project tag and
      // the first child have already been written. Three items is one batch, so
      // all-or-nothing still holds across this whole file.
      final longName = 'x' * 501;
      final json = '['
          '{"cancelled":0,"deleted":0,"name":"Proj","type":1,"id":"p1"},'
          '{"cancelled":0,"deleted":0,"name":"Child","type":0,"state":1,'
          '"id":"c1","parentid":"p1"},'
          '{"cancelled":0,"deleted":0,"name":"$longName","type":0,"state":1,'
          '"id":"toolong"}'
          ']';

      await expectLater(
        importNirvanaLocally(
          bytes: _bytes(json),
          filename: 'test.json',
          format: 'json',
          userId: _userId,
          db: db,
        ),
        throwsA(isA<InvalidDataException>()),
      );

      // The project tag is a scope of its own and commits ahead of the batch, so
      // it and its op survive — the documented, accepted tags-without-tasks
      // state. The failing batch leaves neither rows nor ops.
      expect(capture.forCollection(tagsCollection), hasLength(1));
      expect(capture.forCollection(todosCollection), isEmpty,
          reason: 'a rolled-back batch must leave no signed Outcome op behind');
      expect(capture.forCollection(todoTagsCollection), isEmpty);
      expect(await db.select(db.todos).get(), isEmpty);
      expect(await db.select(db.todoTags).get(), isEmpty);
      expect(await db.select(db.tags).get(), hasLength(1));
    });
  });

  // Issue #610, the property that replaced whole-file atomicity: an interrupted
  // import is a *partial* import, and re-running the same export completes it.
  group('importNirvanaLocally — interruption and resume', () {
    /// [taskCount] tasks under one project, ids `t0..t{n-1}` so a re-run lands
    /// on the same deterministic rows. More than [nirvanaImportTaskBatchSize] of
    /// them, so the import spans several capturing scopes.
    String exportOf(int taskCount) => '['
        '{"cancelled":0,"deleted":0,"name":"Proj","type":1,"id":"p1"},'
        '${[
              for (var i = 0; i < taskCount; i++)
                '{"cancelled":0,"deleted":0,"name":"Task $i","type":0,'
                    '"state":1,"id":"t$i","parentid":"p1"}'
            ].join(',')}'
        ']';

    /// The Outcome ids a store holds. Deterministic (derived from the Nirvana
    /// item id), which is exactly what makes a resumed import comparable to a
    /// clean one — unlike a Tag id, which is minted fresh per store.
    Future<Set<String>> outcomeIds(GtdDatabase db) async =>
        {for (final row in await db.select(db.todos).get()) row.id};

    const taskCount = 250;

    test('a fault in the second batch keeps the first batch\'s rows and ops',
        () async {
      final faults = FaultInjectingInterceptor();
      final capture = RecordingDomainOpCapture();
      final db = GtdDatabase(
        NativeDatabase.memory().interceptWith(faults),
        opCapture: capture,
      );
      addTearDown(db.close);

      // The 210th Outcome insert is item index 209 — inside batch 2, which runs
      // 200..249. A storage fault rather than a bad row: this models the process
      // dying mid-import, which is the case whole-file atomicity handled worst.
      faults.failNthInsertInto('todos', 210);

      await expectLater(
        importNirvanaLocally(
          bytes: _bytes(exportOf(taskCount)),
          filename: 'test.json',
          format: 'json',
          userId: _userId,
          db: db,
        ),
        throwsA(isA<SqliteException>()),
      );
      expect(faults.firedCount, 1, reason: 'the fault was never reached');

      // Batch 1 committed and authored: 200 Outcomes, 200 project junctions.
      expect(await db.select(db.todos).get(),
          hasLength(nirvanaImportTaskBatchSize));
      expect(capture.forCollection(todosCollection),
          hasLength(nirvanaImportTaskBatchSize));
      expect(capture.forCollection(todoTagsCollection),
          hasLength(nirvanaImportTaskBatchSize));

      // Batch 2 left neither rows nor ops — the two must agree, because a
      // committed row with no op is exactly the invisible-data bug #610 fixes.
      final authoredIds = {
        for (final op in capture.forCollection(todosCollection)) op.entityId,
      };
      final rowIds = {for (final row in await db.select(db.todos).get()) row.id};
      expect(authoredIds, rowIds,
          reason: 'a committed Outcome row has no op, or vice versa');
    });

    test('re-running the same export completes the interrupted import',
        () async {
      final faults = FaultInjectingInterceptor();
      final capture = RecordingDomainOpCapture();
      final db = GtdDatabase(
        NativeDatabase.memory().interceptWith(faults),
        opCapture: capture,
      );
      addTearDown(db.close);
      final bytes = _bytes(exportOf(taskCount));

      Future<void> runImport() => importNirvanaLocally(
            bytes: bytes,
            filename: 'test.json',
            format: 'json',
            userId: _userId,
            db: db,
          );

      faults.failNthInsertInto('todos', 210);
      await expectLater(runImport(), throwsA(isA<SqliteException>()));
      final survivors = {
        for (final row in await db.select(db.todos).get()) row.id: row.createdAt,
      };
      expect(survivors, hasLength(nirvanaImportTaskBatchSize),
          reason: 'the interruption left no partial import to resume');

      // The injector disarms itself, so the re-run is the same export against a
      // store that is now healthy — a resumed import, not a repaired file.
      capture.clear();
      await runImport();

      // What makes this a *resume*: the re-run landed on the surviving rows
      // rather than re-creating them. Their birth timestamps are untouched, and
      // on the log they are field updates — a create would re-assert the whole
      // codec column set under a fresh clock.
      final wholeRow = collectionCodecs[todosCollection]!.columns.keys.toSet();
      final opByEntity = {
        for (final op in capture.forCollection(todosCollection))
          op.entityId: op,
      };
      for (final entry in survivors.entries) {
        final row = await (db.select(db.todos)
              ..where((t) => t.id.equals(entry.key)))
            .getSingle();
        expect(row.createdAt, entry.value,
            reason: 'a surviving Outcome was re-created, not resumed');
        expect(opByEntity[entry.key]!.fields.keys.toSet(), isNot(wholeRow),
            reason: 'a surviving Outcome was re-asserted whole');
      }
      // Everything the interruption dropped came back as a create.
      final resumedIds =
          opByEntity.keys.toSet().difference(survivors.keys.toSet());
      expect(resumedIds, hasLength(taskCount - nirvanaImportTaskBatchSize));
      for (final id in resumedIds) {
        expect(opByEntity[id]!.fields.keys.toSet(), wholeRow,
            reason: 'a resumed Outcome was not asserted whole for a peer');
      }

      // What a clean import of the same export would have produced, in a store
      // that never saw the interruption. Two live databases in one test is the
      // point of the comparison, not a leak.
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final pristine = GtdDatabase(NativeDatabase.memory());
      addTearDown(pristine.close);
      await importNirvanaLocally(
        bytes: bytes,
        filename: 'test.json',
        format: 'json',
        userId: _userId,
        db: pristine,
      );

      expect(await outcomeIds(db), await outcomeIds(pristine),
          reason: 'the resumed store holds a different Outcome set');
      expect(await db.select(db.todos).get(), hasLength(taskCount),
          reason: 'the re-run did not complete the import');
      expect(await db.select(db.tags).get(), hasLength(1),
          reason: 'the re-run duplicated the project tag');
      final pristineJunctionCount =
          (await pristine.select(pristine.todoTags).get()).length;
      expect(await db.select(db.todoTags).get(),
          hasLength(pristineJunctionCount),
          reason: 'the re-run duplicated a project junction');

      // Every row the re-run left behind is described on the log: batch 1's
      // entities as updates, the rest as creates.
      final authoredIds = {
        for (final op in capture.forCollection(todosCollection)) op.entityId,
      };
      expect(authoredIds, await outcomeIds(db),
          reason: 'the re-run left an Outcome row undescribed');
    });
  });
}
