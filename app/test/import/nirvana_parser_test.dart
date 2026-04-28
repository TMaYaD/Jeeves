import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/import/nirvana_parser.dart';

String _fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();

void main() {
  group('parseCsv', () {
    test('parses sample CSV — correct item counts', () {
      final (items, skipped) = parseCsv(_fixture('nirvana_sample.csv'));
      // 2 done tasks (logbook), 1 project, 2 next-action tasks → 5 items total
      expect(items.length, 5);
      expect(skipped, 0);
    });

    test('CSV tasks are tasks; project is a project', () {
      final (items, _) = parseCsv(_fixture('nirvana_sample.csv'));
      final tasks = items.where((i) => i.type == 'task').toList();
      final projects = items.where((i) => i.type == 'project').toList();
      expect(tasks.length, 4);
      expect(projects.length, 1);
      expect(projects.first.name, 'Brush up on GTD®');
    });

    test('logbook items have doneAt set', () {
      final (items, _) = parseCsv(_fixture('nirvana_sample.csv'));
      final done = items.where((i) => i.doneAt != null).toList();
      expect(done.length, 2);
    });

    test('next state maps to next_action', () {
      final (items, _) = parseCsv(_fixture('nirvana_sample.csv'));
      final next =
          items.where((i) => i.state == 'next_action' && i.doneAt == null).toList();
      expect(next.length, 2);
    });

    test('parent name is populated for child tasks', () {
      final (items, _) = parseCsv(_fixture('nirvana_sample.csv'));
      final withParent = items.where((i) => i.parentName != null).toList();
      expect(withParent.length, 2);
      expect(withParent.every((i) => i.parentName == 'Brush up on GTD®'), isTrue);
    });

    test('Standalone parent is treated as no project', () {
      final (items, _) = parseCsv(_fixture('nirvana_sample.csv'));
      final standalone = items.where((i) => i.parentName == null && i.type == 'task').toList();
      // The 2 logbook tasks have PARENT=Standalone → parentName=null
      expect(standalone.length, 2);
    });

    test('energy level parsed correctly', () {
      final (items, _) = parseCsv(_fixture('nirvana_sample.csv'));
      final withEnergy = items.where((i) => i.energyLevel != null).toList();
      expect(withEnergy.any((i) => i.energyLevel == 'medium'), isTrue);
      expect(withEnergy.any((i) => i.energyLevel == 'low'), isTrue);
    });

    test('time estimate parsed in minutes', () {
      final (items, _) = parseCsv(_fixture('nirvana_sample.csv'));
      final readBook = items.firstWhere((i) => i.name == 'Read the Book');
      expect(readBook.timeEstimate, 240);
    });

    test('tags parsed as list', () {
      final (items, _) = parseCsv(_fixture('nirvana_sample.csv'));
      final computerTask = items.firstWhere(
          (i) => i.name == 'On a computer? click the note →');
      expect(computerTask.tags, contains('computer'));
    });

    test('empty NAME rows are skipped', () {
      const csv = 'TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n'
          'Task,,Next,,,,,,,, \n'
          'Task,Valid task,Next,,,,,,,,\n';
      final (items, skipped) = parseCsv(csv);
      expect(items.length, 1);
      expect(skipped, 1);
    });

    test('unknown TYPE rows are skipped', () {
      const csv = 'TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n'
          'Checklist,Bad row,Next,,,,,,,,\n'
          'Task,Good row,Next,,,,,,,,\n';
      final (items, skipped) = parseCsv(csv);
      expect(items.length, 1);
      expect(skipped, 1);
    });

    test('malformed due dates are tolerated (returns null)', () {
      const csv = 'TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n'
          'Task,X,Next,,,,,,,not-a-date,\n';
      final (items, _) = parseCsv(csv);
      expect(items.first.dueDate, isNull);
    });

    test('well-formed date with single-digit month/day is normalised', () {
      const csv = 'TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n'
          'Task,X,Next,,,,,,,2024-4-3,\n';
      final (items, _) = parseCsv(csv);
      expect(items.first.dueDate, '2024-04-03');
    });

    test('completed task has doneAt set regardless of state column', () {
      const csv = 'TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n'
          'Task,Done task,Next,2024-01-01,,,,,,, \n';
      final (items, _) = parseCsv(csv);
      expect(items.first.state, 'next_action');
      expect(items.first.doneAt, isNotNull);
    });

    test('notes with embedded newlines are parsed correctly', () {
      const csv = 'TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n'
          '"Task","Multi-line note task","Next","","Line1\nLine2",,,,,, \n';
      final (items, _) = parseCsv(csv);
      expect(items.first.notes, contains('Line1'));
      expect(items.first.notes, contains('Line2'));
    });

    test('scheduled state maps to next_action (not raw scheduled)', () {
      const csv = 'TYPE,NAME,STATE,COMPLETED,NOTES,TAGS,TIME,ENERGY,WAITINGFOR,DUEDATE,PARENT\n'
          'Task,Scheduled task,Scheduled,,,,,,,,\n';
      final (items, _) = parseCsv(csv);
      expect(items.first.state, 'next_action');
    });
  });

  group('parseJson', () {
    test('parses sample JSON — correct item counts', () {
      final (items, skipped) = parseJson(_fixture('nirvana_sample.json'));
      // 2 done tasks + 1 project + 2 next-action tasks = 5; 2 skipped (cancelled+deleted)
      expect(items.length, 5);
      expect(skipped, 2);
    });

    test('cancelled and deleted rows are skipped', () {
      final (items, skipped) = parseJson(_fixture('nirvana_sample.json'));
      expect(items.every((i) => !i.name.contains('skipped')), isTrue);
      expect(skipped, 2);
    });

    test('completed items have doneAt set', () {
      final (items, _) = parseJson(_fixture('nirvana_sample.json'));
      final done = items.where((i) => i.doneAt != null).toList();
      expect(done.length, 2);
      expect(done.every((i) => i.state == 'next_action'), isTrue);
    });

    test('state=1 (next_action) is mapped correctly', () {
      final (items, _) = parseJson(_fixture('nirvana_sample.json'));
      final next =
          items.where((i) => i.state == 'next_action' && i.doneAt == null).toList();
      expect(next.length, 2);
    });

    test('project item is type project', () {
      final (items, _) = parseJson(_fixture('nirvana_sample.json'));
      final projects = items.where((i) => i.type == 'project').toList();
      expect(projects.length, 1);
      expect(projects.first.name, 'Brush up on GTD®');
    });

    test('parentid is populated for child tasks', () {
      final (items, _) = parseJson(_fixture('nirvana_sample.json'));
      const projectId = '540503BC-6CBA-4104-9FA7-6AD4414C6724';
      final children = items
          .where((i) => i.parentId == projectId)
          .toList();
      expect(children.length, 2);
    });

    test('energy level decoded from numeric code', () {
      final (items, _) = parseJson(_fixture('nirvana_sample.json'));
      final readBook = items.firstWhere((i) => i.name == 'Read the Book');
      expect(readBook.energyLevel, 'medium'); // energy=2
    });

    test('etime is mapped to timeEstimate in minutes', () {
      final (items, _) = parseJson(_fixture('nirvana_sample.json'));
      final readBook = items.firstWhere((i) => i.name == 'Read the Book');
      expect(readBook.timeEstimate, 240);
    });

    test('tags with leading/trailing commas are stripped', () {
      final (items, _) = parseJson(_fixture('nirvana_sample.json'));
      final computerTask = items.firstWhere(
          (i) => i.name == 'On a computer? click the note →');
      expect(computerTask.tags, contains('computer'));
      expect(computerTask.tags, isNot(contains('')));
    });

    test('empty name rows are skipped', () {
      const json = '[{"cancelled":0,"deleted":0,"name":"","type":0,"state":0}]';
      final (items, skipped) = parseJson(json);
      expect(items, isEmpty);
      expect(skipped, 1);
    });

    test('invalid JSON throws ParseError', () {
      expect(() => parseJson('not json at all'), throwsA(isA<ParseError>()));
    });

    test('non-list JSON root throws ParseError', () {
      expect(() => parseJson('{}'), throwsA(isA<ParseError>()));
    });

    test('state=3 (Nirvana scheduled) maps to next_action (not raw scheduled)', () {
      const json = '[{"cancelled":0,"deleted":0,"name":"Scheduled task","type":0,"state":3}]';
      final (items, _) = parseJson(json);
      expect(items.first.state, 'next_action');
    });
  });

  group('detectFormat', () {
    test('detects JSON by filename extension', () {
      expect(detectFormat('export.json', ''), 'json');
    });

    test('detects CSV by filename extension', () {
      expect(detectFormat('export.csv', ''), 'csv');
    });

    test('sniffs JSON by leading bracket', () {
      expect(detectFormat('file.dat', '[ {"x":1} ]'), 'json');
    });

    test('defaults to CSV when unsure', () {
      expect(detectFormat('file.dat', 'TYPE,NAME'), 'csv');
    });
  });
}
