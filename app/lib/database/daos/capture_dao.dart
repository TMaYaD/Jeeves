/// DAO for Captures — the Inbox is `captures` with `clarified_at IS NULL`
/// (ADR-0006). Owns the Inbox reads that once ran against
/// `todos WHERE clarified = false`, plus the Capture↔Outcome provenance links
/// and Capture tag-hint reads/writes.
///
/// Every method that writes a `captures` / `capture_outcomes` / `capture_tags`
/// table directly calls [GtdDatabase.notifyCapturesViewWrite] right after the
/// write: the Inbox reads across all three, so a write to one has to refresh
/// watchers naming another, which Drift's per-table invalidation does not do.
library;

import 'package:drift/drift.dart';
import '../../utils/uuid.dart';
import 'package:uuid/enums.dart' show Namespace;

import '../../sync/collection_codecs.dart';
import '../gtd_database.dart';
import 'action_dao.dart' show ActionDao;

part 'capture_dao.g.dart';

/// Deterministic `capture_outcomes.id` for the (captureId, outcomeId) pair.
///
/// The op log names an entity by one id, so the junction row needs
/// an explicit one; deriving it from the pair makes re-linking collapse under
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
    this.currentActionText,
  });

  final Todo outcome;
  final int captureCount;

  /// Text of the Outcome's current Action, or null when it is Actionless.
  ///
  /// Joined in rather than read off [outcome]: the Action entity is the only
  /// next-action grain (ADR-0001 story 3; the Outcome-column cursor it replaced
  /// no longer exists).
  final String? currentActionText;

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

