/// DAO for Captures — the Inbox is `captures` with `clarified_at IS NULL`
/// (ADR-0006). Absorbs the reads the old [InboxDao] performed against
/// `todos WHERE clarified = false`, plus the Capture↔Outcome provenance links
/// and Capture tag-hint reads/writes.
///
/// Every method that writes a `captures` / `capture_outcomes` / `capture_tags`
/// view directly calls [GtdDatabase.notifyCapturesViewWrite] right after the
/// write: in production these are PowerSync views with INSTEAD OF triggers, so
/// the write reports `changes() == 0` and Drift's built-in stream invalidation
/// never fires (ADR-0010).
library;

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart' show uuid;
import 'package:uuid/enums.dart' show Namespace;

import '../gtd_database.dart';

part 'capture_dao.g.dart';

/// Deterministic `capture_outcomes.id` for the (captureId, outcomeId) pair.
///
/// PowerSync exposes `capture_outcomes` as a view whose INSTEAD OF INSERT
/// trigger writes `NEW.id` into the backing table, so the junction row needs
/// an explicit id; deriving it from the pair makes re-linking collapse under
/// INSERT OR REPLACE instead of accumulating duplicate rows (todo_tags
/// precedent).
String captureOutcomeIdFor(String captureId, String outcomeId) => uuid.v5(
      Namespace.url.value,
      'jeeves://capture_outcome/$captureId/$outcomeId',
    );

/// Deterministic `capture_tags.id` for the (captureId, tagId) pair.
String captureTagIdFor(String captureId, String tagId) =>
    uuid.v5(Namespace.url.value, 'jeeves://capture_tag/$captureId/$tagId');

@DriftAccessor(tables: [Captures, CaptureOutcomes, CaptureTags, Tags, Todos])
class CaptureDao extends DatabaseAccessor<GtdDatabase> with _$CaptureDaoMixin {
  CaptureDao(super.db);

  // --- Inbox reads ----------------------------------------------------------

  /// Stream of Inbox captures (`clarified_at IS NULL`), newest first. When
  /// [tagIds] is non-empty only captures carrying **all** those tag hints are
  /// returned (AND semantics), mirroring the old [InboxDao] tag filter.
  Stream<List<Capture>> watchInbox({Set<String> tagIds = const {}}) {
    if (tagIds.isEmpty) {
      return (select(captures)
            ..where((c) => c.clarifiedAt.isNull())
            ..orderBy([(c) => OrderingTerm.desc(c.createdAt)]))
          .watch();
    }

    final n = tagIds.length;
    final placeholders = List.filled(n, '?').join(', ');
    return customSelect(
      'SELECT captures.* FROM captures '
      'WHERE captures.clarified_at IS NULL '
      'AND (SELECT COUNT(DISTINCT tag_id) FROM capture_tags '
      '     WHERE capture_id = captures.id '
      '       AND tag_id IN ($placeholders)) = $n '
      'ORDER BY captures.created_at DESC',
      variables: [...tagIds.map(Variable.new)],
      readsFrom: {captures, captureTags},
    ).watch().map(
          (rows) => rows.map((row) => captures.map(row.data)).toList(),
        );
  }

  /// Emits true as soon as any capture exists (Inbox or clarified). Feeds the
  /// onboarding first-launch collapse alongside `InboxDao.watchHasTodos`.
  Stream<bool> watchHasCaptures() =>
      (select(captures)..limit(1)).watch().map((rows) => rows.isNotEmpty);

  /// Count of Inbox captures — the Inbox badge.
  Stream<int> watchInboxCount() {
    final query = selectOnly(captures)
      ..addColumns([captures.id.count()])
      ..where(captures.clarifiedAt.isNull());
    return query.map((row) => row.read(captures.id.count()) ?? 0).watchSingle();
  }

  Future<Capture?> getCapture(String id) =>
      (select(captures)..where((c) => c.id.equals(id))).getSingleOrNull();

  // --- Capture writes -------------------------------------------------------

  /// Insert a new Capture (Inbox: `clarified_at` stays NULL).
  Future<void> insertCapture(CapturesCompanion companion) async {
    await into(captures).insert(companion);
    attachedDatabase.notifyCapturesViewWrite();
  }

  /// Stamp `clarified_at` — completes the clarify act for [id]. In 1-1 mode
  /// this fires automatically at the first Outcome link; in n-m mode it fires
  /// when the user presses the footer (Done-with-links or Discard-at-zero).
  ///
  /// Idempotent: only an *unstamped* Capture is stamped, so a repeated call
  /// never moves the original clarification moment. A Capture returned to the
  /// Inbox via [unstampClarified] (clarified_at back to NULL) can be stamped
  /// afresh.
  Future<void> stampClarified(String id, {DateTime? at}) async {
    final ts = (at ?? DateTime.now()).toUtc();
    await (update(captures)
          ..where((c) => c.id.equals(id) & c.clarifiedAt.isNull()))
        .write(
      CapturesCompanion(clarifiedAt: Value(ts), updatedAt: Value(ts)),
    );
    attachedDatabase.notifyCapturesViewWrite();
  }

