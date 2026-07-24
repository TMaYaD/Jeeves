/// DAO for Captures — the Inbox is `captures` with `clarified_at IS NULL`
/// (ADR-0006). Owns the Inbox reads that once ran against
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

/// An Outcome a Capture claims, plus how many Captures claim it in total.
///
/// [captureCount] is the provenance signal the n-m clarify surface renders:
/// `1` is an Outcome this Capture alone carved, `> 1` is a merge — several
/// Captures clarified into the same Outcome (CONTEXT.md § GTD Core: Capture ↔
/// Outcome is many-to-many).
class CarvedOutcome {
  const CarvedOutcome({
    required this.outcome,
    required this.captureCount,
    this.contexts = const [],
  });

  final Todo outcome;
  final int captureCount;

  /// Names of the Outcome's Context tags, alphabetical.
  ///
  /// Contexts gate *when* a next action is visible, so the clarify list shows
  /// them beside the action they qualify (CONTEXT.md § GTD Core: Contexts
  /// attach to the NextAction, not the Task).
  final List<String> contexts;

  /// True when more than one Capture clarified into this Outcome.
  bool get isMerged => captureCount > 1;
}

/// Splits the `GROUP_CONCAT` of Context tag names into a sorted list. SQLite
/// concatenates in unspecified order, so the sort is what keeps the clarify
/// list from reshuffling its chips between rebuilds.
List<String> _splitContexts(String? concatenated) {
  if (concatenated == null || concatenated.isEmpty) return const [];
  return concatenated.split(',')..sort();
}

@DriftAccessor(
    tables: [Captures, CaptureOutcomes, CaptureTags, Tags, Todos, TodoTags])
class CaptureDao extends DatabaseAccessor<GtdDatabase> with _$CaptureDaoMixin {
  CaptureDao(super.db);

  // --- Inbox reads ----------------------------------------------------------

  /// Stream of Inbox captures (`clarified_at IS NULL`), newest first. When
  /// [tagIds] is non-empty only captures carrying **all** those tag hints are
  /// returned (AND semantics).
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
  /// onboarding first-launch collapse (see also [watchHasAnyItem]).
  Stream<bool> watchHasCaptures() =>
      (select(captures)..limit(1)).watch().map((rows) => rows.isNotEmpty);

  /// Emits true as soon as **any** item exists — a Capture (Inbox or clarified)
  /// or an Outcome (`todos`). Drives the first-launch onboarding collapse:
  /// once the split lands, a brand-new user's first quick-add is a Capture, but
  /// a Nirvana import (clarified Outcomes) or a fully-cleared Inbox must also
  /// keep the card dismissed, so both tables are watched (issue #184 Phase 2).
  Stream<bool> watchHasAnyItem() => customSelect(
        'SELECT (EXISTS(SELECT 1 FROM captures) '
        'OR EXISTS(SELECT 1 FROM todos)) AS has_any',
        readsFrom: {captures, todos},
      ).watch().map((rows) => rows.first.read<int>('has_any') != 0);

  /// Count of Inbox captures — the Inbox badge.
  Stream<int> watchInboxCount() {
    final query = selectOnly(captures)
      ..addColumns([captures.id.count()])
      ..where(captures.clarifiedAt.isNull());
    return query.map((row) => row.read(captures.id.count()) ?? 0).watchSingle();
  }

  Future<Capture?> getCapture(String id) =>
      (select(captures)..where((c) => c.id.equals(id))).getSingleOrNull();

  /// Live single-Capture read. The clarify surfaces bind to this so a Capture
  /// edited (or hard-deleted) on another device re-renders the open card.
  /// Emits null once the row is gone.
  Stream<Capture?> watchCapture(String id) =>
      (select(captures)..where((c) => c.id.equals(id))).watchSingleOrNull();

  // --- Capture writes -------------------------------------------------------

  /// Insert a new Capture (Inbox: `clarified_at` stays NULL).
  Future<void> insertCapture(CapturesCompanion companion) async {
    await into(captures).insert(companion);
    attachedDatabase.notifyCapturesViewWrite();
  }

