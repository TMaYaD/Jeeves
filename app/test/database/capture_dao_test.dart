import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/capture_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

const _userId = 'test-user';

CapturesCompanion _capture({
  required String id,
  required String title,
  String? captureSource = 'manual',
  DateTime? createdAt,
}) {
  final now = createdAt ?? DateTime.now();
  return CapturesCompanion(
    id: Value(id),
    title: Value(title),
    captureSource: Value(captureSource),
    userId: Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  );
}

/// A minimal clarified Outcome row so provenance links have a valid FK target.
/// Goes through the production write path ([TodoDao.insertOutcome]) so these
/// tests exercise the same insert — and the same view-notify — the clarify flow
/// uses, rather than a raw `todos` insert that skips it.
Future<void> _insertOutcome(GtdDatabase db, String id, String title) =>
    db.todoDao.insertOutcome(id: id, title: title, userId: _userId);

Future<String> _insertTag(GtdDatabase db, String name) =>
    db.tagDao.findOrCreateTag(name, 'context', _userId);

void main() {
  setUpAll(configureSqliteForTests);

  group('CaptureDao', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('a fresh Capture is in the Inbox (clarified_at IS NULL)', () async {
      await db.captureDao.insertCapture(_capture(id: 'c1', title: 'Buy milk'));

      final inbox = await db.captureDao.watchInbox().first;
      expect(inbox.map((c) => c.id), ['c1']);
      expect(inbox.first.clarifiedAt, isNull);
    });

    test('watchInbox orders newest first', () async {
      await db.captureDao.insertCapture(_capture(
        id: 'old',
        title: 'Old',
        createdAt: DateTime.utc(2026, 1, 1),
      ));
      await db.captureDao.insertCapture(_capture(
        id: 'new',
        title: 'New',
        createdAt: DateTime.utc(2026, 6, 1),
      ));

      final inbox = await db.captureDao.watchInbox().first;
      expect(inbox.map((c) => c.id), ['new', 'old']);
    });

    test('stampClarified removes the Capture from the Inbox', () async {
      await db.captureDao.insertCapture(_capture(id: 'c1', title: 'Idea'));
      await db.captureDao.stampClarified('c1');

      expect(await db.captureDao.watchInbox().first, isEmpty);
      // The Capture persists (never deleted) — the row is still in the table.
      expect(await db.select(db.captures).get(), isNotEmpty);
      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNotNull);
    });

    test('unstampClarified returns the Capture to the Inbox', () async {
      await db.captureDao.insertCapture(_capture(id: 'c1', title: 'Idea'));
      await db.captureDao.stampClarified('c1');
      await db.captureDao.unstampClarified('c1');

      expect(await db.captureDao.watchInbox().first, hasLength(1));
      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNull);
    });

    test('stampClarified is idempotent — a repeat call keeps the first moment',
        () async {
      await db.captureDao.insertCapture(_capture(id: 'c1', title: 'Idea'));
      await db.captureDao
          .stampClarified('c1', at: DateTime.utc(2026, 1, 1, 9));
      // A later stamp must not move the original clarification timestamp.
      await db.captureDao
          .stampClarified('c1', at: DateTime.utc(2026, 6, 1, 9));

      expect(
        (await db.captureDao.getCapture('c1'))!.clarifiedAt,
        DateTime.utc(2026, 1, 1, 9),
      );

      // But an un-stamped (undo) Capture can be stamped afresh.
      await db.captureDao.unstampClarified('c1');
      await db.captureDao
          .stampClarified('c1', at: DateTime.utc(2026, 6, 1, 9));
      expect(
        (await db.captureDao.getCapture('c1'))!.clarifiedAt,
        DateTime.utc(2026, 6, 1, 9),
      );
    });

    test('updateFields edits text and leaves the Capture in the Inbox',
        () async {
      await db.captureDao.insertCapture(_capture(id: 'c1', title: 'buy milk'));

      await db.captureDao
          .updateFields('c1', title: 'Buy oat milk', notes: 'the barista one');

      final edited = (await db.captureDao.getCapture('c1'))!;
      expect(edited.title, 'Buy oat milk');
      expect(edited.notes, 'the barista one');
      // Refining the wording of a Capture is not the clarify act (ADR-0006):
      // the row must still be in the Inbox afterwards.
      expect(edited.clarifiedAt, isNull);
      expect(await db.captureDao.watchInbox().first, hasLength(1));
    });

    test('updateFields clears notes only via the clear flag', () async {
      await db.captureDao.insertCapture(_capture(id: 'c1', title: 'Idea'));
      await db.captureDao.updateFields('c1', notes: 'keep me');

      // A null `notes` means "no change", not "erase".
      await db.captureDao.updateFields('c1', title: 'Idea, refined');
      expect((await db.captureDao.getCapture('c1'))!.notes, 'keep me');

      await db.captureDao.updateFields('c1', clearNotes: true);
      expect((await db.captureDao.getCapture('c1'))!.notes, isNull);
    });

    test('updateFields with nothing to write is a no-op', () async {
      await db.captureDao.insertCapture(_capture(id: 'c1', title: 'Idea'));
      final before = (await db.captureDao.getCapture('c1'))!;

      await db.captureDao.updateFields('c1');

      // No mutation means no updated_at churn — an empty autosave flush must
      // not manufacture a sync upload.
      expect((await db.captureDao.getCapture('c1'))!.updatedAt, before.updatedAt);
    });

    test('watchCapture emits edits and then null once the row is gone',
        () async {
      await db.captureDao.insertCapture(_capture(id: 'c1', title: 'Idea'));

      expect((await db.captureDao.watchCapture('c1').first)!.title, 'Idea');

      await db.captureDao.updateFields('c1', title: 'Sharper idea');
      expect(
        (await db.captureDao.watchCapture('c1').first)!.title,
        'Sharper idea',
      );

      // Simulates a sync-download removing the row (no production code path
      // deletes Captures — ADR-0006).
      await (db.delete(db.captures)..where((c) => c.id.equals('c1'))).go();
      expect(await db.captureDao.watchCapture('c1').first, isNull);
    });

    test('linkOutcome preserves the first link\'s createdAt on a repeat',
        () async {
      await db.captureDao.insertCapture(_capture(id: 'c1', title: 'Project X'));
      await _insertOutcome(db, 'o1', 'Draft outline');

      await db.captureDao
          .linkOutcome('c1', 'o1', _userId, at: DateTime.utc(2026, 1, 1));
      await db.captureDao
          .linkOutcome('c1', 'o1', _userId, at: DateTime.utc(2026, 6, 1));

      final links = await (db.select(db.captureOutcomes)
            ..where((l) => l.captureId.equals('c1')))
          .get();
      expect(links, hasLength(1));
      expect(links.single.createdAt, DateTime.utc(2026, 1, 1));
    });

    test('watchInbox tag-hint filter uses AND semantics', () async {
      await db.captureDao.insertCapture(_capture(id: 'c1', title: 'One'));
      await db.captureDao.insertCapture(_capture(id: 'c2', title: 'Two'));
      final work = await _insertTag(db, 'work');
      final home = await _insertTag(db, 'home');

      await db.captureDao.assignTagHint('c1', work, _userId);
      await db.captureDao.assignTagHint('c1', home, _userId);
      await db.captureDao.assignTagHint('c2', work, _userId);

      final both =
          await db.captureDao.watchInbox(tagIds: {work, home}).first;
      expect(both.map((c) => c.id), ['c1']);

      final workOnly = await db.captureDao.watchInbox(tagIds: {work}).first;
      expect(workOnly.map((c) => c.id).toSet(), {'c1', 'c2'});
    });

    test('tag hints round-trip and are removable', () async {
      await db.captureDao.insertCapture(_capture(id: 'c1', title: 'One'));
      final work = await _insertTag(db, 'work');

      await db.captureDao.assignTagHint('c1', work, _userId);
      expect(await db.captureDao.tagHintIdsForCapture('c1'), {work});

      // Idempotent: re-assigning the same hint does not duplicate.
      await db.captureDao.assignTagHint('c1', work, _userId);
      expect(await db.captureDao.tagHintIdsForCapture('c1'), {work});

      await db.captureDao.removeTagHint('c1', work);
      expect(await db.captureDao.tagHintIdsForCapture('c1'), isEmpty);
    });

    test('linkOutcome records provenance both ways; unlink removes it',
        () async {
      await db.captureDao.insertCapture(_capture(id: 'c1', title: 'Project X'));
      await _insertOutcome(db, 'o1', 'Draft outline');
      await _insertOutcome(db, 'o2', 'Send to reviewers');

      // One Capture splits into two Outcomes.
      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      await db.captureDao.linkOutcome('c1', 'o2', _userId);
      expect(
        (await db.captureDao.outcomeIdsForCapture('c1')).toSet(),
        {'o1', 'o2'},
      );

      // Provenance for an Outcome: the Captures it was clarified from.
      final prov = await db.captureDao.watchCapturesForOutcome('o1').first;
      expect(prov.map((c) => c.id), ['c1']);

      // Idempotent link (deterministic id collapses under INSERT OR REPLACE).
      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      expect((await db.captureDao.outcomeIdsForCapture('c1')).length, 2);

      await db.captureDao.unlinkOutcome('c1', 'o1');
      expect(await db.captureDao.outcomeIdsForCapture('c1'), ['o2']);
    });

    test('merge: multiple Captures link to one Outcome', () async {
      await db.captureDao.insertCapture(_capture(id: 'c1', title: 'Call John'));
      await db.captureDao.insertCapture(_capture(id: 'c2', title: 'Ring John'));
      await _insertOutcome(db, 'o1', 'Catch up with John');

      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      await db.captureDao.linkOutcome('c2', 'o1', _userId);

      final prov = await db.captureDao.watchCapturesForOutcome('o1').first;
      expect(prov.map((c) => c.id).toSet(), {'c1', 'c2'});
    });

    test('watchHasAnyItem is true for a capture, an outcome, or both',
        () async {
      // Empty DB → false.
      expect(await db.captureDao.watchHasAnyItem().first, isFalse);

      // Capture-only → true.
      await db.captureDao.insertCapture(_capture(id: 'c1', title: 'Idea'));
      expect(await db.captureDao.watchHasAnyItem().first, isTrue);

      // Removing the only capture → false again.
      await (db.delete(db.captures)..where((c) => c.id.equals('c1'))).go();
      expect(await db.captureDao.watchHasAnyItem().first, isFalse);

      // Outcome-only (no captures) → true.
      await _insertOutcome(db, 'o1', 'Outcome');
      expect(await db.captureDao.watchHasAnyItem().first, isTrue);

      // Both populated → true.
      await db.captureDao.insertCapture(_capture(id: 'c2', title: 'Another'));
      expect(await db.captureDao.watchHasAnyItem().first, isTrue);
    });

    test('watchHasAnyItem re-emits on inserts and deletes in either table',
        () async {
      final emissions = <bool>[];
      final sub = db.captureDao.watchHasAnyItem().listen(emissions.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      await db.captureDao.insertCapture(_capture(id: 'c1', title: 'Idea'));
      await pumpEventQueue();
      await _insertOutcome(db, 'o1', 'Outcome');
      await pumpEventQueue();
      // Delete the capture — the outcome still keeps it true.
      await (db.delete(db.captures)..where((c) => c.id.equals('c1'))).go();
      await pumpEventQueue();
      // Delete the last outcome via the production path — now nothing remains.
      await db.todoDao.deleteOutcome('o1');
      await pumpEventQueue();

      expect(emissions.first, isFalse, reason: 'starts empty');
      expect(emissions.last, isFalse, reason: 'ends empty after both deleted');
      expect(emissions.contains(true), isTrue,
          reason: 'reacted to inserts in either table');
    });

    test('deterministic junction ids are stable for a pair', () {
      expect(
        captureOutcomeIdFor('c1', 'o1'),
        captureOutcomeIdFor('c1', 'o1'),
      );
      expect(
        captureOutcomeIdFor('c1', 'o1'),
        isNot(captureOutcomeIdFor('c1', 'o2')),
      );
      expect(captureTagIdFor('c1', 't1'), captureTagIdFor('c1', 't1'));
    });
  });
}
