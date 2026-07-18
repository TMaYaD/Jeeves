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

CapturesCompanion _captureRow({required String id, required String title}) {
  final now = DateTime.now();
  return CapturesCompanion(
    id: Value(id),
    title: Value(title),
    captureSource: const Value('manual'),
    userId: Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  );
}

Future<Todo> _row(GtdDatabase db, String id) =>
    (db.select(db.todos)..where((t) => t.id.equals(id))).getSingle();

Future<Todo?> _rowOrNull(GtdDatabase db, String id) =>
    (db.select(db.todos)..where((t) => t.id.equals(id))).getSingleOrNull();

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

  group('clarifyCaptureToOutcome (Capture → new Outcome)', () {
    test('creates a routed Outcome, links it, and stamps the Capture',
        () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Draft'));

      final outcomeId = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Draft outline',
        nextActionText: 'Draft outline',
      );

      // A distinct Outcome row exists — the Capture is not flipped in place.
      final outcome = await _row(db, outcomeId);
      expect(outcome.id, isNot('c1'));
      expect(outcome.title, 'Draft outline');
      expect(outcome.clarified, isTrue);
      expect(outcome.intent, 'next');
      expect(outcome.nextActionText, 'Draft outline');
      expect(outcome.lastClarifiedAt, isNotNull);

      // Provenance link + Capture stamped out of the Inbox.
      expect(await db.captureDao.outcomeIdsForCapture('c1'), [outcomeId]);
      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNotNull);
      expect(await db.captureDao.watchInbox().first, isEmpty);
      // The raw fragment persists as provenance, unmutated.
      expect((await db.captureDao.getCapture('c1'))!.title, 'Draft');
    });

    test('carries draft fields and tag ids onto the Outcome', () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Idea'));
      final work = await db.tagDao.findOrCreateTag('work', 'context', _userId);

      final outcomeId = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Renamed',
        notes: 'Context',
        energyLevel: 'high',
        timeEstimate: 30,
        dueDate: DateTime.utc(2026, 8, 1),
        tagIds: {work},
      );

      final outcome = await _row(db, outcomeId);
      expect(outcome.notes, 'Context');
      expect(outcome.energyLevel, 'high');
      expect(outcome.timeEstimate, 30);
      expect(outcome.dueDate?.toUtc(), DateTime.utc(2026, 8, 1));
      final tagRows = await (db.select(db.todoTags)
            ..where((tt) => tt.todoId.equals(outcomeId)))
          .get();
      expect(tagRows.map((r) => r.tagId), [work]);
    });

    test('waitingFor attaches the delegate person tag', () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Ask Bob'));
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('bob-tag'),
        name: Value('Bob'),
        type: Value('person'),
        userId: Value(_userId),
      ));

      final outcomeId = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.waitingFor,
        userId: _userId,
        title: 'Ask Bob to review',
        personTagIds: {'bob-tag'},
      );

      expect(await db.todoDao.getPersonTagIdsForTodo(outcomeId), {'bob-tag'});
      expect((await _row(db, outcomeId)).intent, 'next');
    });

    test('done routing stamps Completion on the new Outcome', () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Quick'));

      final outcomeId = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.done,
        userId: _userId,
        title: 'Quick win',
      );

      expect((await _row(db, outcomeId)).doneAt, isNotNull);
    });

    test('normalises an injected non-UTC timestamp to UTC on the Outcome',
        () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Item'));
      // A local (non-UTC) wall-clock time — the clarify card supplies one.
      final localNow = DateTime(2026, 8, 1, 9, 30);
      expect(localNow.isUtc, isFalse);

      final outcomeId = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Item',
        now: localNow,
      );

      final outcome = await _row(db, outcomeId);
      // Every timestamp column must land in UTC (PowerSync upload contract),
      // not just last_clarified_at.
      expect(outcome.createdAt.isUtc, isTrue);
      expect(outcome.createdAt, localNow.toUtc());
      expect(outcome.updatedAt!.isUtc, isTrue);
      expect(outcome.updatedAt, localNow.toUtc());
      expect(outcome.lastClarifiedAt!.isUtc, isTrue);
    });

    test('throws and creates nothing when the Capture is gone', () async {
      // No Capture 'missing' exists.
      await expectLater(
        service.clarifyCaptureToOutcome(
          'missing',
          to: RoutingKind.nextAction,
          userId: _userId,
          title: 'Orphan',
          outcomeId: 'o-orphan',
        ),
        throwsA(isA<StateError>()),
      );
      // The transaction rolled back — no orphan Outcome or link persisted.
      expect(await _rowOrNull(db, 'o-orphan'), isNull);
      expect(await db.select(db.todos).get(), isEmpty);
      expect(await db.select(db.captureOutcomes).get(), isEmpty);
    });

    test('re-route overwrites the session Outcome (Ceremony Back → re-tap)',
        () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Item'));

      final first = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Item',
      );
      final second = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.maybe,
        userId: _userId,
        title: 'Item',
      );

      // The first Outcome is gone; exactly one link remains, to the second.
      expect(await _rowOrNull(db, first), isNull);
      expect(first, isNot(second));
      expect(await db.captureDao.outcomeIdsForCapture('c1'), [second]);
      expect((await _row(db, second)).intent, 'maybe');
    });

    test('re-route keeps an Outcome another Capture still claims (merge)',
        () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'One'));
      await db.captureDao.insertCapture(_captureRow(id: 'c2', title: 'Two'));

      final shared = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Shared work',
      );
      // A second Capture merges into the same Outcome (many-to-many).
      await db.captureDao.linkOutcome('c2', shared, _userId);

      // Re-routing c1 must retract only c1's claim, never delete the shared row.
      final fresh = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.maybe,
        userId: _userId,
        title: 'Shared work',
      );

      expect(fresh, isNot(shared));
      expect(await _rowOrNull(db, shared), isNotNull,
          reason: 'c2 still claims it — must survive');
      expect(await db.captureDao.captureIdsForOutcome(shared), ['c2']);
      expect(await db.captureDao.outcomeIdsForCapture('c1'), [fresh]);
    });
  });

  group('discardCapture (zero-Outcome clarification)', () {
    test('stamps the Capture and creates nothing', () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Noise'));

      await service.discardCapture('c1');

      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNotNull);
      expect(await db.captureDao.watchInbox().first, isEmpty);
      expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
      // No Outcome fabricated on the todos table.
      final todoCount = await db.select(db.todos).get();
      expect(todoCount, isEmpty);
    });

    test('throws when the Capture is gone', () async {
      await expectLater(
        service.discardCapture('missing'),
        throwsA(isA<StateError>()),
      );
    });

    test('drops a session Outcome carved before the discard', () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Item'));
      final outcomeId = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Item',
      );

      await service.discardCapture('c1');

      expect(await _rowOrNull(db, outcomeId), isNull);
      expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNotNull);
    });

    test('keeps an Outcome another Capture still claims (merge)', () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'One'));
      await db.captureDao.insertCapture(_captureRow(id: 'c2', title: 'Two'));
      final shared = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Shared work',
      );
      await db.captureDao.linkOutcome('c2', shared, _userId);

      await service.discardCapture('c1');

      expect(await _rowOrNull(db, shared), isNotNull,
          reason: 'c2 still claims it — discard must only unlink');
      expect(await db.captureDao.captureIdsForOutcome(shared), ['c2']);
      expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNotNull);
    });
  });

  group('captureExists', () {
    test('reflects Capture presence', () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Item'));
      expect(await service.captureExists('c1'), isTrue);
      expect(await service.captureExists('missing'), isFalse);
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