  /// Persist text edits made on a Capture's clarify card.
  ///
  /// A Capture carries only [title] and [notes]; energy, time estimate, due
  /// date and Intent are *Outcome* attributes, so a clarify card holds those
  /// as draft state until [ClarificationService.clarifyCaptureToOutcome] mints
  /// the Outcome and writes them there. `null` means "no change"; pass
  /// [clearNotes] to null the column.
  ///
  /// Deliberately does **not** touch `clarified_at`: refining the wording of a
  /// Capture is not the clarify act (ADR-0006), so an edited Capture stays in
  /// the Inbox. This is the difference from [TodoDao.updateFields], which
  /// stamps `last_clarified_at` because each edit to an Outcome *is* a
  /// clarifying micro-act.
  Future<void> updateFields(
    String id, {
    String? title,
    String? notes,
    bool clearNotes = false,
  }) async {
    if (title == null && notes == null && !clearNotes) return;
    await (update(captures)..where((c) => c.id.equals(id))).write(
      CapturesCompanion(
        title: title != null ? Value(title) : const Value.absent(),
        notes: clearNotes
            ? const Value(null)
            : notes != null
                ? Value(notes)
                : const Value.absent(),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
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

  /// The Capture ids still claiming [outcomeId] — the inverse of
  /// [outcomeIdsForCapture]. Because Capture↔Outcome is many-to-many (merge
  /// links several Captures to one Outcome), a caller cleaning up after one
  /// Capture must check this before hard-deleting the Outcome: a non-empty
  /// result means another Capture still owns it and it must survive.
  Future<List<String>> captureIdsForOutcome(String outcomeId) async {
    final rows = await (select(captureOutcomes)
          ..where((l) => l.outcomeId.equals(outcomeId)))
        .get();
    return [for (final r in rows) r.captureId];
  }

  /// The Outcomes a Capture currently claims, oldest link first, each carrying
  /// the number of Captures that claim it.
  ///
  /// Drives the n-m clarify surface: the list of Outcomes carved out of (or
  /// merged into) the Capture being clarified, and the provenance chip that
  /// marks a shared one. Link order is ascending so the list does not reshuffle
  /// under the user as they add to it.
  Stream<List<CarvedOutcome>> watchCarvedOutcomes(String captureId) =>
      customSelect(
        'SELECT todos.*, ('
        '  SELECT COUNT(*) FROM capture_outcomes AS all_links '
        '  WHERE all_links.outcome_id = todos.id'
        ') AS capture_count, ('
        '  SELECT GROUP_CONCAT(tags.name) FROM tags '
        '  INNER JOIN todo_tags ON todo_tags.tag_id = tags.id '
        "  WHERE todo_tags.todo_id = todos.id AND tags.type = 'context'"
        ') AS context_names '
        'FROM todos '
        'INNER JOIN capture_outcomes ON capture_outcomes.outcome_id = todos.id '
        'WHERE capture_outcomes.capture_id = ? '
        'ORDER BY capture_outcomes.created_at ASC',
        variables: [Variable<String>(captureId)],
        readsFrom: {todos, captureOutcomes, todoTags, tags},
      ).watch().map(
            (rows) => [
              for (final row in rows)
                CarvedOutcome(
                  outcome: todos.map(row.data),
                  captureCount: row.read<int>('capture_count'),
                  contexts: _splitContexts(
                    row.read<String?>('context_names'),
                  ),
                ),
            ],
          );

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

  /// Live tag hints on a Capture, alphabetical — drives the clarify card's
  /// project / context pickers. These are hints, not Organising: they seed the
  /// Outcome's tags when the Capture is clarified and mean nothing on their
  /// own (CONTEXT.md).
  Stream<List<Tag>> watchTagHints(String captureId) {
    final query = select(tags).join([
      innerJoin(captureTags, captureTags.tagId.equalsExp(tags.id)),
    ])
      ..where(captureTags.captureId.equals(captureId))
      ..orderBy([OrderingTerm.asc(tags.name)]);
    return query
        .watch()
        .map((rows) => rows.map((r) => r.readTable(tags)).toList());
  }

  /// One-shot read of the same tag hints [watchTagHints] streams.
  ///
  /// For surfaces that consume hints as *draft input* rather than rendering
  /// them — the standalone clarify screen collects them once at load and lets
  /// them ride into the new Outcome, but shows no tag pickers, so there is
  /// nothing for a live stream to keep in step. Unlike
  /// [tagHintIdsForCapture] this returns whole [Tag] rows, so the caller can
  /// filter by type (person hints travel on the delegate axis, not `tagIds`).
  Future<List<Tag>> tagHintsForCapture(String captureId) {
    final query = select(tags).join([
      innerJoin(captureTags, captureTags.tagId.equalsExp(tags.id)),
    ])
      ..where(captureTags.captureId.equals(captureId))
      ..orderBy([OrderingTerm.asc(tags.name)]);
    return query
        .map((row) => row.readTable(tags))
        .get();
  }

  /// Attach a project-typed tag hint, replacing any existing one.
  ///
  /// A Capture carries at most one project hint, mirroring the single-project
  /// invariant [TaskDetailNotifier.assignProject] enforces on Outcomes — the
  /// hint would otherwise seed an Outcome that violates it.
  Future<void> assignProjectHint(
    String captureId,
    String tagId,
    String userId,
  ) async {
    await transaction(() async {
      await _deleteHintsOfType(captureId, 'project');
      await assignTagHint(captureId, tagId, userId);
    });
  }

  /// Drop the Capture's project-typed tag hint, if any.
  Future<void> clearProjectHint(String captureId) async {
    await _deleteHintsOfType(captureId, 'project');
    attachedDatabase.notifyCapturesViewWrite();
  }

  Future<void> _deleteHintsOfType(String captureId, String type) async {
    final existing = await (select(captureTags).join([
      innerJoin(tags, tags.id.equalsExp(captureTags.tagId)),
    ])
          ..where(
            captureTags.captureId.equals(captureId) & tags.type.equals(type),
          ))
        .get();
    for (final row in existing) {
      await removeTagHint(captureId, row.readTable(tags).id);
    }
  }

  /// The tag-hint ids on a Capture.
  Future<Set<String>> tagHintIdsForCapture(String captureId) async {
    final rows = await (select(captureTags)
          ..where((t) => t.captureId.equals(captureId)))
        .get();
    return {for (final r in rows) r.tagId};
  }
}
