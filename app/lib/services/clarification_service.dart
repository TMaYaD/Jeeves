/// Single write path for the clarification flow (issue #184, Phase 0).
///
/// Consolidates the clarify-flow DB writes previously spread across
/// [ProcessToHandlers], [InboxClarifyScreen], and
/// [FocusSessionPlanningNotifier] behind one interface, per the issue #184
/// reversibility directive: nothing outside this service may bake "Inbox is
/// just a Todo with `clarified = false`" into a load-bearing assumption.
/// When the Capture/Outcome schema split lands (`captures` +
/// `capture_outcomes` tables, ADR-0006), only [DaoClarificationService]
/// changes — callsites keep speaking this interface.
///
/// Vocabulary is CONTEXT.md's: methods speak Capture and Outcome even
/// though the current implementation still writes the conflated `todos`
/// row. In the conflated model, clarifying a Capture and re-clarifying an
/// existing Outcome are the same UPDATE; the split makes them distinct
/// (Capture clarify creates + links an Outcome and stamps `clarified_at`).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../models/todo.dart' show RoutingKind;
import '../providers/database_provider.dart';

/// Interface for every write the clarification UI flows perform, plus the
/// reads those flows need to guard their writes (row-existence pre-checks,
/// person-tag pre-seeding for the Waiting For picker).
abstract class ClarificationService {
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
        clearEnergyLevel: clearEnergyLevel,
        clearTimeEstimate: clearTimeEstimate,
        clearDueDate: clearDueDate,
      );
}

final clarificationServiceProvider = Provider<ClarificationService>(
  (ref) => DaoClarificationService(ref.watch(databaseProvider)),
);
