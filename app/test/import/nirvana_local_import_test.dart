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
          await db.tagDao.watchByType(_userId, 'project').first;
      expect(projectTags.length, 1);
      expect(projectTags.first.name, 'Brush up on GTD®');

      final tagId = projectTags.first.id;
      final tasksByProject =
          await db.todoDao.watchByProject(_userId, tagId).first;
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
          await db.tagDao.watchByType(_userId, 'context').first;
      final names = contextTags.map((t) => t.name).toSet();
      expect(names, containsAll(['computer', 'Personal', 'anywhere']));
    });

    test('done tasks are stored with state=done', () async {
      await importNirvanaLocally(
        bytes: _fixtureBytes('nirvana_sample.csv'),
        filename: 'nirvana_sample.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );

      final done =
          await db.todoDao.watchByState(_userId, 'done').first;
      expect(done.length, 2);
    });

    test('next-action tasks are stored with state=next_action', () async {
      await importNirvanaLocally(
        bytes: _fixtureBytes('nirvana_sample.csv'),
        filename: 'nirvana_sample.csv',
        format: 'csv',
        userId: _userId,
        db: db,
      );

      final next =
          await db.todoDao.watchByState(_userId, 'next_action').first;
      expect(next.length, 2);
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

    test('CSV task with scheduled state is persisted as next_action', () async {
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
      expect(all.first.state, 'next_action');
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
          await db.tagDao.watchByType(_userId, 'project').first;
      expect(projectTags.length, 1);

      final tagId = projectTags.first.id;
      final tasksByProject =
          await db.todoDao.watchByProject(_userId, tagId).first;
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

      final tags = await db.tagDao.watchByType(_userId, 'project').first;
      expect(tags.length, 1);
    });

    test('JSON task with state=3 (scheduled) is persisted as next_action', () async {
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
      expect(all.first.state, 'next_action');
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
