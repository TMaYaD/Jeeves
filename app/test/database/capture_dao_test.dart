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
Future<void> _insertOutcome(GtdDatabase db, String id, String title) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
}

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
      expect(await db.captureDao.watchInboxCount().first, 1);
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
      expect(await db.captureDao.watchInboxCount().first, 0);
      // The Capture persists (never deleted) — still visible to watchHasCaptures.
      expect(await db.captureDao.watchHasCaptures().first, isTrue);
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
