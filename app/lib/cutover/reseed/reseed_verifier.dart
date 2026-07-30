/// Reduces the server log from zero and compares it with the legacy source.
///
/// **Cutover tooling — removed by #556.**
///
/// ## Why a scratch stack rather than a rebuild
///
/// The claim the cutover rests on is "the flip changes transport, not data", and
/// the only honest way to check it is to reduce **what the server holds** from
/// nothing. So the verification builds a throwaway stack — a fresh
/// [SyncDatabase], a scratch [SyncClient] carrying the *same* member identity and
/// member transport, the live device's Root pin copied in, a fresh [Reducer] with
/// the production strategy registry, and a [DomainProjector] into a scratch
/// [GtdDatabase] — and pulls it from cursor 0. That runs the entire production
/// receive pipeline: envelope verification, chain verdicts, control hydration,
/// the reducer guards, reduction, and projection including the derived-id
/// realignment and the held-back rule.
///
/// `rebuildFromOpLog()` on the live store was the obvious alternative and is
/// wrong twice over: it replays the *local* log, so it proves nothing about the
/// server, and it wipes and rebuilds live derived state as a side effect of a
/// verification.
///
/// The Root pin is **copied, not re-established by trust-on-first-use**: control
/// verification refuses every op without a pin, and TOFU here would make the
/// check weaker than the device it is checking.
///
/// ## What is compared, and what is not
///
/// Per table, both sides canonicalise through #582's encoder against the same
/// column manifest, so the timestamp grammar, the column order and the
/// anomaly-not-throw discipline are shared rather than re-derived. The comparison
/// is over the scratch stack's **reduced state**, not its domain rows: reduced
/// fields hold the canonical wire values verbatim, whereas Drift's default
/// `dateTime` storage is unix *seconds*, so a domain-row comparison would
/// manufacture sub-millisecond mismatches that say nothing about the data.
/// Projection is still exercised, and reports what it held back — an entity in
/// reduced state with no domain row.
library;

import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnectionUser;

import '../../database/gtd_database.dart';
import '../../sync/collection_codecs.dart';
import '../../sync/domain_projector.dart';
import '../../sync/hlc.dart';
import '../../sync/member_identity.dart';
import '../../sync/merge_strategy.dart';
import '../../sync/reducer.dart';
import '../../sync/sync_client.dart';
import '../../sync/sync_database.dart';
import '../../sync/sync_transport.dart';
import '../converge_verify/canonical_row.dart';
import '../../sync/initial_upload_plan.dart';

/// One throwaway verification stack, for one Workspace.
class ReseedScratchStack {
  ReseedScratchStack({
    required this.workspaceId,
    required this.syncDatabase,
    required this.domain,
    required this.client,
    required this.registry,
  });

  final String workspaceId;
  final SyncDatabase syncDatabase;
  final GtdDatabase domain;
  final SyncClient client;
  final CollectionRegistry registry;

  /// Both stores, in the order that leaves nothing writing into a closed one —
  /// and both of them regardless: this is the only cleanup path (the runner calls
  /// it from `finally`), so a throw from the first close would otherwise leave the
  /// op-log store open for the life of the process.
  Future<void> close() async {
    try {
      await domain.close();
    } finally {
      await syncDatabase.close();
    }
  }
}

/// Builds the stack for one Workspace. The stores are injected because opening a
/// native database is platform code and this library has to stay compilable
/// everywhere the app is — see `reseed_scratch_store.dart`.
typedef ReseedScratchStackFactory = Future<ReseedScratchStack> Function(
    String workspaceId);