  /// Reverse a stamp (Ceremony Back / in-session undo): return the Capture to
  /// the Inbox by clearing `clarified_at`.
  Future<void> unstampClarified(String id) async {
    await (update(captures)..where((c) => c.id.equals(id))).write(
      CapturesCompanion(
        clarifiedAt: const Value(null),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    attachedDatabase.notifyCapturesViewWrite();
  }

  /// Delete a Capture. The clarify flow never deletes Captures (merge links,
  /// never consumes — ADR-0006); this exists only for local-only cleanup and
  /// test teardown.
  Future<int> deleteCapture(String id) async {
    final rows = await (delete(captures)..where((c) => c.id.equals(id))).go();
    attachedDatabase.notifyCapturesViewWrite();
    return rows;
  }

  // --- Capture ↔ Outcome provenance links -----------------------------------

  /// Link [captureId] to the Outcome [outcomeId] (idempotent). The
  /// deterministic id makes a repeat link a no-op under INSERT OR IGNORE, so
  /// the *first* link's `created_at` provenance timestamp is preserved rather
  /// than overwritten. [userId] is denormalized onto the junction row for the
  /// PowerSync bucket and must match the parent Capture's `user_id`.
  Future<void> linkOutcome(
    String captureId,
    String outcomeId,
    String userId, {
    DateTime? at,
  }) async {
    await into(captureOutcomes).insert(
      CaptureOutcomesCompanion(
        id: Value(captureOutcomeIdFor(captureId, outcomeId)),
        captureId: Value(captureId),
        outcomeId: Value(outcomeId),
        createdAt: Value((at ?? DateTime.now()).toUtc()),
        userId: Value(userId),
      ),
      mode: InsertMode.insertOrIgnore,
    );
    attachedDatabase.notifyCapturesViewWrite();
  }

  /// Remove a Capture↔Outcome link (merge-unlink; the pre-existing Outcome is
  /// left intact — deleting a session-created Outcome is the caller's job).
  Future<int> unlinkOutcome(String captureId, String outcomeId) async {
    final rows = await (delete(captureOutcomes)
          ..where(
            (l) => l.captureId.equals(captureId) & l.outcomeId.equals(outcomeId),
          ))
        .go();
    attachedDatabase.notifyCapturesViewWrite();
    return rows;
  }

  /// The Outcome ids a Capture has clarified into.
  Future<List<String>> outcomeIdsForCapture(String captureId) async {
    final rows = await (select(captureOutcomes)
          ..where((l) => l.captureId.equals(captureId)))
        .get();
    return [for (final r in rows) r.outcomeId];
  }

  /// Provenance for an Outcome: the Captures it was clarified from, newest link
  /// first. Drives the "Captured from…" display (issue #184 Phase 4).
  Stream<List<Capture>> watchCapturesForOutcome(String outcomeId) {
    final query = select(captures).join([
      innerJoin(
        captureOutcomes,
        captureOutcomes.captureId.equalsExp(captures.id),
      ),
    ])
      ..where(captureOutcomes.outcomeId.equals(outcomeId))
      ..orderBy([OrderingTerm.desc(captureOutcomes.createdAt)]);
    return query
        .watch()
        .map((rows) => rows.map((r) => r.readTable(captures)).toList());
  }

  // --- Tag hints ------------------------------------------------------------

  /// Attach a tag hint to a Capture (idempotent). Tag hints never stamp
  /// anything and are not Organising (issue #184).
  Future<void> assignTagHint(
    String captureId,
    String tagId,
    String userId,
  ) async {
    await into(captureTags).insert(
      CaptureTagsCompanion(
        id: Value(captureTagIdFor(captureId, tagId)),
        captureId: Value(captureId),
        tagId: Value(tagId),
        userId: Value(userId),
      ),
      mode: InsertMode.insertOrReplace,
    );
    attachedDatabase.notifyCapturesViewWrite();
  }

  /// Remove a tag hint from a Capture.
  Future<int> removeTagHint(String captureId, String tagId) async {
    final rows = await (delete(captureTags)
          ..where(
            (t) => t.captureId.equals(captureId) & t.tagId.equals(tagId),
          ))
        .go();
    attachedDatabase.notifyCapturesViewWrite();
    return rows;
  }

  /// The tag-hint ids on a Capture.
  Future<Set<String>> tagHintIdsForCapture(String captureId) async {
    final rows = await (select(captureTags)
          ..where((t) => t.captureId.equals(captureId)))
        .get();
    return {for (final r in rows) r.tagId};
  }
}
