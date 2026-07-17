/// Behavior tests for [DaoClarificationService] (issue #184, Phase 0).
///
/// The service is the single write path for the clarification flow; these
/// tests pin its DB effects on the conflated `todos` schema so the Phase 1/2
/// implementation swap (captures + capture_outcomes) has a contract to
/// preserve at the interface level.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show RoutingKind;
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/services/clarification_service.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

const _userId = 'test-user';

TodosCompanion _capture({required String id, required String title}) {
  final now = DateTime.now();
  return TodosCompanion(
    id: Value(id),
    title: Value(title),
    userId: Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  );
}

Future<Todo> _row(GtdDatabase db, String id) =>
    (db.select(db.todos)..where((t) => t.id.equals(id))).getSingle();

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ClarificationService service;

  setUp(() {
    db = _openInMemory();
    service = DaoClarificationService(db);
  });
  tearDown(() => db.close());

  group('DaoClarificationService', () {
    test('exists reflects row presence', () async {
      await db.inboxDao.insertTodo(_capture(id: 'a', title: 'Item'));

      expect(await service.exists('a'), isTrue);
      expect(await service.exists('missing'), isFalse);
    });

    test('clarifyToOutcome to nextAction routes and stamps', () async {
      await db.inboxDao.insertTodo(_capture(id: 'a', title: 'Item'));

      await service.clarifyToOutcome(
        'a',
        to: RoutingKind.nextAction,
        nextActionText: 'Call Alice',
      );

      final row = await _row(db, 'a');
      expect(row.clarified, isTrue);
      expect(row.intent, 'next');
      expect(row.nextActionText, 'Call Alice');
      expect(row.lastClarifiedAt, isNotNull);
      expect(row.doneAt, isNull);
    });

    test('clarifyToOutcome to maybe sets intent without done_at', () async {
      await db.inboxDao.insertTodo(_capture(id: 'a', title: 'Item'));

      await service.clarifyToOutcome('a', to: RoutingKind.maybe);

      final row = await _row(db, 'a');
      expect(row.clarified, isTrue);
      expect(row.intent, 'maybe');
      expect(row.doneAt, isNull);
    });

    test('clarifyToOutcome to done stamps Completion', () async {
      await db.inboxDao.insertTodo(_capture(id: 'a', title: 'Item'));

      await service.clarifyToOutcome('a', to: RoutingKind.done);

      final row = await _row(db, 'a');
      expect(row.clarified, isTrue);
      expect(row.doneAt, isNotNull);
    });

    test('clarifyToOutcome to trash sets intent=trash', () async {
      await db.inboxDao.insertTodo(_capture(id: 'a', title: 'Item'));

      await service.clarifyToOutcome('a', to: RoutingKind.trash);

      final row = await _row(db, 'a');
      expect(row.intent, 'trash');
    });

    test('clarifyToOutcome to waitingFor replaces person tags', () async {
      await db.inboxDao.insertTodo(_capture(id: 'a', title: 'Item'));
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('alice-tag'),
        name: Value('Alice'),
        type: Value('person'),
        userId: Value(_userId),
      ));
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('bob-tag'),
        name: Value('Bob'),
        type: Value('person'),
        userId: Value(_userId),
      ));
      // Pre-existing delegate: the routing below must replace it, not
      // append to it.
      await db.tagDao.assignTag('a', 'bob-tag', _userId);
      expect(await service.getPersonTagIds('a'), {'bob-tag'});

      await service.clarifyToOutcome(
        'a',
        to: RoutingKind.waitingFor,
        personTagIds: {'alice-tag'},
        userId: _userId,
      );

      final row = await _row(db, 'a');
      expect(row.clarified, isTrue);
      expect(row.intent, 'next');
      expect(await service.getPersonTagIds('a'), {'alice-tag'});
    });

    test('promoteCaptureToOutcome flips clarified and guards re-processing',
        () async {
      await db.inboxDao.insertTodo(_capture(id: 'a', title: 'Item'));

      expect(await service.promoteCaptureToOutcome('a'), 1);

      final row = await _row(db, 'a');
      expect(row.clarified, isTrue);
      expect(row.lastClarifiedAt, isNotNull);

      // Already-clarified rows are not double-processed.
      expect(await service.promoteCaptureToOutcome('a'), 0);
    });

    test('promoteCaptureToOutcome passes intent and dueDate through',
        () async {
      await db.inboxDao.insertTodo(_capture(id: 'a', title: 'Item'));
      final due = DateTime.utc(2026, 8, 1);

      await service.promoteCaptureToOutcome('a', intent: 'maybe', dueDate: due);

      final row = await _row(db, 'a');
      expect(row.intent, 'maybe');
      expect(row.dueDate?.toUtc(), due);
    });

    test('completeOutcome stamps done_at and last_clarified_at', () async {
      await db.inboxDao.insertTodo(_capture(id: 'a', title: 'Item'));

      await service.completeOutcome('a');

      final row = await _row(db, 'a');
      expect(row.doneAt, isNotNull);
      expect(row.lastClarifiedAt, isNotNull);
    });

    test('stampClarified touches only the clarification timestamp', () async {
      await db.inboxDao.insertTodo(_capture(id: 'a', title: 'Item'));

      await service.stampClarified('a');

      final row = await _row(db, 'a');
      expect(row.lastClarifiedAt, isNotNull);
      expect(row.clarified, isFalse); // stamp-only: no routing applied
      expect(row.title, 'Item');
    });

    test('updateFields writes edits and honors clear flags', () async {
      await db.inboxDao.insertTodo(_capture(id: 'a', title: 'Item'));

      await service.updateFields(
        'a',
        title: 'Renamed',
        notes: 'Some context',
        energyLevel: 'high',
        timeEstimate: 30,
        dueDate: DateTime.utc(2026, 8, 1),
      );

      var row = await _row(db, 'a');
      expect(row.title, 'Renamed');
      expect(row.notes, 'Some context');
      expect(row.energyLevel, 'high');
      expect(row.timeEstimate, 30);
      expect(row.dueDate, isNotNull);
      // A non-no-op edit is a clarifying micro-act and must stamp.
      expect(row.lastClarifiedAt, isNotNull);

      await service.updateFields(
        'a',
        clearEnergyLevel: true,
        clearTimeEstimate: true,
        clearDueDate: true,
      );

      row = await _row(db, 'a');
      expect(row.energyLevel, isNull);
      expect(row.timeEstimate, isNull);
      expect(row.dueDate, isNull);
    });
  });

  group('clarificationServiceProvider', () {
    test('resolves to the DAO-backed implementation', () {
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      expect(
        container.read(clarificationServiceProvider),
        isA<DaoClarificationService>(),
      );
    });
  });
}
