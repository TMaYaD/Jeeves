/// Authors the initial-upload plan through the production capture path.
///
/// **Permanent sync-layer machinery.** The trigger is enrolment
/// (`sync_lifecycle.dart`), not a button: a device that becomes enrolled with
/// local data already in it authors that data into the log, and a device that was
/// interrupted resumes on its next sync.
///
/// Nothing here is a second write path: every entity goes through
/// `SyncClient.capture`, so the codecs, the receive-codec round trip, the
/// author-side guards (#573, ADR-0033), the HLC, the signature, the outbox and
/// the local reduce are all exactly the ones every other write uses. The
/// uploader's only job is deciding *what* to capture and *when to stop*.
///
/// ## Idempotence is decided by reading the target, not by remembering the run
///
/// Op ids stay what the protocol says they are — a random UUIDv4 per authored op.
/// A deterministic op id would be actively wrong: `op_id` travels inside a signed
/// header alongside `author_seq`, `prev_author_hash` and the payload's HLC, and a
/// re-run structurally cannot reproduce those, so a derived id would claim an
/// already-spent `(workspace, author, op_id)` slot and every peer would read the
/// differing envelope as a rewrite.
///
/// Instead the skip is a diff against the spine's reduced state, which is
/// airtight because `capture()` reduces locally *before* it returns: there is no
/// window in which an authored entity is invisible to the check. A pass therefore
/// requires a pull first, so a device whose sync store was rebuilt diffs against
/// reality rather than emptiness. On a second device that pull has already
/// projected the first device's data into the domain store, so the walk over a
/// projector-fed store is self-cancelling — every entity's planned fields are
/// already the reduced values and the whole pass skips.
///
/// **Only the planned fields are compared** (see [plannedFieldsAlreadyReduced]).
/// Comparing the whole reduced field set would re-author every entity that
/// carries one extra field from any other source, and the `skipped` counter would
/// be a lie.
///
/// A restart does not fork the author chain: `_authorAndQueue` reads the head
/// from the persisted `author_state` row and every capture goes through the one
/// serialised authoring tail. (The only path that re-derives a head from the log
/// is the superseded-genesis rewind, which an upload never reaches.)
///
/// No tombstones are authored. The upload asserts what exists; absence from the
/// domain store is "never authored", not "deleted".
library;

import 'dart:convert';

import 'envelope.dart' show SyncRejection;
import 'initial_upload_plan.dart';
import 'sync_client.dart';

/// How many captures to author between `flushOutbox()` calls.
///
/// Not configurable: `flushOutbox` already chunks its POSTs at
/// `maxOpsPerBatch`, so this is not a wire concern — it only bounds how much an
/// interrupted run leaves un-posted, and the diff skip makes the retry free
/// either way. One value, chosen to match the flush chunk so a full batch goes
/// out at a time.
const int initialUploadFlushEveryOpCount = 1000;

/// How many entities to walk between [InitialUploadProgress] emissions.
///
/// Coarse on purpose: an emission is a `setState` on whatever observes the walk,
/// and a store with thousands of `todos` does not need one rebuild per row. Fine
/// enough that the counters visibly advance, which is the whole reason they
/// exist.
const int initialUploadProgressEveryEntityCount = 100;

/// Where the upload has got to, for a progress line.
class InitialUploadProgress {
  const InitialUploadProgress({
    required this.collection,
    required this.completedEntityCount,
    required this.plannedEntityCount,
    required this.authoredOpCount,
    required this.skippedEntityCount,
  });

  final String collection;
  final int completedEntityCount;
  final int plannedEntityCount;
  final int authoredOpCount;
  final int skippedEntityCount;

  String get summaryLine =>
      'Authoring $collection — $completedEntityCount/$plannedEntityCount '
      '($authoredOpCount authored, $skippedEntityCount already present)';
}

/// What one upload pass did.
class InitialUploadReport {
  const InitialUploadReport({
    required this.plannedEntityCount,
    required this.authoredOpCount,
    required this.skippedEntityCount,
    required this.reassertedEntityCount,
    required this.refusedEntityCount,
    required this.anomalies,
  });

  final int plannedEntityCount;

  /// Ops this pass signed and queued.
  final int authoredOpCount;

  /// Entities whose planned fields the spine already held — an interrupted run's
  /// completed work, or a re-run with nothing to do.
  final int skippedEntityCount;

  /// Entities that already existed and were authored again because the legacy
  /// row had changed. Field-grain LWW converges every device on the re-asserted
  /// values; the earlier op stays in the log as history.
  final int reassertedEntityCount;

  /// Entities `capture()` refused. The store, the outbox and the author chain
  /// are untouched by design (#573), so the entity simply never lands — and the
  /// verification then shows it as `only_in_legacy`, which is the honest state.
  final int refusedEntityCount;

