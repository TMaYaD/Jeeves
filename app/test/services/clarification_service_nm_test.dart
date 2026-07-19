/// Behaviour tests for the n-m clarify write path (issue #434).
///
/// The n-m mode's whole point is that a Capture accumulates Outcomes while
/// staying in the Inbox, and only the user's explicit verdict ends the clarify
/// act. That is what separates [ClarificationService.carveOutcome] /
/// [ClarificationService.mergeIntoOutcome] from the 1-1 mode's
/// `clarifyCaptureToOutcome`, which creates-links-stamps in one shot and
/// overwrites any earlier carve. These tests pin the difference against a real
/// Drift database — no fakes, so what is asserted is what production writes.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show RoutingKind;
import 'package:jeeves/services/clarification_service.dart';

import '../test_helpers.dart';

const _userId = 'test-user';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<void> _insertCapture(
  GtdDatabase db, {
  required String id,
  String title = 'Raw fragment',
}) async {
  final now = DateTime.now();
  await db.captureDao.insertCapture(CapturesCompanion(
    id: Value(id),
    title: Value(title),
    captureSource: const Value('manual'),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
}

Future<DateTime?> _clarifiedAt(GtdDatabase db, String captureId) async =>
    (await db.captureDao.getCapture(captureId))?.clarifiedAt;

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ClarificationService service;

  setUp(() {
    db = _openInMemory();
    service = DaoClarificationService(db);
  });

  tearDown(() => db.close());

  group('carveOutcome', () {
    test('creates and links an Outcome without stamping clarified_at', () async {
      await _insertCapture(db, id: 'c1');

      final outcomeId = await service.carveOutcome(
        'c1',
        userId: _userId,
        title: 'Book the flights',
      );

      final outcome = await db.todoDao.getTodo(outcomeId);
      expect(outcome, isNotNull);
      expect(outcome!.title, 'Book the flights');
      expect(
        await db.captureDao.outcomeIdsForCapture('c1'),
        [outcomeId],
      );
      // The Capture is still in the Inbox — this is the whole difference from
      // 1-1 mode's create-link-stamp.
      expect(await _clarifiedAt(db, 'c1'), isNull);
    });

    test('accumulates rather than overwriting, unlike clarifyCaptureToOutcome',
        () async {
      await _insertCapture(db, id: 'c1');

      final first =
          await service.carveOutcome('c1', userId: _userId, title: 'First');
      final second =
          await service.carveOutcome('c1', userId: _userId, title: 'Second');

      expect(
        (await db.captureDao.outcomeIdsForCapture('c1')).toSet(),
        {first, second},
      );
      // Both survive: a split is several Outcomes out of one Capture.
      expect(await db.todoDao.getTodo(first), isNotNull);
      expect(await db.todoDao.getTodo(second), isNotNull);
    });

    test('attaches the tag hints it is given', () async {
      await _insertCapture(db, id: 'c1');
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('t1'),
        name: const Value('home'),
        type: const Value('context'),
        userId: const Value(_userId),
      ));

      final outcomeId = await service.carveOutcome(
        'c1',
        userId: _userId,
        title: 'Tidy the shed',
        tagIds: {'t1'},
      );

      final rows = await (db.select(db.todoTags)
            ..where((t) => t.todoId.equals(outcomeId)))
          .get();
      expect([for (final r in rows) r.tagId], ['t1']);
    });

    test('refuses to mint an Outcome for a Capture that has vanished',
        () async {
      expect(
        () => service.carveOutcome('gone', userId: _userId, title: 'Orphan'),
        throwsA(isA<StateError>()),
      );
    });

    // The n-m New Outcome form collects the same attributes the 1-1 card does
    // (CONTEXT.md § GTD Core: they are Outcome attributes, with no column on a
    // Capture to hold them). Carving must therefore write all of them, not just
    // the title — otherwise the user fills in a form whose fields silently
    // evaporate.
    test('persists the whole clarify draft onto the carved Outcome', () async {
      await _insertCapture(db, id: 'c1');
      final due = DateTime(2026, 8, 1);

      final outcomeId = await service.carveOutcome(
        'c1',
        userId: _userId,
        title: 'Book the flights',
        notes: 'Aim for a morning departure',
        energyLevel: 'high',
        timeEstimate: 45,
        dueDate: due,
      );

      final outcome = await db.todoDao.getTodo(outcomeId);
      expect(outcome!.notes, 'Aim for a morning departure');
      expect(outcome.energyLevel, 'high');
      expect(outcome.timeEstimate, 45);
      expect(outcome.dueDate!.toLocal(), due);
    });

    test('applies the routing destination the New Outcome form chose', () async {
      await _insertCapture(db, id: 'c1');

      final outcomeId = await service.carveOutcome(
        'c1',
        userId: _userId,
        title: 'Book the flights',
        to: RoutingKind.maybe,
      );

      final outcome = await db.todoDao.getTodo(outcomeId);
      expect(outcome!.intent, 'maybe');
      // Routing the form's Outcome is not the Capture's verdict: the Capture
      // stays in the Inbox until the user says it is done with.
      expect(await _clarifiedAt(db, 'c1'), isNull);
    });

    test('records the next action when the carve routes to Next', () async {
      await _insertCapture(db, id: 'c1');

      final outcomeId = await service.carveOutcome(
        'c1',
        userId: _userId,
        title: 'Book the flights',
        to: RoutingKind.nextAction,
        nextActionText: 'Compare fares',
      );

      final outcome = await db.todoDao.getTodo(outcomeId);
      expect(outcome!.intent, 'next');
      expect(outcome.nextActionText, 'Compare fares');
    });

    test('attaches person tags when the carve routes to Waiting For', () async {
      await _insertCapture(db, id: 'c1');
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('p1'),
        name: const Value('Dana'),
        type: const Value('person'),
        userId: const Value(_userId),
      ));

      final outcomeId = await service.carveOutcome(
        'c1',
        userId: _userId,
        title: 'Chase the quote',
        to: RoutingKind.waitingFor,
        personTagIds: {'p1'},
      );

      expect(await db.todoDao.getPersonTagIdsForTodo(outcomeId), {'p1'});
    });
  });

  group('mergeIntoOutcome', () {
    test('links without consuming the Capture or touching the Outcome',
        () async {
      await _insertCapture(db, id: 'c1', title: 'Fragment one');
      await _insertCapture(db, id: 'c2', title: 'Fragment two');
      final outcomeId = await service.carveOutcome(
        'c1',
        userId: _userId,
        title: 'Shared outcome',
      );

      await service.mergeIntoOutcome('c2', outcomeId, userId: _userId);

      // Both Captures survive and both claim the one Outcome.
      expect(await db.captureDao.getCapture('c1'), isNotNull);
      expect(await db.captureDao.getCapture('c2'), isNotNull);
      expect(
        (await db.captureDao.captureIdsForOutcome(outcomeId)).toSet(),
        {'c1', 'c2'},
      );
      expect((await db.todoDao.getTodo(outcomeId))!.title, 'Shared outcome');
      expect(await _clarifiedAt(db, 'c2'), isNull);
    });

    test('is idempotent — a repeat merge adds no second link', () async {
      await _insertCapture(db, id: 'c1');
      final outcomeId =
          await service.carveOutcome('c1', userId: _userId, title: 'Once');
      await _insertCapture(db, id: 'c2');

      await service.mergeIntoOutcome('c2', outcomeId, userId: _userId);
      await service.mergeIntoOutcome('c2', outcomeId, userId: _userId);

      expect(await db.captureDao.outcomeIdsForCapture('c2'), [outcomeId]);
    });

    test('refuses to link an Outcome that has vanished', () async {
      await _insertCapture(db, id: 'c1');
      expect(
        () => service.mergeIntoOutcome('c1', 'gone', userId: _userId),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('unlinkOutcome', () {
    test('deletes a session-carved Outcome', () async {
      await _insertCapture(db, id: 'c1');
      final outcomeId =
          await service.carveOutcome('c1', userId: _userId, title: 'Carved');

      await service.unlinkOutcome('c1', outcomeId, deleteCarved: true);

      expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
      expect(await db.todoDao.getTodo(outcomeId), isNull);
    });

    test('detaches a pre-existing Outcome and leaves it intact', () async {
      await _insertCapture(db, id: 'c1');
      await db.todoDao.insertOutcome(
        id: 'o1',
        title: 'Existing work',
        userId: _userId,
      );
      await service.mergeIntoOutcome('c1', 'o1', userId: _userId);

      await service.unlinkOutcome('c1', 'o1', deleteCarved: false);

      expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
      expect(await db.todoDao.getTodo('o1'), isNotNull);
    });

    test('never deletes an Outcome another Capture still claims', () async {
      await _insertCapture(db, id: 'c1');
      await _insertCapture(db, id: 'c2');
      final outcomeId =
          await service.carveOutcome('c1', userId: _userId, title: 'Shared');
      await service.mergeIntoOutcome('c2', outcomeId, userId: _userId);

      // c1 carved it, so c1's surface would ask for the delete — but c2's
      // claim must veto it.
      await service.unlinkOutcome('c1', outcomeId, deleteCarved: true);

      expect(await db.todoDao.getTodo(outcomeId), isNotNull);
      expect(await db.captureDao.captureIdsForOutcome(outcomeId), ['c2']);
    });
  });

  group('completeCaptureClarification', () {
    test('stamps clarified_at and keeps every linked Outcome', () async {
      await _insertCapture(db, id: 'c1');
      final first =
          await service.carveOutcome('c1', userId: _userId, title: 'One');
      final second =
          await service.carveOutcome('c1', userId: _userId, title: 'Two');

      await service.completeCaptureClarification('c1');

      expect(await _clarifiedAt(db, 'c1'), isNotNull);
      expect(
        (await db.captureDao.outcomeIdsForCapture('c1')).toSet(),
        {first, second},
      );
      expect(await db.todoDao.getTodo(first), isNotNull);
      expect(await db.todoDao.getTodo(second), isNotNull);
    });

    test('leaves the Capture itself in place as provenance', () async {
      await _insertCapture(db, id: 'c1', title: 'The raw fragment');
      await service.carveOutcome('c1', userId: _userId, title: 'One');

      await service.completeCaptureClarification('c1');

      expect((await db.captureDao.getCapture('c1'))!.title, 'The raw fragment');
    });

    test('refuses to stamp a Capture that has vanished', () async {
      expect(
        () => service.completeCaptureClarification('gone'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('discardCapture at zero Outcomes', () {
    test('stamps clarified_at and creates nothing', () async {
      await _insertCapture(db, id: 'c1');

      await service.discardCapture('c1');

      expect(await _clarifiedAt(db, 'c1'), isNotNull);
      expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
      // Discard is not Trash: no Outcome exists to carry `intent = trash`.
      final trashed = await (db.select(db.todos)
            ..where((t) => t.intent.equals(RoutingKind.trash.name)))
          .get();
      expect(trashed, isEmpty);
    });
  });

  group('watchCarvedOutcomes', () {
    test('reports the capture count that drives the provenance chip', () async {
      await _insertCapture(db, id: 'c1');
      await _insertCapture(db, id: 'c2');
      final solo =
          await service.carveOutcome('c1', userId: _userId, title: 'Solo');
      final shared =
          await service.carveOutcome('c1', userId: _userId, title: 'Shared');
      await service.mergeIntoOutcome('c2', shared, userId: _userId);

      final carved = await db.captureDao.watchCarvedOutcomes('c1').first;

      expect(
        {for (final c in carved) c.outcome.id: c.captureCount},
        {solo: 1, shared: 2},
      );
      expect(
        carved.firstWhere((c) => c.outcome.id == solo).isMerged,
        isFalse,
      );
      expect(
        carved.firstWhere((c) => c.outcome.id == shared).isMerged,
        isTrue,
      );
    });
  });

  group('searchOutcomesByTitle', () {
    test('matches case-insensitively on a substring', () async {
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Plan the Kitchen', userId: _userId);
      await db.todoDao
          .insertOutcome(id: 'o2', title: 'Unrelated', userId: _userId);

      final found = await db.todoDao.searchOutcomesByTitle('kitchen');

      expect([for (final t in found) t.id], ['o1']);
    });

    test('excludes trashed and achieved Outcomes', () async {
      await db.todoDao
          .insertOutcome(id: 'live', title: 'Ship the thing', userId: _userId);
      await db.todoDao
          .insertOutcome(id: 'gone', title: 'Ship the other', userId: _userId);
      await db.todoDao
          .insertOutcome(id: 'done', title: 'Ship the last', userId: _userId);
      await db.todoDao.applyRouting('gone', to: RoutingKind.trash);
      await db.todoDao.markDone('done');

      final found = await db.todoDao.searchOutcomesByTitle('Ship');

      expect([for (final t in found) t.id], ['live']);
    });

    test('returns nothing for a blank query', () async {
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Anything', userId: _userId);
      expect(await db.todoDao.searchOutcomesByTitle('   '), isEmpty);
    });

    test('treats LIKE wildcards as literal characters', () async {
      await db.todoDao
          .insertOutcome(id: 'o1', title: '100% done deal', userId: _userId);
      await db.todoDao
          .insertOutcome(id: 'o2', title: 'no wildcard here', userId: _userId);

      final found = await db.todoDao.searchOutcomesByTitle('%');

      expect([for (final t in found) t.id], ['o1']);
    });
  });
}
