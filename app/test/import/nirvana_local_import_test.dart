import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/import/nirvana_local_import.dart';
import 'package:jeeves/import/nirvana_parser.dart' show ParseError;

import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

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
      final tasksByProject =
          await db.todoDao.watchByProject(tagId).first;
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

    test('CSV task with scheduled state is imported successfully', () async {
      const csv = 'TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n'
          'Task,Scheduled task,Scheduled,,,,,,,,\n';
      await importNirvanaLocally(
        bytes: _bytes(csv),
        filename: 'test.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );

      final all = await (db.select(db.todos)
            ..where((t) => t.userId.equals(_userId)))
          .get();
      expect(all.length, 1);
    });

    test('CSV Inactive/Later → clarified=true, intent=maybe', () async {
      const csv =
          'TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n'
          'Task,Inactive task,Inactive/Later,,,,,,,,\n';
      await importNirvanaLocally(
        bytes: _bytes(csv),
        filename: 'test.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );

      final all = await (db.select(db.todos)
            ..where((t) => t.userId.equals(_userId)))
          .get();
      expect(all.length, 1);
      expect(all.first.clarified, isTrue);
      expect(all.first.intent, 'maybe');
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

    test('CSV Trash → clarified=true, intent=trash', () async {
      const csv =
          'TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n'
          'Task,Trash task,Trash,,,,,,,,\n';
      await importNirvanaLocally(
        bytes: _bytes(csv),
        filename: 'test.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );

      final all = await (db.select(db.todos)
            ..where((t) => t.userId.equals(_userId)))
          .get();
      expect(all.length, 1);
      expect(all.first.clarified, isTrue);
      expect(all.first.intent, 'trash');
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
      final tasksByProject =
          await db.todoDao.watchByProject(tagId).first;
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

    test('JSON task with state=3 (scheduled) is imported successfully', () async {
      const json = '[{"cancelled":0,"deleted":0,"name":"Scheduled task","type":0,"state":3}]';
      await importNirvanaLocally(
        bytes: _bytes(json),
        filename: 'test.json',
        format: 'json',
        userId: _userId,
        db: db,
      );

      final all = await (db.select(db.todos)
            ..where((t) => t.userId.equals(_userId)))
          .get();
      expect(all.length, 1);
    });

    test('JSON state=4 (Someday) → clarified=true, intent=maybe', () async {
      const json =
          '[{"cancelled":0,"deleted":0,"name":"S","type":0,"state":4}]';
      await importNirvanaLocally(
        bytes: _bytes(json),
        filename: 'test.json',
        format: 'json',
        userId: _userId,
        db: db,
      );
      final all = await (db.select(db.todos)
            ..where((t) => t.userId.equals(_userId)))
          .get();
      expect(all.length, 1);
      expect(all.first.clarified, isTrue);
      expect(all.first.intent, 'maybe');
    });

    test('JSON state=6 (Trash) → clarified=true, intent=trash', () async {
      const json =
          '[{"cancelled":0,"deleted":0,"name":"T","type":0,"state":6}]';
      await importNirvanaLocally(
        bytes: _bytes(json),
        filename: 'test.json',
        format: 'json',
        userId: _userId,
        db: db,
      );
      final all = await (db.select(db.todos)
            ..where((t) => t.userId.equals(_userId)))
          .get();
      expect(all.length, 1);
      expect(all.first.clarified, isTrue);
      expect(all.first.intent, 'trash');
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
}