  final List<InitialUploadAnomaly> anomalies;

  Map<String, Object?> toJson() => {
        'planned_entity_count': plannedEntityCount,
        'authored_op_count': authoredOpCount,
        'skipped_entity_count': skippedEntityCount,
        'reasserted_entity_count': reassertedEntityCount,
        'refused_entity_count': refusedEntityCount,
        'anomalies': [for (final anomaly in anomalies) anomaly.toJson()],
      };
}

/// Whether every field the plan would author is already the reduced value.
///
/// The comparison is over `jsonEncode`, which is the reducer's own stored
/// encoding (`reduced_fields.value_json`), so it is a fixed point rather than a
/// structural comparison that could disagree with what is on disk. Field kinds
/// are scalar-only, so the encoding is canonical for these values.
///
/// **The null convention, spelled out:** a planned null is a real assertion and
/// must be *present and null* in reduced state to count as already-authored — a
/// missing field is not a match. Reduced fields the plan does not mention are
/// ignored entirely; they belong to whatever else wrote them.
bool plannedFieldsAlreadyReduced(
  Map<String, Object?> plannedFields,
  Map<String, Object?>? reducedFields,
) {
  if (reducedFields == null) return false;
  for (final entry in plannedFields.entries) {
    if (!reducedFields.containsKey(entry.key)) return false;
    if (jsonEncode(reducedFields[entry.key]) != jsonEncode(entry.value)) {
      return false;
    }
  }
  return true;
}

/// Author every entity in [plan] that the spine does not already hold.
///
/// [readReducedCollection] is read once per collection: the diff needs the whole
/// collection's reduced state anyway, and one read beats one query per entity on a
/// store with thousands of rows.
///
/// A transport failure during a flush propagates. That is deliberate — the outbox
/// is intact by contract, the entities already authored are in reduced state, and
/// the next run skips them. Hiding the failure would leave the user believing the
/// server holds ops it has never seen.
Future<InitialUploadReport> runInitialUpload({
  required InitialUploadPlan plan,
  required SyncClient gtdClient,
  required SyncClient preferencesClient,
  required ReducedCollectionReader readReducedCollection,
  void Function(InitialUploadProgress)? onProgress,
  int flushEveryOpCount = initialUploadFlushEveryOpCount,
  int progressEveryEntityCount = initialUploadProgressEveryEntityCount,
}) async {
  var authored = 0;
  var skipped = 0;
  var reasserted = 0;
  var refused = 0;
  var completed = 0;
  final anomalies = <InitialUploadAnomaly>[];

  var authoredSinceFlush = 0;

  Future<void> flush() async {
    authoredSinceFlush = 0;
    await gtdClient.flushOutbox();
    await preferencesClient.flushOutbox();
  }

  for (final collection in initialUploadCollectionOrder) {
    final entities = plan.entitiesFor(collection).toList();
    if (entities.isEmpty) continue;
    final reduced = await readReducedCollection(collection);

    // Emitted at the head of the collection and then *inside* the walk: the
    // counters are what a progress line is for, and a collection holding
    // thousands of entities would otherwise show its starting values for the
    // whole pass.
    void reportProgress() => onProgress?.call(InitialUploadProgress(
          collection: collection,
          completedEntityCount: completed,
          plannedEntityCount: plan.entities.length,
          authoredOpCount: authored,
          skippedEntityCount: skipped,
        ));
    reportProgress();

    for (final entity in entities) {
      completed++;
      final existing = reduced[entity.entityId];
      if (plannedFieldsAlreadyReduced(entity.fields, existing)) {
        skipped++;
        continue;
      }
      final client = entity.workspace == InitialUploadWorkspace.preferences
          ? preferencesClient
          : gtdClient;
      try {
        await client.capture(
          collection: entity.collection,
          entityId: entity.entityId,
          fields: entity.fields,
        );
        authored++;
        authoredSinceFlush++;
        if (existing != null) reasserted++;
      } on SyncRejection catch (rejection) {
        refused++;
        anomalies.add(InitialUploadAnomaly(
          table: entity.collection,
          kind: uploadRefused,
          rowId: entity.entityId,
          raw: '${rejection.reason.code}: ${rejection.message}',
        ));
      }
      if (authoredSinceFlush >= flushEveryOpCount) await flush();
      if (completed % progressEveryEntityCount == 0) reportProgress();
    }
  }

  // The tail, and the only flush a small store ever reaches.
  await flush();

  return InitialUploadReport(
    plannedEntityCount: plan.entities.length,
    authoredOpCount: authored,
    skippedEntityCount: skipped,
    reassertedEntityCount: reasserted,
    refusedEntityCount: refused,
    anomalies: anomalies,
  );
}
