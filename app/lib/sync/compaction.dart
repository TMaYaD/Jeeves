/// Entity-level compaction: the mechanism, and the policy that picks its work.
///
/// A compaction pass authors two ops back to back — a class-4 snapshot of one
/// entity's joined state, and a class-5 prune enumerating the ops that snapshot
/// supersedes — through [SyncClient.captureCompaction] and
/// [SyncClient.capturePrune]. Both go through the ordinary authoring lock, so the
/// snapshot always takes the earlier `author_seq` and the outbox flusher (which
/// uploads in `author_seq` order) always presents compaction-before-prune. The
/// server's ordered batch walk makes that pair legal inside one POST and equally
/// legal split across two.
///
/// **Who compacts in v1: the owner device, itself.** The role matrix has admitted
/// `{owner, compactor}` for classes 4 and 5 since #549, so nothing is minted and
/// nothing is enrolled — a future dedicated compactor Member gets a `compactor`
/// Grant and reuses every line of this unchanged.
///
/// **The snapshot is the join, or it is nothing.** The preconditions below are the
/// reason it can be trusted: a device that is not caught up would snapshot a
/// partial join, and one with a standing integrity alarm would snapshot state it
/// has itself accused. Both are refused rather than approximated.
///
/// Two exemptions are structural rather than policy. Control ops are never targets
/// — compacting one away would delete the evidence a Grant existed — and prune ops
/// are never targets, because a prune *is* the attestation that history was removed
/// and pruning it would destroy what distinguishes garbage collection from a server
/// that truncated the log. [SyncClient.loggedOpsForEntity] cannot return either,
/// and the server refuses them too.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import 'envelope.dart';
import 'hlc.dart';
import 'op_payload.dart';
import 'prune_payload.dart';
import 'reducer.dart' show AffectedEntity;
import 'sync_client.dart';
import 'sync_database.dart';

/// not tunable per call: how many live ops an entity must carry before compacting
/// it is worth an op of its own. Below this the snapshot plus the prune cost more
/// chain slots than they reclaim.
const int compactionThresholdLiveOps = 20;

/// not tunable per call: how recently an entity may have been written to and still
/// be compacted.
///
/// The grace window is how the pass protects stragglers — a device that has been
/// offline for a day still holds ops whose peers are about to be pruned, and its
/// edits merge correctly either way but its *chain* verification is easier if the
/// history is still there. It is also what keeps compaction out of a reseed's way
/// by construction: a freshly reseeded log is all young, so nothing in it is a
/// candidate until it ages past this.
const Duration pruneGraceWindow = Duration(days: 3);

/// Why a compaction pass refused to run.
enum CompactionBlocker {
  /// The outbox is not drained, or this device has never completed a pull. Either
  /// way the reduced state is not the join of everything, so a snapshot of it would
  /// be a snapshot of a partial history.
  notCaughtUp,

  /// An integrity accusation still stands. Snapshotting state this device has
  /// itself accused would launder the accusation into a signed op.
  unresolvedIntegrityAlarm,

  /// Fewer than [compactionThresholdLiveOps] compactable ops for the entity.
  tooFewLiveOps,

  /// The entity has no reduced state at all — nothing to snapshot.
  nothingToCompact,
}

/// A compaction pass that declined to author anything.
///
/// Fail-closed and named: every blocker is a state the caller can do something
/// about (sync, resolve the alarm, wait), and a silent no-op would leave a policy
/// sweep unable to tell "not yet" from "done".
class CompactionBlocked implements Exception {
  const CompactionBlocked(this.blocker, this.message);

  final CompactionBlocker blocker;
  final String message;

  @override
  String toString() => 'CompactionBlocked(${blocker.name}): $message';
}

/// What one [Compactor.compactEntity] authored.
class CompactionResult {
  const CompactionResult({
    required this.compactionOpId,
    required this.pruneOpId,
    required this.prunedOpCount,
  });

  final String compactionOpId;
  final String pruneOpId;

  /// How many ops the prune attested — the history a fresh device will not replay.
  final int prunedOpCount;
}

class Compactor {
  Compactor({
    required SyncClient client,
    required SyncDatabase database,
    this.thresholdLiveOps = compactionThresholdLiveOps,
    this.pruneGrace = pruneGraceWindow,
    DateTime Function()? now,
  })  : _client = client,
        _db = database,
        _now = now ?? DateTime.now;

