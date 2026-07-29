/// The reseed report: the verdict, the evidence, and the archival JSON.
///
/// **Cutover tooling — removed by #556.**
///
/// This is #553 Phase 2's acceptance artifact — the thing the user copies off the
/// phone and pastes into the issue — so it is deliberately over-explicit: every
/// declared exclusion, every conversion, every anomaly and the read-only proof
/// are all in it, and the verdict is derived from them rather than stored
/// alongside them.
library;

import '../converge_verify/canonical_row.dart' show excludedColumnsReport;
import '../converge_verify/converge_differ.dart' show ReadOnlyProof;
import 'reseed_plan.dart';
import 'reseed_uploader.dart';
import 'reseed_verifier.dart';

/// What has to be true before "reduced state equals the source" means anything.
class ReseedPreconditions {
  const ReseedPreconditions({
    required this.enrolled,
    required this.rootPinned,
    required this.pulledBeforeAuthoring,
    required this.pendingOpCountAfterFlush,
  });

  /// Both Workspace clients hold a member credential. Without one there is
  /// nothing to author through and nothing to pull with.
  final bool enrolled;

  /// A Root is pinned, so the scratch stack can verify control ops at all.
  final bool rootPinned;

  /// The run pulled before it authored. Without it a device whose sync store was
  /// rebuilt would diff against emptiness and re-author the whole store.
  final bool pulledBeforeAuthoring;

  /// Outbox rows still unsent after the final flush, summed over both
  /// Workspaces. Non-zero means the server does not hold everything the reseed
  /// authored, so a converged verdict would be about the wrong log.
  final int pendingOpCountAfterFlush;

  bool get satisfied =>
      enrolled &&
      rootPinned &&
      pulledBeforeAuthoring &&
      pendingOpCountAfterFlush == 0;

  Map<String, Object?> toJson() => {
        'enrolled': enrolled,
        'root_pinned': rootPinned,
        'pulled_before_authoring': pulledBeforeAuthoring,
        'pending_op_count_after_flush': pendingOpCountAfterFlush,
        'satisfied': satisfied,
      };
}

enum ReseedVerdict {
  /// Every table's transformed-legacy set is the reduced-from-zero set, both
  /// Workspaces, and every legacy row was carried.
  reseededAndConverged,

  /// The tables converge, but the plan could not carry every legacy row — a
  /// required column was NULL, or a value no codec accepts. What is on the spine
  /// is faithful; it is not *complete*, and the report names what is missing.
  partiallyReseeded,

  /// A table's id sets or digests differ.
  diverged,

  /// The device cannot run this — not enrolled, no Root pinned on one of the two
  /// Workspaces — or the run never got as far as pulling and comparing, so there
  /// is no reading to report at all.
  notEnrolled,

  /// Ops are still queued after the final flush, so the server does not hold
  /// what was authored. Nothing is claimed about the data.
  uploadIncomplete,

  /// The legacy store or PowerSync's upload queue changed during the run. The
  /// tool is not trustworthy in this state and says so instead of reporting a
  /// verdict about the data.
  readOnlyProofFailed,
}

/// One reseed run, end to end.
class ReseedOutcome {
  const ReseedOutcome({
    required this.verdict,
    required this.plan,
    required this.upload,
    required this.tables,
    required this.readOnlyProof,
    required this.preconditions,
  });

  final ReseedVerdict verdict;
  final ReseedPlan plan;

  /// Null when the run never got as far as authoring.
  final ReseedUploadReport? upload;

  /// Both Workspaces' tables, in [reseedCollectionOrder].
  final List<ReseedTableDiff> tables;

  /// Read-only *on the legacy side*: the store the reseed reads and must not
  /// touch. The new spine is written on purpose, so it is not in the proof.
  final ReadOnlyProof readOnlyProof;

  final ReseedPreconditions preconditions;

  bool get converged => verdict == ReseedVerdict.reseededAndConverged;

  List<ReseedTableDiff> get divergedTables =>
      [for (final table in tables) if (!table.converged) table];

  /// Every anomaly the run produced, plan and upload and verification alike, in
  /// one list — the screen renders this and nothing has to remember to look in
  /// three places.
  List<ReseedAnomaly> get anomalies => [
        ...plan.anomalies,
        ...?upload?.anomalies,
        for (final table in tables) ...table.legacyAnomalies,
        for (final table in tables) ...table.reducedAnomalies,
      ];

  Map<String, Object?> toJson() => {
        'verdict': verdict.name,
        'preconditions': preconditions.toJson(),
        'read_only_proof': {
          'legacy_digest_before': readOnlyProof.localDigestBefore,
          'legacy_digest_after': readOnlyProof.localDigestAfter,
          'powersync_upload_queue_count_before':
              readOnlyProof.uploadQueueCountBefore,
          'powersync_upload_queue_count_after':
              readOnlyProof.uploadQueueCountAfter,
          'unchanged': readOnlyProof.unchanged,
        },
        'declared_exclusions': reseedDeclaredExclusions,
        'excluded_columns': excludedColumnsReport(),
        'plan': plan.toJson(),
        'upload': upload?.toJson(),
        'tables': {
          for (final table in tables) table.table: table.toJson(),
        },
      };
}

/// What the comparison deliberately does not claim, in the report so a reviewer
/// sees the judgment calls rather than having to infer them.
const Map<String, String> reseedDeclaredExclusions = {
  'user_id': 'stamped with the enrolled account on every op rather than copied: '
      'a legacy row stranded under the "local" placeholder belongs to this User, '
      'and the stamping is itself the declaration',
  'todos.time_spent_minutes': 'a dead device-local cache, never on the wire '
      '(ADR-0030); the projector supplies the column default on insert',
  'sync_dead_letters': 'Drift-local PowerSync infrastructure, not a domain '
      'table — never walked',
  'junction and user_preferences id columns':
      'compared under their derivation (todoTagIdFor and siblings, '
      'preferenceEntityId); a legacy random id is declared as realigned, which '
      'is the same correction the domain projector applies',
  'surplus todo_tags rows (ADR-0025)':
      'not excluded but transformed — every conversion is enumerated in '
      'plan.area_exclusivity.resolutions',
};

/// Worst-news-first, exactly as converge-verify orders its own: a fault in the
/// tool outranks a fault in the device, which outranks an unmet premise, which
/// outranks a divergence the premise would have explained anyway.
ReseedVerdict reseedVerdictFor({
  required ReseedPreconditions preconditions,
  required ReadOnlyProof readOnlyProof,
  required ReseedPlan plan,
  required List<ReseedTableDiff> tables,
}) {
  if (!readOnlyProof.unchanged) return ReseedVerdict.readOnlyProofFailed;
  if (!preconditions.enrolled || !preconditions.rootPinned) {
    return ReseedVerdict.notEnrolled;
  }
  if (preconditions.pendingOpCountAfterFlush > 0) {
    return ReseedVerdict.uploadIncomplete;
  }
  // The premise, gated here rather than trusted from the caller: without the pull
  // the diff skip measured emptiness, and `tables.any` is vacuously false over an
  // empty list — so the strongest verdict in the acceptance artifact would
  // otherwise be reachable from a run that compared nothing.
  if (!preconditions.pulledBeforeAuthoring || tables.isEmpty) {
    return ReseedVerdict.notEnrolled;
  }
  if (tables.any((table) => !table.converged)) return ReseedVerdict.diverged;
  if (plan.excludedRowCount > 0) return ReseedVerdict.partiallyReseeded;
  return ReseedVerdict.reseededAndConverged;
}