/// Assemble a scratch stack over already-opened stores.
///
/// [identity] and [clock] are the live device's, per the enrolment provider: the
/// scratch client has to be the *same* Member — that is what makes the pulled ops
/// its own writes rather than a stranger's, and what lets the chain verdicts mean
/// anything. Nothing is authored here, so sharing the clock costs only an HLC
/// observation.
///
/// The scratch [GtdDatabase] deliberately keeps the default
/// `NoopDomainOpCapture`: a capture seam wired back to a client would tee the
/// projector's own writes into an outbox, which is the opposite of a read model.
Future<ReseedScratchStack> assembleReseedScratchStack({
  required String workspaceId,
  required String userId,
  required MemberIdentity identity,
  required HlcClock clock,
  required int Function() nowMs,
  required SyncTransport transport,
  required Uint8List pinnedRootPk,
  required int escrowVersion,
  required SyncDatabase syncDatabase,
  required GtdDatabase domain,
  MergeStrategyRegistry strategies = const MergeStrategyRegistry(),
}) async {
  final registry = CollectionRegistry(syncDatabase);
  final client = SyncClient(
    workspaceId: workspaceId,
    userId: userId,
    identity: identity,
    database: syncDatabase,
    clock: clock,
    reducer: Reducer(syncDatabase, nowMs: nowMs, strategies: strategies),
    transport: transport,
    now: () => DateTime.fromMillisecondsSinceEpoch(nowMs(), isUtc: true),
  );
  client.projector = DomainProjector(registry: registry, domain: domain);
  await client.pinRoot(pinnedRootPk, escrowVersion);
  for (final collection in collectionCodecs.keys) {
    registry.register(collection);
  }
  return ReseedScratchStack(
    workspaceId: workspaceId,
    syncDatabase: syncDatabase,
    domain: domain,
    client: client,
    registry: registry,
  );
}

// --- per-table comparison ---------------------------------------------------

/// One table's reading of "the reduced state equals the source".
class ReseedTableDiff {
  const ReseedTableDiff({
    required this.table,
    required this.plannedCount,
    required this.reducedCount,
    required this.projectedRowCount,
    required this.onlyInLegacyIds,
    required this.onlyInReducedIds,
    required this.mismatchedIds,
    required this.heldBackIds,
    required this.legacyAnomalies,
    required this.reducedAnomalies,
  });

  final String table;

  /// Entities the plan asserted — the transformed legacy store's own count.
  final int plannedCount;

  /// Entities the scratch stack reduced from the server log.
  final int reducedCount;

  /// Rows the scratch projector actually materialised.
  final int projectedRowCount;

  /// Planned, and the server log does not reduce to it: an op that never landed,
  /// or one `capture()` refused.
  final List<String> onlyInLegacyIds;

  /// Reduced, and the plan never asserted it: state from something other than
  /// this legacy store.
  final List<String> onlyInReducedIds;

  /// Same entity id, different canonical row.
  final List<String> mismatchedIds;

  /// Reduced but not projected — required columns unsatisfied.
  final List<String> heldBackIds;

  final List<InitialUploadAnomaly> legacyAnomalies;
  final List<InitialUploadAnomaly> reducedAnomalies;

  /// #582's rule, kept verbatim: an anomaly means this row's digest does not
  /// carry that column's content, so "equal digests" would be a weaker claim than
  /// it looks. A held-back entity is not converged either — the row the user will
  /// read is not there.
  bool get converged =>
      onlyInLegacyIds.isEmpty &&
      onlyInReducedIds.isEmpty &&
      mismatchedIds.isEmpty &&
      heldBackIds.isEmpty &&
      legacyAnomalies.isEmpty &&
      reducedAnomalies.isEmpty;

  /// Held-back entities are counted too. They are one of the things that makes
  /// [converged] false, so leaving them out let the screen read
  /// "— 0 difference(s)" beside a red table.
  int get differenceCount =>
      onlyInLegacyIds.length +
      onlyInReducedIds.length +
      mismatchedIds.length +
      heldBackIds.length;

  Map<String, Object?> toJson() => {
        'converged': converged,
        'planned_count': plannedCount,
        'reduced_count': reducedCount,
        'projected_row_count': projectedRowCount,
        'only_in_legacy_ids': onlyInLegacyIds,
        'only_in_reduced_ids': onlyInReducedIds,
        'mismatched_ids': mismatchedIds,
        'held_back_ids': heldBackIds,
        'legacy_anomalies': [
          for (final anomaly in legacyAnomalies) anomaly.toJson(),
        ],
        'reduced_anomalies': [
          for (final anomaly in reducedAnomalies) anomaly.toJson(),
        ],
      };
}

/// The canonical row for one entity: the sync row identifier plus its fields.
///
/// `id` is supplied rather than read out of the fields, which is what carries the
/// junction and preference derivations into the comparison on both sides — the
/// same realignment the projector performs on the domain row.
Map<String, Object?> reseedCanonicalInput(
  String entityId,
  Map<String, Object?> fields,
) =>
    {'id': entityId, ...fields};

