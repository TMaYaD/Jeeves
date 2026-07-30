/// Rebuild a fresh domain read model from the local op log.
///
/// The store cutover (ADR-0035) gives the device a brand-new
/// `jeeves_domain.sqlite` and deletes the PowerSync-era file rather than
/// converting it. For an **enrolled** device that is not a data loss: its op log
/// is the record, `jeeves_sync.sqlite` is a file of its own, and reduced state is
/// exactly what the domain read model is a projection of. So the new store is
/// replayed into, once — gated on the marker a completed replay writes rather than
/// on the store's own creation, so a replay that failed is retried on the next
/// launch (`database/domain_store_io.dart`).
///
/// Nothing new is computed here. The reduce already happened — this walks the
/// entities the substrate holds and drives them through the same
/// [DomainProjector] a pull batch does, which is idempotent on reduced state and
/// already handles create-vs-merge, the widened delete cascade and derived-id
/// realignment. A second run would produce the same rows.
///
/// A device that never enrolled has no log and gets an empty store; that is the
/// sanctioned path (fresh sign-up → enrolment → re-import), not a failure.
library;

import '../database/gtd_database.dart';
import 'domain_projector.dart';
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
  await DomainProjector(
    registry: CollectionRegistry(sync),
    domain: domain,
  ).project(entities);
  return entities.length;
}
