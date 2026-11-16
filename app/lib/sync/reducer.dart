/// Field-grain last-write-wins reduction over the op log.
///
/// The rules, all pinned by `spec/sync/reducer_v1_vectors.json`:
///
/// - A field applies iff its HLC is strictly greater than the stored one. Equal
///   HLCs are an idempotent skip, which is also what makes a pulled echo of the
///   device's own op a no-op.
/// - A field's HLC is its own when it carries one, else the op-level HLC. The
///   same rule applies one level up to a tombstone, whose `tombstone_hlc` a
///   compaction op carries so a compacted deletion is re-asserted at the clock it
///   was made at rather than the compactor's.
/// - Deletion is a tombstone op with its own HLC. Visibility is decided at read
///   time — a field newer than the tombstone is live and revives the entity, a
///   field older stays hidden. Nothing is deleted, so reduction is
///   order-independent in both directions.
/// - **The guards are scoped to the op-level HLC only** (review F15, as ruled
///   for this slice). Per-field HLCs are exempt: a compaction op (#555)
///   legitimately re-asserts *other authors'* older clocks per field, and
///   checking those would make compaction impossible. The exemption is *from
///   the guards, not from LWW* — a re-asserted older clock still loses.
/// - LWW is the *default* rule, not the only one. A field may be governed by a
///   non-LWW [FieldMergeStrategy] — the Conflict Strategy registry rides
///   here — and every such strategy must be a join-semilattice so reduction
///   stays order-independent (ADR-0030).
/// - **Which** strategy arbitrates is read from the op and nothing else. A
///   `user_preferences` write names the `key` that selects its lattice or it is
///   refused (`preference_value_without_key`, ADR-0033), so reduction consults no
///   stored state to pick a strategy and selection is order-independent
///   structurally rather than by policy.
library;

import 'host/change.dart';
import 'host/merge_core.dart';
import 'host/merge_state.dart';
import 'merge_strategy.dart';
import 'op_payload.dart';
import 'sync_database.dart';
import 'sync_rejection.dart';

export 'host/merge_state.dart';

/// How far ahead of local time an op-level `wall_ms` may be before the op is
/// quarantined. Without a bound, any member could pin a field against every
/// future edit by writing a clock in 2099 (review F15).
const int defaultFutureSkewBoundMs = 5 * 60 * 1000;

class Reducer {
  Reducer(
    SyncDatabase db, {
    required int Function() nowMs,
    this.futureSkewBoundMs = defaultFutureSkewBoundMs,
    this.strategies = const MergeStrategyRegistry(),
  })  : _nowMs = nowMs,
        _core = MergeCore(db, strategies: strategies);

  final MergeCore _core;
  final int Function() _nowMs;
  final int futureSkewBoundMs;

  /// Which [FieldMergeStrategy] governs each field. The default is the Conflict
  /// Strategy registry's adapter; every collection but `user_preferences` resolves to LWW.
  final MergeStrategyRegistry strategies;

  /// The op → [Change] conversion: a field's HLC is its own when it carries one,
  /// else the op-level HLC, and a tombstone applies at its effective clock.
  static Change toChange(OpPayload payload) => Change(
        collection: payload.collection,
        entityId: payload.entityId,
        fields: {
          for (final entry in payload.fields.entries)
            entry.key: ClockedValue(
                entry.value.value, entry.value.hlc ?? payload.hlc),
        },
        tombstone:
            payload.tombstone ? payload.effectiveTombstoneHlc : null,
      );

  /// Apply [payload], or throw [SyncRejection] so the caller quarantines it.
  ///
  /// The op-level guards run first; the merge itself is the sync host's
  /// [MergeCore]. Returns the entities this op touched. `SyncClient` accumulates
  /// them over a pull batch and hands them to the domain projector once the batch
  /// is applied — projection hangs off the tail of the receive order, after apply.
  Future<Set<AffectedEntity>> apply(
    OpPayload payload, {
    required String authorMemberIdHex,
  }) async {
    guardPayload(payload, authorMemberIdHex: authorMemberIdHex);
    return _core.apply(toChange(payload));
  }

  /// The refusals that read no reduced state — the op, its header author and
  /// local wall time are the whole input, so the verdict does not depend on what
  /// this device has already applied.
  ///
  /// Public because `SyncClient.capture` runs it *before* authoring, on the same
  /// [Reducer] instance the receive path uses: one function rather than a second
  /// author-side copy free to disagree with it, and a payload every peer would
  /// refuse is never signed into the outbox (the divergence class #573 closes).
  /// Stateful verdicts — chain position, grants, the epoch floor — stay where
  /// they are and are deliberately not here.
  void guardPayload(
    OpPayload payload, {
    required String authorMemberIdHex,
  }) {
    if (payload.hlc.wallMs > _nowMs() + futureSkewBoundMs) {
      throw SyncRejection(
        SyncRejectionReason.hlcInTheFuture,
        'op wall_ms ${payload.hlc.wallMs} is beyond the '
        '${futureSkewBoundMs}ms skew bound',
      );
    }
    if (payload.hlc.memberIdHex != authorMemberIdHex) {
      throw SyncRejection(
        SyncRejectionReason.hlcMemberIsNotAuthor,
        'op hlc member ${payload.hlc.memberIdHex} is not the header author '
        '$authorMemberIdHex',
      );
    }
    _core.guard(toChange(payload));
  }
}
