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
/// - **Outcome routing** — [clarifyToOutcome], [completeOutcome],
///   [completeCurrentAction], [stampClarified], [updateFields] (+ the
///   [exists] / [getPersonTagIds] guards). These operate on the conflated
///   `todos` row and back today's review + Inbox surfaces.
/// - **Capture clarification** (ADR-0006, the split model) —
///   [clarifyCaptureToOutcome], [discardCapture], [captureExists]. Clarifying a
///   Capture creates a *new* Outcome, links it (`capture_outcomes` provenance),
///   and stamps `captures.clarified_at`; discard is the zero-Outcome verdict.
///   This is the write path the Capture-split Inbox/clarify UI cutover will
///   use — a staged follow-up (see ARCHITECTURE.md); the methods are pinned by
///   tests ahead of their callsites.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../utils/uuid.dart';

import '../database/gtd_database.dart';
import '../models/action_draft.dart';
import '../models/todo.dart' show RoutingKind;
import '../providers/database_provider.dart';

/// Interface for every write the clarification UI flows perform, plus the
/// reads those flows need to guard their writes (row-existence pre-checks,
/// person-tag pre-seeding for the Waiting For picker).
abstract class ClarificationService {
  /// Whether the Capture [captureId] still exists. Capture clarify surfaces
  /// (standalone inbox-clarify, both ceremonies) load a snapshot of Inbox
  /// Captures and can lose a row between render and tap — a pull or another
  /// device may hard-delete it. The routing write is a multi-statement
  /// transaction whose affected-rows count cannot signal a missing subject;
  /// callers pre-check here so they don't advance cursors or record phantom
  /// routings for a vanished Capture.
  Future<bool> captureExists(String captureId);

  /// Clarifies the Capture [captureId] into a **new** Outcome (ADR-0006:
  /// promotion is Outcome creation, not an in-place flip). In one transaction:
  ///
  /// 1. Creates a clarified `todos` Outcome from the clarify-card draft
  ///    (title / notes / due), routed to [to], carrying [action]'s effort
  ///    values on its columns so the birth Action seeds from them (D3).
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
  /// **[to] must not be [RoutingKind.trash].** Routing a Capture to Trash is a
  /// zero-Outcome discard (ADR-0006): it stamps `clarified_at` and creates
  /// nothing, which is [discardCapture]'s job. Minting an Outcome only to mark
  /// it trashed would put a phantom row on the Trash List (a surface about
  /// Outcomes the user once cared about) and record a provenance link to work
  /// that was never done. Passing `trash` throws [ArgumentError].
  ///
  /// [action] describes the Action the card collected, or is null when it
  /// collected none. Its effort values are written to the Outcome's columns
  /// regardless of destination (draft storage, D3); its phrase reaches an
  /// Action row only on the Next / Waiting For arms, where
  /// [TodoDao.applyRouting] mints one that seeds from those columns.
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
    DateTime? dueDate,
    ActionDraft? action,
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

  /// Carves a **new** Outcome out of the Capture [captureId] without
  /// completing the clarify act — the split half of the n-m clarify surface.
  ///
  /// Creates the Outcome, applies the routing [to] the New Outcome form chose,
  /// attaches [tagIds] and [personTagIds], and links it to the Capture as
  /// provenance. Deliberately does **not** stamp `captures.clarified_at` and
  /// does **not** drop Outcomes an earlier carve produced: in n-m mode a
  /// Capture stays in the Inbox while several Outcomes accumulate against it,
  /// and only the user's explicit verdict ([completeCaptureClarification] /
  /// [discardCapture]) ends that (CONTEXT.md § GTD Core). This is exactly what
  /// separates it from [clarifyCaptureToOutcome], which is the 1-1 mode's
  /// create-link-stamp path and overwrites.
  ///
  /// [notes] and [dueDate] are Outcome attributes with no column on a Capture
  /// (ADR-0006), and [action] carries the Action grain. The n-m New Outcome
  /// form collects them exactly as the 1-1 card does, so they are written here
  /// or they are lost.
  ///
  /// Returns the new Outcome id.
  Future<String> carveOutcome(
    String captureId, {
    required String userId,
    required String title,
    RoutingKind? to,
    String? notes,
    DateTime? dueDate,
    ActionDraft? action,
    Set<String>? personTagIds,
    Set<String> tagIds = const {},
    String? outcomeId,
    DateTime? now,
  });

