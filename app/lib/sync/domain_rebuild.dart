/// Rebuild a fresh domain read model from the local op log.
///
/// The domain read model is a projection of reduced state (ADR-0035), so a store
/// that has never been projected into gets the walk once — gated on the marker a
/// completed replay writes rather than on the store's own creation, so a replay
/// that failed is retried on the next launch (`database/domain_store_io.dart`).
///
/// **This is not a recovery path and nothing may treat it as one.** It replays
/// what the local op log holds; a device with no log has nothing to replay, and
/// this compensates for no loss anywhere else.
///
/// Nothing new is computed here. The reduce already happened — this walks the
/// entities the substrate holds and drives them through the same
/// [DomainProjector] a pull batch does, which is idempotent on reduced state and
/// already handles create-vs-merge, the widened delete cascade and derived-id
/// realignment. A second run would produce the same rows.
///
/// It is also one of the two [DomainReconciler] sites, for the same reason it is a
/// projection site: a log that holds two same-`(name, type)` Tag entities projects
/// into two rows, and a device must not come out of a rebuild showing the user two
/// "Alice" entries. The reconcile runs on the tail, after the projection has
/// committed, because its passes author ops.
///
/// A device that never enrolled has no log, so this leaves its store exactly as
/// it found it. That is the ordinary case, not a failure: a local-only device's
/// data lives in the domain store itself and is never rebuilt from anywhere.
library;

import '../database/gtd_database.dart';
import 'domain_projector.dart';
import 'domain_reconciler.dart';
import 'reducer.dart';
import 'sync_database.dart';

/// Project every entity in [sync]'s reduced state into [domain], and return how
/// many were projected.
///
/// Returns 0 without touching [domain] when the log holds nothing — the ordinary
/// case on a device that has never synced.
Future<int> rebuildDomainFromOpLog({
  required SyncDatabase sync,
  required GtdDatabase domain,
}) async {
  final entities = await reducedEntities(sync);
  if (entities.isEmpty) return 0;
  // One registry for both: the reconciler's rehome pass reads the same reduced
  // state the projector does, and a second registry would be a second binding to
  // the same store for no gain.
  final registry = CollectionRegistry(sync);
  final touched = await DomainProjector(
    registry: registry,
    domain: domain,
  ).project(entities);
  await DomainReconciler(registry: registry, domain: domain)
      .reconcile(touched);
  return entities.length;
}