  final SyncClient _client;
  final SyncDatabase _db;
  final DateTime Function() _now;

  final int thresholdLiveOps;
  final Duration pruneGrace;

  /// Snapshot one entity and prune the ops the snapshot supersedes.
  ///
  /// The snapshot re-asserts `(joined value, winning clock)` per field, read from
  /// `reduced_fields`, `field_clocks` and `row_tombstones` — which *are* the join of
  /// the entity's ops under ADR-0030's semilattice laws. That is what makes merging
  /// it absorption rather than a fresh write: a pending edit at an older clock loses
  /// exactly as it would have lost against the original op, one at a newer clock
  /// wins exactly as it would have won, and an equal clock is an idempotent skip.
  Future<CompactionResult> compactEntity({
    required String collection,
    required String entityId,
  }) async {
    await _requireCaughtUp();
    final snapshot = await _snapshotOf(collection, entityId);
    final targets = await _targetsFor(collection: collection, entityId: entityId);
    if (targets.length < thresholdLiveOps) {
      throw CompactionBlocked(
        CompactionBlocker.tooFewLiveOps,
        '$collection/$entityId has ${targets.length} compactable op(s), below the '
        'threshold of $thresholdLiveOps',
      );
    }

    // Awaited in order, so the snapshot takes the earlier `author_seq` and the
    // flusher presents the pair compaction-before-prune. Two un-awaited authors
    // would fork this device's own chain, which is what the authoring lock exists
    // to prevent — awaiting is how a caller cooperates with it.
    final compactionOpId = await _client.captureCompaction(snapshot);
    final pruneOpId = await _client.capturePrune(PrunePayload(
      compactionOpId: compactionOpId,
      targets: targets,
    ));
    return CompactionResult(
      compactionOpId: compactionOpId,
      pruneOpId: pruneOpId,
      prunedOpCount: targets.length,
    );
  }

  /// Entities worth compacting: over the threshold, and quiet for long enough.
  ///
  /// The grace window is applied to the entity as a whole rather than per op — a
  /// recently-active entity is left alone entirely. That protects the same
  /// stragglers a compact-now/prune-later split would, and it avoids a
  /// "compactions pending prune" state machine nobody has asked for.
  Future<List<AffectedEntity>> compactionCandidates() async {
    final cutoff = _now().subtract(pruneGrace);
    final rows = await (_db.select(_db.reducedFields)).get();
    final entities = {
      for (final row in rows) (collection: row.collection, entityId: row.entityId),
    };
    final attested = await _attestedPositions();
    final candidates = <AffectedEntity>[];
    for (final entity in entities) {
      final ops = await _compactableOps(
        collection: entity.collection,
        entityId: entity.entityId,
        attested: attested,
      );
      if (ops.length < thresholdLiveOps) continue;
      final newest = await _newestReceivedAt([for (final op in ops) op.seq]);
      if (newest == null || newest.isAfter(cutoff)) continue;
      candidates.add(entity);
    }
    return candidates;
  }

  /// Outbox drained, a pull completed, and nothing standing accused.
  Future<void> _requireCaughtUp() async {
    final health = await _client.health();
    if (health.pendingOpCount > 0 || health.lastSyncedAt == null) {
      throw CompactionBlocked(
        CompactionBlocker.notCaughtUp,
        'the snapshot must be the join of everything, and this device has '
        '${health.pendingOpCount} unsent op(s)'
        '${health.lastSyncedAt == null ? ' and has never completed a pull' : ''}',
      );
    }
    if (health.unresolvedAlarmCount > 0) {
      throw CompactionBlocked(
        CompactionBlocker.unresolvedIntegrityAlarm,
        'refusing to snapshot state this device has itself accused: '
        '${health.alarmKinds.toList()..sort()}',
      );
    }
  }