  /// Links the Capture [captureId] to the **existing** Outcome [outcomeId] —
  /// the merge half of the n-m clarify surface.
  ///
  /// Merge links, it never consumes: the Capture survives as provenance and
  /// the Outcome is untouched apart from gaining a link (CONTEXT.md § GTD
  /// Core). Idempotent, and — like [carveOutcome] — does not stamp
  /// `clarified_at`.
  Future<void> mergeIntoOutcome(
    String captureId,
    String outcomeId, {
    required String userId,
    DateTime? now,
  });

  /// Retracts this Capture's claim on [outcomeId].
  ///
  /// The link always goes. Whether the Outcome goes with it depends on where
  /// it came from, which only the clarify surface knows: [deleteCarved] is
  /// true for an Outcome carved during this clarify session (undoing the carve
  /// should leave nothing behind) and false for one that pre-existed it
  /// (merging was a link, so unmerging is a detach — the Outcome is the user's
  /// existing work and must survive).
  ///
  /// Even with [deleteCarved] the delete is gated on no *other* Capture
  /// claiming the Outcome, for the reason [_dropOwnOutcomes] documents.
  Future<void> unlinkOutcome(
    String captureId,
    String outcomeId, {
    required bool deleteCarved,
  });

  /// Completes the clarify act for [captureId], keeping every Outcome it has
  /// carved or merged into — the n-m surface's "Done with this Capture"
  /// verdict.
  ///
  /// Stamps `captures.clarified_at` and nothing else, so the Capture leaves
  /// the Inbox and persists as provenance for its Outcomes. The zero-Outcome
  /// counterpart is [discardCapture], which additionally drops anything the
  /// Capture still claims.
  Future<void> completeCaptureClarification(String captureId, {DateTime? now});

