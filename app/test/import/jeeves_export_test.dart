import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/import/jeeves_export.dart';
import 'package:jeeves/import/nirvana_local_import.dart';
import 'package:jeeves/sync/domain_op_capture.dart'
    show NoopDomainOpCapture, RecordingDomainOpCapture;

import '../test_helpers.dart';

const _userId = 'alice';

GtdDatabase _openInMemory({RecordingDomainOpCapture? recorder}) => GtdDatabase(
      NativeDatabase.memory(),
      opCapture: recorder ?? const NoopDomainOpCapture(),
    );

/// Whole-second UTC instant, so the value survives whichever datetime storage
/// mode the store uses without a truncation surprise in the assertions.
DateTime _utc(int day, int hour, int minute, int second) =>
    DateTime.utc(2026, 7, day, hour, minute, second);

/// Seeds one representative row in every exported collection, exercising
/// instants, TEXT timestamps, nulls, booleans, and every junction. A
/// `user_preferences` row is seeded too — it must NOT appear in an export.
Future<void> _seed(GtdDatabase db, {String userId = _userId}) async {
  // --- tags: one of every discriminator ---
  await db.into(db.tags).insert(TagsCompanion(
      id: const Value('tag-label'),
      name: const Value('urgent-this-week'),
      color: const Value('#ff0000'),
      type: const Value('label'),
      userId: Value(userId)));
  await db.into(db.tags).insert(TagsCompanion(
      id: const Value('tag-area'),
      name: const Value('Health'),
      type: const Value('area'),
      userId: Value(userId)));
  await db.into(db.tags).insert(TagsCompanion(
      id: const Value('tag-project'),
      name: const Value('Quarterly plan'),
      type: const Value('project'),
      userId: Value(userId)));
  await db.into(db.tags).insert(TagsCompanion(
      id: const Value('tag-person'),
      name: const Value('Trixy'),
      type: const Value('person'),
      userId: Value(userId)));

  // --- todos: a next Outcome with instants, and a done maybe Outcome ---
  await db.into(db.todos).insert(TodosCompanion(
      id: const Value('todo-next'),
      title: const Value('Draft the hiring plan'),
      notes: const Value('Two paragraphs, no more'),
      priority: const Value(2),
      dueDate: Value(_utc(30, 9, 0, 0)),
      createdAt: Value(_utc(28, 5, 12, 3)),
      updatedAt: Value(_utc(28, 6, 0, 0)),
      clarified: const Value(true),
      intent: const Value('next'),
      timeEstimate: const Value(30),
      energyLevel: const Value('medium'),
      captureSource: const Value('manual'),
      userId: Value(userId),
      lastClarifiedAt: Value(_utc(28, 6, 0, 0))));
  await db.into(db.todos).insert(TodosCompanion(
      id: const Value('todo-done'),
      title: const Value('Renew passport'),
      notes: const Value.absent(),
      createdAt: Value(_utc(20, 8, 0, 0)),
      doneAt: const Value('2026-07-27T10:00:00.000Z'),
      clarified: const Value(true),
      intent: const Value('maybe'),
      userId: Value(userId)));

  // --- captures: an Inbox one (unclarified) and a clarified one ---
  await db.into(db.captures).insert(CapturesCompanion(
      id: const Value('cap-inbox'),
      title: const Value('random thought'),
      captureSource: const Value('voice'),
      createdAt: Value(_utc(28, 7, 0, 0)),
      userId: Value(userId)));
  await db.into(db.captures).insert(CapturesCompanion(
      id: const Value('cap-clarified'),
      title: const Value('call the dentist'),
      createdAt: Value(_utc(26, 7, 0, 0)),
      clarifiedAt: Value(_utc(27, 9, 0, 0)),
      userId: Value(userId)));

  // --- actions: a current and a planned, on the next Outcome ---
  await db.into(db.actions).insert(ActionsCompanion(
      id: const Value('act-current'),
      outcomeId: const Value('todo-next'),
      userId: Value(userId),
      actionText: const Value('write the intro'),
      role: const Value('current'),
      energyLevel: const Value('low'),
      timeEstimate: const Value(15),
      createdAt: Value(_utc(28, 5, 30, 0))));
  await db.into(db.actions).insert(ActionsCompanion(
      id: const Value('act-planned'),
      outcomeId: const Value('todo-next'),
      userId: Value(userId),
      actionText: const Value('circulate for review'),
      role: const Value('planned'),
      position: const Value(0),
      createdAt: Value(_utc(28, 5, 31, 0))));

  // --- focus session (open), a time log, and the plan/disposition junctions ---
  await db.into(db.focusSessions).insert(FocusSessionsCompanion(
      id: const Value('fs-1'),
      userId: Value(userId),
      startedAt: const Value('2026-07-28T08:00:00.000Z'),
      currentTaskId: const Value('todo-next')));
  await db.into(db.timeLogs).insert(TimeLogsCompanion(
      id: const Value('tl-1'),
      userId: Value(userId),
      taskId: const Value('todo-next'),
      actionId: const Value('act-current'),
      startedAt: const Value('2026-07-28T08:05:00.000Z'),
      endedAt: const Value('2026-07-28T08:30:00.000Z'),
      focusSessionId: const Value('fs-1')));

  // --- junctions ---
  await db.into(db.todoTags).insert(TodoTagsCompanion(
      id: const Value('tt-1'),
      todoId: const Value('todo-next'),
      tagId: const Value('tag-project'),
      userId: Value(userId)));
  await db.into(db.captureOutcomes).insert(CaptureOutcomesCompanion(
      id: const Value('co-1'),
      captureId: const Value('cap-clarified'),
      outcomeId: const Value('todo-done'),
      createdAt: Value(_utc(27, 9, 0, 0)),
      userId: Value(userId)));
  await db.into(db.captureTags).insert(CaptureTagsCompanion(
      id: const Value('ct-1'),
      captureId: const Value('cap-inbox'),
      tagId: const Value('tag-label'),
      userId: Value(userId)));
  await db.into(db.focusSessionTasks).insert(FocusSessionTasksCompanion(
      id: const Value('fst-1'),
      focusSessionId: const Value('fs-1'),
      taskId: const Value('todo-next'),
      position: const Value(0),
      disposition: const Value('rollover'),
      userId: Value(userId)));
  await db.into(db.focusSessionDispositions).insert(
      FocusSessionDispositionsCompanion(
          id: const Value('fsd-1'),
          focusSessionId: const Value('fs-1'),
          taskId: const Value('todo-done'),
          disposition: const Value('maybe'),
          userId: Value(userId)));

  // --- a preference: MUST be excluded from the export ---
  await db.into(db.userPreferences).insert(UserPreferencesCompanion(
      id: const Value('pref-1'),
      userId: Value(userId),
      key: const Value('clarify_mode'),
      value: const Value('"nToM"'),
      updatedAt: const Value('2026-07-28T00:00:00.000Z')));
}