@DriftAccessor(tables: [
  Captures,
  CaptureOutcomes,
  CaptureTags,
  Tags,
  Todos,
  TodoTags,
  Actions,
])
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
    await attachedDatabase.capturing(() async {
      await into(captures).insert(companion);
      attachedDatabase.notifyCapturesViewWrite();
      // Read back rather than trust the companion: `id` and `created_at` can
      // come from client defaults, and the create assertion must carry the full
      // field set a peer will build the row from.
      final id = companion.id.present ? companion.id.value : null;
      final row = id == null
          ? null
          : await (select(captures)..where((c) => c.id.equals(id)))
              .getSingleOrNull();
      if (row == null) return;
      attachedDatabase.opCapture.write(
        collection: capturesCollection,
        entityId: row.id,
        fields: _wholeCaptureRowFields(row),
      );
    });
  }

  /// The whole synced row, as the op-log fields a create asserts. Exactly
  /// `collectionCodecs[capturesCollection].columns` — the contract test pins the
  /// two sets equal, so a new synced column has one place to be added.
  static Map<String, Object?> _wholeCaptureRowFields(Capture row) => {
        'title': row.title,
        'notes': row.notes,
        'capture_source': row.captureSource,
        'created_at': encodeInstant(row.createdAt),
        'clarified_at': encodeInstant(row.clarifiedAt),
        'updated_at': encodeInstant(row.updatedAt),
        'user_id': row.userId,
      };

  /// The op-log fields a partial [companion] describes: only the columns it
  /// actually carries, so an update never re-asserts a column it left alone.
  static Map<String, Object?> _presentCaptureFields(
          CapturesCompanion companion) =>
      {
        if (companion.title.present) 'title': companion.title.value,
        if (companion.notes.present) 'notes': companion.notes.value,
        if (companion.captureSource.present)
          'capture_source': companion.captureSource.value,
        if (companion.createdAt.present)
          'created_at': encodeInstant(companion.createdAt.value),
        if (companion.clarifiedAt.present)
          'clarified_at': encodeInstant(companion.clarifiedAt.value),
        if (companion.updatedAt.present)
          'updated_at': encodeInstant(companion.updatedAt.value),
        if (companion.userId.present) 'user_id': companion.userId.value,
      };

  /// Insert the Capture [id] from [createColumns], or — when it already exists —
  /// update it with exactly the columns [updateColumns] carries.
  ///
  /// The re-runnable write an id-addressed source of record needs (the Nirvana
  /// import): a re-run lands on the same deterministic id, refreshes what the
  /// export owns, and leaves the rest as the user has since made it. So
  /// [createColumns] carries `created_at` and [updateColumns] does not.
  ///
  /// A distinct method from [updateFields] rather than a widened one:
  /// [updateFields] is the clarify card's text edit, which hard-codes its own
  /// timestamp and deliberately never touches `capture_source` — a contract this
  /// must not disturb. Neither companion here should carry `clarified_at`
  /// either: a Capture the user has since clarified must not be pushed back to
  /// the Inbox by a re-run.
  ///
  /// An UPDATE, never `INSERT OR REPLACE`: REPLACE is delete-then-insert, which
  /// would re-stamp `created_at`, reset `clarified_at`, and fire the declared
  /// ON DELETE CASCADE onto `capture_outcomes` / `capture_tags` wherever
  /// foreign-key enforcement is on (latent today — issue #637).
  ///
  /// On the log: a create asserts the whole codec column set so a peer that has
  /// never seen the Capture can build it; an update asserts only the fields it
  /// changed, so it cannot clobber a peer's concurrent edit to a column this
  /// write never touched.
  Future<void> upsertCapture({
    required String id,
    required CapturesCompanion createColumns,
    required CapturesCompanion updateColumns,
  }) async {
    await attachedDatabase.capturing(() async {
      final existing = await (select(captures)..where((c) => c.id.equals(id)))
          .getSingleOrNull();
      if (existing == null) {
        await into(captures).insert(createColumns.copyWith(id: Value(id)));
        // Read back rather than trust the companion: `created_at` can come from
        // a client default, and the create assertion must carry the value the
        // row actually holds.
        final created = await (select(captures)..where((c) => c.id.equals(id)))
            .getSingle();
        attachedDatabase.opCapture.write(
          collection: capturesCollection,
          entityId: id,
          fields: _wholeCaptureRowFields(created),
        );
      } else {
        await (update(captures)..where((c) => c.id.equals(id)))
            .write(updateColumns);
        final fields = _presentCaptureFields(updateColumns);
        if (fields.isNotEmpty) {
          attachedDatabase.opCapture.write(
            collection: capturesCollection,
            entityId: id,
            fields: fields,
          );
        }
      }
      attachedDatabase.notifyCapturesViewWrite();
    });
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
    final ts = DateTime.now().toUtc();
    await attachedDatabase.capturing(() async {
      await (update(captures)..where((c) => c.id.equals(id))).write(
        CapturesCompanion(
          title: title != null ? Value(title) : const Value.absent(),
          notes: clearNotes
              ? const Value(null)
              : notes != null
                  ? Value(notes)
                  : const Value.absent(),
          updatedAt: Value(ts),
        ),
      );
      attachedDatabase.opCapture.write(
        collection: capturesCollection,
        entityId: id,
        fields: {
          'title': ?title,
          if (clearNotes) 'notes': null else 'notes': ?notes,
          'updated_at': encodeInstant(ts),
        },
      );
      attachedDatabase.notifyCapturesViewWrite();
    });
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
    await attachedDatabase.capturing(() async {
      // The stamp is conditional on the row being unstamped, so the op is
      // captured only when the write actually moved it — otherwise a repeat
      // call would author an op that re-asserts the original moment.
      final unstamped = await (select(captures)
            ..where((c) => c.id.equals(id) & c.clarifiedAt.isNull()))
          .getSingleOrNull();
      await (update(captures)
            ..where((c) => c.id.equals(id) & c.clarifiedAt.isNull()))
          .write(
        CapturesCompanion(clarifiedAt: Value(ts), updatedAt: Value(ts)),
      );
      if (unstamped != null) {
        attachedDatabase.opCapture.write(
          collection: capturesCollection,
          entityId: id,
          fields: {
            'clarified_at': encodeInstant(ts),
            'updated_at': encodeInstant(ts),
          },
        );
      }
      attachedDatabase.notifyCapturesViewWrite();
    });
  }

  /// Reverse a stamp (Ceremony Back / in-session undo): return the Capture to
  /// the Inbox by clearing `clarified_at`.
  Future<void> unstampClarified(String id) async {
    final ts = DateTime.now().toUtc();
    await attachedDatabase.capturing(() async {
      await (update(captures)..where((c) => c.id.equals(id))).write(
        CapturesCompanion(
          clarifiedAt: const Value(null),
          updatedAt: Value(ts),
        ),
      );
      // A nullable field write, not a tombstone: the Capture is alive and back
      // in the Inbox.
      attachedDatabase.opCapture.write(
        collection: capturesCollection,
        entityId: id,
        fields: {'clarified_at': null, 'updated_at': encodeInstant(ts)},
      );
      attachedDatabase.notifyCapturesViewWrite();
    });
  }

  // --- Capture ↔ Outcome provenance links -----------------------------------

  /// Link [captureId] to the Outcome [outcomeId] (idempotent). The
  /// deterministic id makes a repeat link a no-op under INSERT OR IGNORE, so
  /// the *first* link's `created_at` provenance timestamp is preserved rather
  /// than overwritten. [userId] is denormalized onto the junction row so it
  /// carries its owner without a JOIN, and must match the parent Capture's
  /// `user_id`.
  Future<void> linkOutcome(
    String captureId,
    String outcomeId,
    String userId, {
    DateTime? at,
  }) async {
    final ts = (at ?? DateTime.now()).toUtc();
    await attachedDatabase.capturing(() async {
      await into(captureOutcomes).insert(
        CaptureOutcomesCompanion(
          id: Value(captureOutcomeIdFor(captureId, outcomeId)),
          captureId: Value(captureId),
          outcomeId: Value(outcomeId),
          createdAt: Value(ts),
          userId: Value(userId),
        ),
        mode: InsertMode.insertOrIgnore,
      );
      // Deliberate divergence from the local INSERT-OR-IGNORE nuance: on the
      // log a re-link re-asserts `created_at` at the new clarifying act's time.
      // A re-link *is* a new clarifying micro-act, and a junction whose fields
      // depended on whether the local row happened to exist could not converge.
      attachedDatabase.opCapture.write(
        collection: captureOutcomesCollection,
        entityId: captureOutcomeIdFor(captureId, outcomeId),
        fields: {
          'capture_id': captureId,
          'outcome_id': outcomeId,
          'created_at': encodeInstant(ts),
          'user_id': userId,
        },
      );
      attachedDatabase.notifyCapturesViewWrite();
    });
  }

  /// Remove a Capture↔Outcome link (merge-unlink; the pre-existing Outcome is
  /// left intact — deleting a session-created Outcome is the caller's job).
  Future<int> unlinkOutcome(String captureId, String outcomeId) async {
    return attachedDatabase.capturing(() async {
      final rows = await (delete(captureOutcomes)
            ..where(
              (l) =>
                  l.captureId.equals(captureId) & l.outcomeId.equals(outcomeId),
            ))
          .go();
      // Only a delete that matched authors a tombstone. An idempotent or
      // stale-state call holds no such junction, and a delete op for the
      // deterministic id would bury a link another device created concurrently.
      // (`linkOutcome` authors unconditionally on purpose — a re-link is a new
      // clarifying act — so the asymmetry is deliberate.)
      if (rows > 0) {
        attachedDatabase.opCapture.tombstone(
          collection: captureOutcomesCollection,
          entityId: captureOutcomeIdFor(captureId, outcomeId),
        );
      }
      attachedDatabase.notifyCapturesViewWrite();
      return rows;
    });
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
        ') AS context_names, ('
        // The current Action's text, winner-first so a multi-current race
        // renders the same row everywhere (ActionDao.winnerFirstOrderSql).
        '  SELECT actions.text FROM actions '
        "  WHERE actions.outcome_id = todos.id AND actions.role = 'current' "
        '  ${ActionDao.winnerFirstOrderSql} LIMIT 1'
        ') AS current_action_text '
        'FROM todos '
        'INNER JOIN capture_outcomes ON capture_outcomes.outcome_id = todos.id '
        'WHERE capture_outcomes.capture_id = ? '
        'ORDER BY capture_outcomes.created_at ASC',
        variables: [Variable<String>(captureId)],
        readsFrom: {todos, captureOutcomes, todoTags, tags, actions},
      ).watch().map(
            (rows) => [
              for (final row in rows)
                CarvedOutcome(
                  outcome: todos.map(row.data),
                  captureCount: row.read<int>('capture_count'),
                  contexts: _splitContexts(
                    row.read<String?>('context_names'),
                  ),
                  currentActionText:
                      row.read<String?>('current_action_text'),
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
    await attachedDatabase.capturing(() async {
      await into(captureTags).insert(
        CaptureTagsCompanion(
          id: Value(captureTagIdFor(captureId, tagId)),
          captureId: Value(captureId),
          tagId: Value(tagId),
          userId: Value(userId),
        ),
        mode: InsertMode.insertOrReplace,
      );
      attachedDatabase.opCapture.write(
        collection: captureTagsCollection,
        entityId: captureTagIdFor(captureId, tagId),
        fields: {
          'capture_id': captureId,
          'tag_id': tagId,
          'user_id': userId,
        },
      );
      attachedDatabase.notifyCapturesViewWrite();
    });
  }

  /// Remove a tag hint from a Capture.
  Future<int> removeTagHint(String captureId, String tagId) async {
    return attachedDatabase.capturing(() async {
      final rows = await (delete(captureTags)
            ..where(
              (t) => t.captureId.equals(captureId) & t.tagId.equals(tagId),
            ))
          .go();
      // Gated for the same reason as `unlinkOutcome`: a delete that matched
      // nothing has no effect to describe on the log.
      if (rows > 0) {
        attachedDatabase.opCapture.tombstone(
          collection: captureTagsCollection,
          entityId: captureTagIdFor(captureId, tagId),
        );
      }
      attachedDatabase.notifyCapturesViewWrite();
      return rows;
    });
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
    await attachedDatabase.capturing(() async {
      await _deleteHintsOfType(captureId, 'project');
      await assignTagHint(captureId, tagId, userId);
    });
  }

  /// Drop the Capture's project-typed tag hint, if any.
  Future<void> clearProjectHint(String captureId) async {
    await attachedDatabase.capturing(() async {
      await _deleteHintsOfType(captureId, 'project');
      attachedDatabase.notifyCapturesViewWrite();
    });
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