/// Compare the plan against what one scratch stack reduced.
///
/// [collections] is the subset of the twelve this stack's Workspace carries, so
/// the preferences stack is not asked about `todos` and vice versa.
Future<List<ReseedTableDiff>> compareReducedStateWithPlan({
  required InitialUploadPlan plan,
  required ReseedScratchStack stack,
  required List<String> collections,
}) async {
  final diffs = <ReseedTableDiff>[];
  for (final collection in collections) {
    final planned = <String, Map<String, Object?>>{
      for (final entity in plan.entitiesFor(collection))
        entity.entityId: entity.fields,
    };
    final reduced = await stack.registry.view(collection).readAll();
    final projectedIds = await _projectedRowIds(stack.domain, collection);

    final legacyAnomalies = <InitialUploadAnomaly>[];
    final reducedAnomalies = <InitialUploadAnomaly>[];
    final legacyDigests = <String, String>{};
    final reducedDigests = <String, String>{};

    for (final entry in planned.entries) {
      final row = canonicalRow(
        collection,
        reseedCanonicalInput(entry.key, entry.value),
      );
      legacyDigests[entry.key] = row.digest;
      for (final anomaly in row.anomalies) {
        legacyAnomalies.add(InitialUploadAnomaly(
          table: collection,
          kind: anomaly.kind,
          rowId: entry.key,
          column: anomaly.column,
          raw: anomaly.raw,
        ));
      }
    }
    for (final entry in reduced.entries) {
      final row = canonicalRow(
        collection,
        reseedCanonicalInput(entry.key, entry.value),
      );
      reducedDigests[entry.key] = row.digest;
      for (final anomaly in row.anomalies) {
        reducedAnomalies.add(InitialUploadAnomaly(
          table: collection,
          kind: anomaly.kind,
          rowId: entry.key,
          column: anomaly.column,
          raw: anomaly.raw,
        ));
      }
    }

    final onlyInLegacy = <String>[];
    final mismatched = <String>[];
    for (final entry in legacyDigests.entries) {
      final reducedDigest = reducedDigests[entry.key];
      if (reducedDigest == null) {
        onlyInLegacy.add(entry.key);
      } else if (reducedDigest != entry.value) {
        mismatched.add(entry.key);
      }
    }
    // Entities the plan vouches for without re-asserting — a Label an earlier
    // reseed minted for a converted Area — are not "state the source does not
    // have"; see `InitialUploadPlan.endorsedEntityIdsByCollection`.
    final endorsed =
        plan.endorsedEntityIdsByCollection[collection] ?? const <String>{};
    final onlyInReduced = [
      for (final id in reducedDigests.keys)
        if (!legacyDigests.containsKey(id) && !endorsed.contains(id)) id,
    ];
    final heldBack = [
      for (final id in reducedDigests.keys)
        if (!projectedIds.contains(id)) id,
    ];
    for (final id in heldBack) {
      reducedAnomalies.add(InitialUploadAnomaly(
        table: collection,
        kind: projectionHeldBack,
        rowId: id,
      ));
    }

    diffs.add(ReseedTableDiff(
      table: collection,
      plannedCount: planned.length,
      reducedCount: reduced.length,
      projectedRowCount: projectedIds.length,
      onlyInLegacyIds: onlyInLegacy..sort(),
      onlyInReducedIds: onlyInReduced..sort(),
      mismatchedIds: mismatched..sort(),
      heldBackIds: heldBack..sort(),
      legacyAnomalies: legacyAnomalies,
      reducedAnomalies: reducedAnomalies,
    ));
  }
  return diffs;
}

/// The sync row identifiers the projector materialised.
///
/// `id` and not the domain key, on purpose: the projector writes the entity id
/// into `id` on every row it touches, including the two collections whose domain
/// key is not their `id` column — so this is exactly "did this entity become a
/// row".
Future<Set<String>> _projectedRowIds(
  DatabaseConnectionUser domain,
  String table,
) async {
  final rows = await domain.customSelect('SELECT "id" FROM "$table"').get();
  return {
    for (final row in rows)
      if (row.data['id'] case final String id) id,
  };
}

/// The collections each Workspace carries.
List<String> reseedCollectionsFor(InitialUploadWorkspace workspace) => [
      for (final collection in initialUploadCollectionOrder)
        if ((collection == userPreferencesCollection) ==
            (workspace == InitialUploadWorkspace.preferences))
          collection,
    ];