  /// Whether the clarify subject still exists. Snapshot-based callsites
  /// (inbox-clarify, periodic review) can lose a row between render and
  /// tap — a pull or another device may hard-delete it. The routing write is a
  /// multi-statement transaction whose affected-rows count cannot signal a
  /// missing subject; callers pre-check here so they don't advance cursors or
  /// record phantom routings for a vanished row.
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
    String? actionText,
    Set<String>? personTagIds,
    String? userId,
  });

  /// Marks the Outcome achieved — stamps Completion (`done_at`) and
  /// `last_clarified_at`. Returns the number of affected rows.
  Future<int> completeOutcome(String id);

  /// Records the Outcome's **current Action** as done, leaving the Outcome
  /// itself active and Actionless (ADR-0004: nothing is auto-promoted).
  ///
  /// Vocabulary tension worth naming: this is an *engagement* write, so unlike
  /// every other method on this seam it does **not** stamp
  /// `last_clarified_at` (CONTEXT.md § Clarification). It lives here anyway
  /// because it is the trigger of the re-clarification it feeds — the Focus
  /// "Done" flow completes the Action and then takes a verdict through
  /// [completeOutcome] / [clarifyToOutcome] / [stampClarified] on this same
  /// interface.
  Future<void> completeCurrentAction(String id);

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
/// every method delegates 1:1 to the existing [CaptureDao] / [TodoDao]
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
    DateTime? dueDate,
    ActionDraft? action,
    Set<String>? personTagIds,
    Set<String> tagIds = const {},
    String? outcomeId,
    DateTime? now,
  }) async {
    // Trash is not a destination an Outcome can be created into: it is the
    // zero-Outcome verdict (ADR-0006), handled by [discardCapture]. Reject
    // before anything is allocated so a miswired callsite fails loudly instead
    // of leaving a phantom trashed Outcome behind a real provenance link.
    if (to == RoutingKind.trash) {
      throw ArgumentError.value(
        to,
        'to',
        'Discarding a Capture creates no Outcome — call discardCapture instead',
      );
    }
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

      // Order is load-bearing: the effort values land on the Outcome columns
      // first, so the Action `applyRouting` may mint seeds itself from them
      // (D3). Reversed, the birth Action would seed from empty columns.
      await _db.todoDao.insertOutcome(
        id: id,
        title: title,
        userId: userId,
        notes: notes,
        energyLevel: action?.energyLevel,
        timeEstimate: action?.timeEstimateMinutes,
        dueDate: dueDate,
        now: now,
      );
      for (final tagId in tagIds) {
        await _db.tagDao.assignTag(id, tagId, userId);
      }
      await _db.todoDao.applyRouting(
        id,
        to: to,
        actionText: action?.text,
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
      await _retractClaim(captureId, oid, deleteIfOrphaned: true);
    }
  }

  /// Drops [captureId]'s claim on [outcomeId], and the Outcome with it when
  /// [deleteIfOrphaned] and no other Capture is left claiming it.
  ///
  /// The single implementation of the unlink → check-orphan → delete sequence
  /// that both [_dropOwnOutcomes] and [unlinkOutcome] need. Keeping it in one
  /// place is what stops the orphan gate — the thing preventing one Capture's
  /// retraction from destroying another's merged work — from being weakened on
  /// one path and not the other.
  ///
  /// Callers must already be inside the write transaction.
  Future<void> _retractClaim(
    String captureId,
    String outcomeId, {
    required bool deleteIfOrphaned,
  }) async {
    await _db.captureDao.unlinkOutcome(captureId, outcomeId);
    if (!deleteIfOrphaned) return;
    final stillClaimed = await _db.captureDao.captureIdsForOutcome(outcomeId);
    if (stillClaimed.isEmpty) {
      await _db.todoDao.deleteOutcome(outcomeId);
    }
  }

  @override
  Future<String> carveOutcome(
    String captureId, {
    required String userId,
    required String title,
    RoutingKind? to,
    String? notes,
    DateTime? dueDate,
    ActionDraft? action,
    Set<String>? personTagIds,
    Set<String> tagIds = const {},
    String? outcomeId,
    DateTime? now,
  }) async {
    final id = outcomeId ?? uuid.v4();
    return _db.transaction(() async {
      // Same commit-time guard as clarifyCaptureToOutcome: a Capture that
      // vanished between render and tap must not mint an orphan Outcome behind
      // a dangling link.
      if (await _db.captureDao.getCapture(captureId) == null) {
        throw StateError('Capture $captureId not found');
      }
      // Same load-bearing order as clarifyCaptureToOutcome: columns first so
      // the birth Action can seed from them (D3).
      await _db.todoDao.insertOutcome(
        id: id,
        title: title,
        userId: userId,
        notes: notes,
        energyLevel: action?.energyLevel,
        timeEstimate: action?.timeEstimateMinutes,
        dueDate: dueDate,
        now: now,
      );
      for (final tagId in tagIds) {
        await _db.tagDao.assignTag(id, tagId, userId);
      }
      if (to != null) {
        await _db.todoDao.applyRouting(
          id,
          to: to,
          actionText: action?.text,
          personTagIds: personTagIds,
          userId: personTagIds != null ? userId : null,
          now: now,
        );
      }
      await _db.captureDao.linkOutcome(captureId, id, userId, at: now);
      return id;
    });
  }

  @override
  Future<void> mergeIntoOutcome(
    String captureId,
    String outcomeId, {
    required String userId,
    DateTime? now,
  }) async {
    await _db.transaction(() async {
      if (await _db.captureDao.getCapture(captureId) == null) {
        throw StateError('Capture $captureId not found');
      }
      // The Outcome is the *other* side of a snapshot-driven pick, so it can
      // vanish the same way. Guard it too rather than writing a link whose FK
      // has no target.
      if (await _db.todoDao.getTodo(outcomeId) == null) {
        throw StateError('Outcome $outcomeId not found');
      }
      await _db.captureDao.linkOutcome(captureId, outcomeId, userId, at: now);
    });
  }

  @override
  Future<void> unlinkOutcome(
    String captureId,
    String outcomeId, {
    required bool deleteCarved,
  }) async {
    await _db.transaction(
      () => _retractClaim(captureId, outcomeId, deleteIfOrphaned: deleteCarved),
    );
  }

  @override
  Future<void> completeCaptureClarification(
    String captureId, {
    DateTime? now,
  }) async {
    await _db.transaction(() async {
      if (await _db.captureDao.getCapture(captureId) == null) {
        throw StateError('Capture $captureId not found');
      }
      await _db.captureDao.stampClarified(captureId, at: now);
    });
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
    String? actionText,
    Set<String>? personTagIds,
    String? userId,
  }) =>
      _db.todoDao.applyRouting(
        id,
        to: to,
        actionText: actionText,
        personTagIds: personTagIds,
        userId: userId,
      );

  @override
  Future<int> completeOutcome(String id) => _db.todoDao.markDone(id);

  @override
  Future<void> completeCurrentAction(String id) =>
      _db.actionDao.completeCurrentAction(id);

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
