/// Single write path for the clarification flow (issue #184).
///
/// Consolidates the clarify-flow DB writes previously spread across
/// [ProcessToHandlers], [InboxClarifyScreen], and
/// [FocusSessionPlanningNotifier] behind one interface, per the issue #184
/// reversibility directive: nothing outside this service may bake "Inbox is
/// just a Todo with `clarified = false`" into a load-bearing assumption.
///
/// Vocabulary is CONTEXT.md's: methods speak Capture and Outcome. The
/// interface carries two write families:
///
/// - **Outcome routing** — [clarifyToOutcome], [promoteCaptureToOutcome],
///   [completeOutcome], [stampClarified], [updateFields] (+ the [exists] /
///   [getPersonTagIds] guards). These operate on the conflated `todos` row and
///   back today's review + Inbox surfaces.
/// - **Capture clarification** (ADR-0006, the split model) —
///   [clarifyCaptureToOutcome], [discardCapture], [captureExists]. Clarifying a
///   Capture creates a *new* Outcome, links it (`capture_outcomes` provenance),
///   and stamps `captures.clarified_at`; discard is the zero-Outcome verdict.
///   This is the write path the Capture-split Inbox/clarify UI cutover will
///   use — a staged follow-up (see ARCHITECTURE.md); the methods are pinned by
///   tests ahead of their callsites.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../database/gtd_database.dart';
import '../models/todo.dart' show RoutingKind;
import '../providers/database_provider.dart';

/// Interface for every write the clarification UI flows perform, plus the
/// reads those flows need to guard their writes (row-existence pre-checks,
/// person-tag pre-seeding for the Waiting For picker).
abstract class ClarificationService {
  /// Whether the Capture [captureId] still exists. Capture clarify surfaces
  /// (standalone inbox-clarify, both ceremonies) load a snapshot of Inbox
  /// Captures and can lose a row between render and tap — sync or another
  /// device may hard-delete it. `captures` is a PowerSync VIEW, so a write's
  /// affected-rows count can't signal a missing row; callers pre-check here so
  /// they don't advance cursors or record phantom routings for a vanished
  /// Capture.
  Future<bool> captureExists(String captureId);

  /// Clarifies the Capture [captureId] into a **new** Outcome (ADR-0006:
  /// promotion is Outcome creation, not an in-place flip). In one transaction:
  ///
  /// 1. Creates a clarified `todos` Outcome from the clarify-card draft
  ///    (title / notes / energy / estimate / due), routed to [to].
  /// 2. Attaches the non-person [tagIds] the card carried into the draft (its
  ///    seeded tag hints plus any context/project edits) and, when [to] is
  ///    Waiting For, the [personTagIds] delegate set.
  /// 3. Links the Capture to the new Outcome (`capture_outcomes` provenance).
  /// 4. Stamps `captures.clarified_at` (1-1 mode: the first link completes the
  ///    clarify act).
  ///
  /// **Overwrite semantics.** A Capture re-routed after Ceremony Back → re-tap
  /// still carries the session Outcome carved by the earlier tap; that Outcome
  /// (and its link) is dropped and a fresh one created, so re-tapping a
  /// different destination never accumulates a second Outcome. Because
  /// Capture↔Outcome is many-to-many, the drop retracts only *this* Capture's
  /// claim: an Outcome another Capture still links to (a merge) is unlinked but
  /// never deleted.
  ///
  /// [userId] denormalises onto the Outcome, the provenance link, and any tag
  /// rows. [outcomeId] / [now] are injectable for deterministic testing.
  /// Returns the new Outcome id.
  Future<String> clarifyCaptureToOutcome(
    String captureId, {
    required RoutingKind to,
    required String userId,
    required String title,
    String? notes,
    String? energyLevel,
    int? timeEstimate,
    DateTime? dueDate,
    String? nextActionText,
    Set<String>? personTagIds,
    Set<String> tagIds = const {},
    String? outcomeId,
    DateTime? now,
  });

  /// Discards the Capture [captureId]: a zero-Outcome clarification (ADR-0006).
  /// Stamps `captures.clarified_at` and creates nothing. Any session Outcome a
  /// prior route of this Capture carved (Ceremony Back → Discard) is dropped
  /// with its link. The Capture persists as provenance of the discard; it does
  /// **not** surface on the Trash List, which remains about Outcomes.
  Future<void> discardCapture(String captureId, {DateTime? now});