  /// The entity's joined state, at the clocks that won it.
  Future<OpPayload> _snapshotOf(String collection, String entityId) async {
    final fields = await (_db.select(_db.reducedFields)
          ..where((row) =>
              row.collection.equals(collection) & row.entityId.equals(entityId)))
        .get();
    final clocks = {
      for (final row in await (_db.select(_db.fieldClocks)
            ..where((row) =>
                row.collection.equals(collection) & row.entityId.equals(entityId)))
          .get())
        row.field: Hlc(row.wallMs, row.counter, row.memberIdHex),
    };
    final tombstone = await (_db.select(_db.rowTombstones)
          ..where((row) =>
              row.collection.equals(collection) & row.entityId.equals(entityId)))
        .getSingleOrNull();
    if (fields.isEmpty && tombstone == null) {
      throw CompactionBlocked(
        CompactionBlocker.nothingToCompact,
        '$collection/$entityId holds no reduced state to snapshot',
      );
    }

    final writes = <String, FieldWrite>{};
    for (final row in fields) {
      final clock = clocks[row.field];
      if (clock == null) {
        // A reduced field with no clock is impossible — the reducer writes both in
        // one transaction — and it is refused rather than defaulted, because the
        // op-level clock is precisely the wrong answer.
        throw CompactionBlocked(
          CompactionBlocker.nothingToCompact,
          'field "${row.field}" of $collection/$entityId has a value and no clock',
        );
      }
      writes[row.field] = FieldWrite(_decodeStoredValue(row.valueJson), hlc: clock);
    }
    return OpPayload(
      collection: collection,
      entityId: entityId,
      // The compactor's *own* clock at the op level: it is what `guardPayload`
      // checks, and F15 exempts the per-field clocks precisely so they can be older
      // and belong to somebody else.
      hlc: _client.clock.send(),
      fields: writes,
      tombstone: tombstone != null,
      tombstoneHlc: tombstone == null
          ? null
          : Hlc(tombstone.wallMs, tombstone.counter, tombstone.memberIdHex),
    );
  }

  /// The ops this pass will attest, as prune targets.
  Future<List<PruneTarget>> _targetsFor({
    required String collection,
    required String entityId,
  }) async {
    final ops = await _compactableOps(
      collection: collection,
      entityId: entityId,
      attested: await _attestedPositions(),
    );
    return [
      for (final op in ops)
        PruneTarget(
          seq: op.seq,
          authorMemberId: op.authorMemberId,
          authorSeq: op.authorSeq,
          envelopeHash: envelopeHash(op.envelope),
        ),
    ];
  }

  /// One entity's ops that are still legal, unattested targets.
  ///
  /// Classes 1 and 4 only. Class 3 will need a "resolved" filter when #557 ships
  /// suggestion ops — an unresolved suggestion is not superseded by a snapshot of
  /// the state it proposes changing — and this is the one place that filter goes.
  /// Until then no class-3 op exists and [SyncClient.loggedOpsForEntity] returns
  /// none, so the omission is a named seam rather than a silent gap.
  Future<List<LoggedEntityOp>> _compactableOps({
    required String collection,
    required String entityId,
    required Set<String> attested,
  }) async {
    final ops = await _client.loggedOpsForEntity(
      collection: collection,
      entityId: entityId,
    );
    return [
      for (final op in ops)
        if (!attested.contains('${op.authorMemberId}/${op.authorSeq}')) op,
    ];
  }

  /// Positions a prune has already attested, so a pass never proposes one twice.
  Future<Set<String>> _attestedPositions() async => {
        for (final row in await _client.prunedAttestations())
          '${row.authorMemberId}/${row.authorSeq}',
      };

  /// When the newest of these ops arrived — the grace window's input.
  ///
  /// `op_log.received_at` is this device's own clock at the moment it received the
  /// op, which is the honest reading for "has this entity been quiet": it is a fact
  /// about *this* device's view, and the pass is a decision this device makes.
  Future<DateTime?> _newestReceivedAt(List<int> seqs) async {
    if (seqs.isEmpty) return null;
    final rows = await (_db.select(_db.opLog)
          ..where((row) => row.seq.isIn(seqs))
          ..orderBy([
            (row) => OrderingTerm(expression: row.receivedAt, mode: OrderingMode.desc),
          ])
          ..limit(1))
        .get();
    return rows.isEmpty ? null : rows.first.receivedAt;
  }

  /// A stored `value_json` back as the value the op carried.
  ///
  /// The reduced store keeps values as their JSON encoding, and the snapshot has to
  /// carry the *value*: re-encoding a string that already holds JSON would double
  /// it, and a field that came out of a peer's op would come back out of this one
  /// looking different.
  Object? _decodeStoredValue(String valueJson) => jsonDecode(valueJson);
}