void main() {
  setUpAll(() {
    configureSqliteForTests();
    // Each case opens a source and a restored store; separate in-memory
    // executors make the shared-executor race the warning guards against
    // impossible here.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  group('detection', () {
    test('recognises a Jeeves export and rejects Nirvana / CSV', () async {
      final db = _openInMemory();
      addTearDown(db.close);
      await _seed(db);
      final json =
          encodeJeevesExportJson(await buildJeevesExport(db: db, userId: _userId));

      expect(isJeevesExport(json), isTrue);
      // Nirvana JSON is a bare list; CSV is not JSON at all.
      expect(isJeevesExport('[{"name":"x","type":0,"state":1}]'), isFalse);
      expect(isJeevesExport('NAME,TYPE,STATE\nBuy milk,task,next'), isFalse);
      expect(isJeevesExport('not json'), isFalse);
    });
  });

  group('export contents', () {
    test('carries GTD collections but never user_preferences', () async {
      final db = _openInMemory();
      addTearDown(db.close);
      await _seed(db);

      final doc = await buildJeevesExport(db: db, userId: _userId);
      final collections = doc[jeevesExportCollectionsKey] as Map;

      expect(doc[jeevesExportEnvelopeKey], jeevesExportVersion);
      for (final name in jeevesExportCollections) {
        expect(collections.containsKey(name), isTrue, reason: 'missing $name');
      }
      expect(collections.containsKey('user_preferences'), isFalse);
      // Instants are the canonical three-fraction-digit Z spelling.
      final todoNext = (collections['todos'] as List)
          .cast<Map>()
          .firstWhere((r) => r['id'] == 'todo-next');
      expect(todoNext['due_date'], '2026-07-30T09:00:00.000Z');
      expect(todoNext['clarified'], true);
      // A TEXT timestamp passes through untouched.
      final todoDone = (collections['todos'] as List)
          .cast<Map>()
          .firstWhere((r) => r['id'] == 'todo-done');
      expect(todoDone['done_at'], '2026-07-27T10:00:00.000Z');
      expect(todoDone['notes'], isNull);
    });

    test('only the requested user\'s rows travel', () async {
      final db = _openInMemory();
      addTearDown(db.close);
      await _seed(db, userId: 'alice');
      // A second user's tag in the same store, with a distinct id.
      await db.into(db.tags).insert(TagsCompanion(
          id: const Value('tag-bob'),
          name: const Value('Bob only'),
          type: const Value('label'),
          userId: const Value('bob')));

      final doc = await buildJeevesExport(db: db, userId: 'alice');
      final tags = (doc[jeevesExportCollectionsKey] as Map)['tags'] as List;
      // Alice seeded four tags; Bob's must not be here.
      expect(tags.length, 4);
      expect(tags.cast<Map>().any((t) => t['id'] == 'tag-bob'), isFalse);
    });
  });

  group('round-trip', () {
    test('export → import → export is byte-identical', () async {
      final source = _openInMemory();
      addTearDown(source.close);
      await _seed(source);
      final doc1 = await buildJeevesExport(db: source, userId: _userId);
      final json1 = encodeJeevesExportJson(doc1);

      final restored = _openInMemory();
      addTearDown(restored.close);
      await importJeevesExport(content: json1, userId: _userId, db: restored);

      final doc2 = await buildJeevesExport(db: restored, userId: _userId);
      // Deep equality over the whole document proves every field of every
      // collection round-tripped without loss or reinterpretation.
      expect(json1, encodeJeevesExportJson(doc2));
    });

    test('restores actual rows into an empty store', () async {
      final source = _openInMemory();
      addTearDown(source.close);
      await _seed(source);
      final json =
          encodeJeevesExportJson(await buildJeevesExport(db: source, userId: _userId));

      final restored = _openInMemory();
      addTearDown(restored.close);
      final result =
          await importJeevesExport(content: json, userId: _userId, db: restored);

      expect(result.importedCount, 2); // two Outcomes
      expect(await restored.select(restored.todos).get(), hasLength(2));
      expect(await restored.select(restored.actions).get(), hasLength(2));
      expect(await restored.select(restored.captures).get(), hasLength(2));
      expect(await restored.select(restored.tags).get(), hasLength(4));
      expect(await restored.select(restored.timeLogs).get(), hasLength(1));
      expect(await restored.select(restored.focusSessions).get(), hasLength(1));
      expect(await restored.select(restored.todoTags).get(), hasLength(1));
      expect(
          await restored.select(restored.focusSessionTasks).get(), hasLength(1));
      // A preference is never carried, so none is created.
      expect(await restored.select(restored.userPreferences).get(), isEmpty);
    });

    test('re-importing the same export creates no duplicates', () async {
      final source = _openInMemory();
      addTearDown(source.close);
      await _seed(source);
      final json =
          encodeJeevesExportJson(await buildJeevesExport(db: source, userId: _userId));

      final restored = _openInMemory();
      addTearDown(restored.close);
      await importJeevesExport(content: json, userId: _userId, db: restored);
      await importJeevesExport(content: json, userId: _userId, db: restored);

      expect(await restored.select(restored.todos).get(), hasLength(2));
      expect(await restored.select(restored.todoTags).get(), hasLength(1));
      expect(await restored.select(restored.tags).get(), hasLength(4));
    });

    test('the importing account owns every imported row', () async {
      final source = _openInMemory();
      addTearDown(source.close);
      await _seed(source, userId: 'alice');
      final json =
          encodeJeevesExportJson(await buildJeevesExport(db: source, userId: 'alice'));

      final restored = _openInMemory();
      addTearDown(restored.close);
      await importJeevesExport(content: json, userId: 'bob', db: restored);

      final todos = await restored.select(restored.todos).get();
      expect(todos.map((t) => t.userId).toSet(), {'bob'});
      final links = await restored.select(restored.todoTags).get();
      expect(links.map((l) => l.userId).toSet(), {'bob'});
    });
  });

  group('silent dispatch through the Nirvana entry point', () {
    test('a Jeeves export imported via importNirvanaLocally lands', () async {
      final source = _openInMemory();
      addTearDown(source.close);
      await _seed(source);
      final json =
          encodeJeevesExportJson(await buildJeevesExport(db: source, userId: _userId));

      final restored = _openInMemory();
      addTearDown(restored.close);
      // 'backup.json' — a JSON filename, so Nirvana auto-detection would try the
      // list parser and fail; success proves the envelope sniff routed it to the
      // Jeeves importer instead.
      final result = await importNirvanaLocally(
        bytes: Uint8List.fromList(utf8.encode(json)),
        filename: 'backup.json',
        format: 'auto',
        userId: _userId,
        db: restored,
      );

      expect(result.importedCount, 2);
      expect(await restored.select(restored.todos).get(), hasLength(2));
    });
  });

  group('sync', () {
    test('every imported row authors an op so it reaches other devices',
        () async {
      final source = _openInMemory();
      addTearDown(source.close);
      await _seed(source);
      final json =
          encodeJeevesExportJson(await buildJeevesExport(db: source, userId: _userId));

      final recorder = RecordingDomainOpCapture();
      final restored = _openInMemory(recorder: recorder);
      addTearDown(restored.close);
      await importJeevesExport(content: json, userId: _userId, db: restored);

      final authored = recorder.keys.toSet();
      // At least one op per collection the export carried.
      for (final collection in jeevesExportCollections) {
        expect(
          authored.any((k) => k.startsWith('$collection/')),
          isTrue,
          reason: 'no op authored for $collection',
        );
      }
      // The preference collection authored nothing — it was never exported.
      expect(authored.any((k) => k.startsWith('user_preferences/')), isFalse);
    });
  });
}