  /// Whether the clarify subject still exists. Snapshot-based callsites
  /// (inbox-clarify, periodic review) can lose a row between render and
  /// tap — sync or another device may hard-delete it. PowerSync exposes
  /// `todos` as a SQLite VIEW with INSTEAD OF triggers, so the
  /// affected-rows count for an UPDATE is always 0 and the write itself
  /// can't signal a missing row; callers pre-check here so they don't
  /// advance cursors or record phantom routings for a vanished row.
  Future<bool> exists(String id);

  /// IDs of the person-typed tags currently attached to [id]. Used to
  /// pre-seed the Waiting For person picker inside the clarify flow.
  Future<Set<String>> getPersonTagIds(String id);

  /// Commits a routing verdict: the clarify subject leaves the flow in the
  /// state [to] expresses (see [TodoDao.applyRouting] for the exact
  /// clarified / intent / done_at column matrix). Stamps
  /// `last_clarified_at`.
  ///
  /// Serves both kinds of clarify surface — clarifying a Capture into an
  /// Outcome (inbox surfaces) and re-clarifying an existing Outcome
  /// (review surfaces). Under the conflated `todos` model both are the
  /// same write; the Phase 2/3 schema split gives Capture surfaces their
  /// own create-link-stamp path and leaves this routing write to Outcome
  /// surfaces.
  ///
  /// [personTagIds], when provided, replaces the person-tag set (requires
  /// [userId]); person tags are otherwise never touched — Intent is
  /// orthogonal to delegation.
  Future<void> clarifyToOutcome(
    String id, {
    required RoutingKind to,
    String? nextActionText,
    Set<String>? personTagIds,
    String? userId,
  });

  /// The in-place 1:1 clarify act used by the standalone inbox clarify
  /// screen: promotes the Capture at [id] to a clarified Outcome
  /// (promotion IS Outcome creation per ADR-0006), optionally setting
  /// [intent] / [dueDate]. Stamps `last_clarified_at`.
  ///
  /// Returns the number of affected rows (0 if already clarified or not
  /// found) so callers can guard against double-processing.
  Future<int> promoteCaptureToOutcome(
    String id, {
    String? intent,
    DateTime? dueDate,
  });

  /// Marks the Outcome achieved — stamps Completion (`done_at`) and
  /// `last_clarified_at`. Returns the number of affected rows.
  Future<int> completeOutcome(String id);

  /// The "Keep" / "still relevant" verdict: stamps `last_clarified_at`
  /// only, leaving every other column untouched.
  Future<void> stampClarified(String id);

  /// Persists attribute edits made on a clarify card (title / notes /
  /// energy / time estimate / due date). Passing `null` for a typed
  /// parameter means "no change"; use the matching `clear*` flag to null
  /// a column. Any non-no-op call stamps `last_clarified_at` (each edit
  /// is a clarifying micro-act per CONTEXT.md).
  Future<void> updateFields(
    String id, {
    String? title,
    String? notes,
    String? energyLevel,
    int? timeEstimate,
    DateTime? dueDate,
    bool clearNotes = false,
    bool clearEnergyLevel = false,
    bool clearTimeEstimate = false,
    bool clearDueDate = false,
  });
}

/// Concrete [ClarificationService] over the conflated `todos` schema:
/// every method delegates 1:1 to the existing [InboxDao] / [TodoDao]
/// writes, so behavior is byte-identical to the pre-service callsites.
class DaoClarificationService implements ClarificationService {
  DaoClarificationService(this._db);

  final GtdDatabase _db;

  @override
  Future<bool> captureExists(String captureId) async =>
      await _db.captureDao.getCapture(captureId) != null;

  @override
  Future<String> clarifyCaptureToOutcome(
    String captureId, {
    required RoutingKind to,
    required String userId,
    required String title,
    String? notes,
    String? energyLevel,
    int? timeEstimate,
    DateTime? dueDate,
    String? nextActionText,
    Set<String>? personTagIds,
    Set<String> tagIds = const {},
    String? outcomeId,
    DateTime? now,
  }) async {
    final id = outcomeId ?? uuid.v4();
    return _db.transaction(() async {
      // Require the Capture at commit time, inside the transaction: the
      // [captureExists] pre-check callers run can go stale (sync/another device
      // hard-deletes the row between snapshot and tap). Guarding here — not just
      // at the callsite — stops a vanished Capture from minting an orphan
      // Outcome and a dangling `capture_outcomes` link (a fatal FK violation on
      // Postgres). The throw rolls the whole transaction back.
      if (await _db.captureDao.getCapture(captureId) == null) {
        throw StateError('Capture $captureId not found');
      }
      // Overwrite: drop any Outcome a prior route of this Capture carved
      // (Ceremony Back → re-tap).
      await _dropOwnOutcomes(captureId);

      await _db.todoDao.insertOutcome(
        id: id,
        title: title,
        userId: userId,
        notes: notes,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
        dueDate: dueDate,
        now: now,
      );
      for (final tagId in tagIds) {
        await _db.tagDao.assignTag(id, tagId, userId);
      }
      await _db.todoDao.applyRouting(
        id,
        to: to,
        nextActionText: nextActionText,
        personTagIds: personTagIds,
        userId: personTagIds != null ? userId : null,
        now: now,
      );
      await _db.captureDao.linkOutcome(captureId, id, userId, at: now);
      await _db.captureDao.stampClarified(captureId, at: now);
      return id;
    });
  }

  @override
  Future<void> discardCapture(String captureId, {DateTime? now}) async {
    await _db.transaction(() async {
      // Require the Capture at commit time (see clarifyCaptureToOutcome): a
      // discard must not silently "succeed" against a row that already vanished.
      if (await _db.captureDao.getCapture(captureId) == null) {
        throw StateError('Capture $captureId not found');
      }
      await _dropOwnOutcomes(captureId);
      await _db.captureDao.stampClarified(captureId, at: now);
    });
  }

  /// Unlinks every Outcome [captureId] currently claims and deletes the ones
  /// left with **no other Capture** pointing at them.
  ///
  /// Capture↔Outcome is many-to-many: a merge (issue #184 Phase 3) links
  /// several Captures to one shared Outcome. Re-routing or discarding one of
  /// those Captures must retract only *its own* claim — hard-deleting a shared
  /// Outcome would destroy another Capture's clarified work (and cascade its
  /// provenance links away). So the delete is gated on the post-unlink link
  /// count: an Outcome nobody else claims was carved by this Capture alone and
  /// is safe to drop; a still-claimed one survives, merely unlinked.
  ///
  /// Callers must already be inside the write transaction.
  Future<void> _dropOwnOutcomes(String captureId) async {
    for (final oid in await _db.captureDao.outcomeIdsForCapture(captureId)) {
      await _db.captureDao.unlinkOutcome(captureId, oid);
      final stillClaimed = await _db.captureDao.captureIdsForOutcome(oid);
      if (stillClaimed.isEmpty) {
        await _db.todoDao.deleteOutcome(oid);
      }
    }
  }

  @override
  Future<bool> exists(String id) async => await _db.todoDao.getTodo(id) != null;

  @override
  Future<Set<String>> getPersonTagIds(String id) =>
      _db.todoDao.getPersonTagIdsForTodo(id);

  @override
  Future<void> clarifyToOutcome(
    String id, {
    required RoutingKind to,
    String? nextActionText,
    Set<String>? personTagIds,
    String? userId,
  }) =>
      _db.todoDao.applyRouting(
        id,
        to: to,
        nextActionText: nextActionText,
        personTagIds: personTagIds,
        userId: userId,
      );

  @override
  Future<int> promoteCaptureToOutcome(
    String id, {
    String? intent,
    DateTime? dueDate,
  }) =>
      _db.inboxDao.processInboxItem(id, intent: intent, dueDate: dueDate);

  @override
  Future<int> completeOutcome(String id) => _db.todoDao.markDone(id);

  @override
  Future<void> stampClarified(String id) =>
      _db.todoDao.stampLastClarifiedAt(id);

  @override
  Future<void> updateFields(
    String id, {
    String? title,
    String? notes,
    String? energyLevel,
    int? timeEstimate,
    DateTime? dueDate,
    bool clearNotes = false,
    bool clearEnergyLevel = false,
    bool clearTimeEstimate = false,
    bool clearDueDate = false,
  }) =>
      _db.todoDao.updateFields(
        id,
        title: title,
        notes: notes,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
        dueDate: dueDate,
        clearNotes: clearNotes,
        clearEnergyLevel: clearEnergyLevel,
        clearTimeEstimate: clearTimeEstimate,
        clearDueDate: clearDueDate,
      );
}

final clarificationServiceProvider = Provider<ClarificationService>(
  (ref) => DaoClarificationService(ref.watch(databaseProvider)),
);
