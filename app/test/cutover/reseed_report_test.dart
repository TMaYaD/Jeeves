/// The verdict table as a pure function, and the archival report's shape.
///
/// **Cutover tooling — removed by #556.**
///
/// The ordering is worst-news-first, and it is asserted directly rather than
/// through seven staged runs: a fault in the tool has to outrank a fault in the
/// device, which has to outrank an unmet premise, which has to outrank a
/// divergence the premise would have explained anyway.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/cutover/converge_verify/converge_differ.dart'
    show ReadOnlyProof;
import 'package:jeeves/cutover/reseed/reseed_plan.dart';
import 'package:jeeves/cutover/reseed/reseed_report.dart';
import 'package:jeeves/cutover/reseed/reseed_uploader.dart';
import 'package:jeeves/cutover/reseed/reseed_verifier.dart';
import 'package:jeeves/sync/collection_codecs.dart';

const _proofUnchanged = ReadOnlyProof(
  localDigestBefore: 'a',
  localDigestAfter: 'a',
  uploadQueueCountBefore: 0,
  uploadQueueCountAfter: 0,
);

const _proofChanged = ReadOnlyProof(
  localDigestBefore: 'a',
  localDigestAfter: 'b',
  uploadQueueCountBefore: 0,
  uploadQueueCountAfter: 0,
);

const _clean = ReseedPreconditions(
  enrolled: true,
  rootPinned: true,
  pulledBeforeAuthoring: true,
  pendingOpCountAfterFlush: 0,
);

ReseedPlan _plan({Map<String, List<String>> excluded = const {}}) => ReseedPlan(
      entities: const [],
      resolutions: const [],
      anomalies: const [],
      legacyRowCountByTable: const {'todos': 1},
      excludedRowIdsByTable: excluded,
      endorsedEntityIdsByCollection: const {},
    );

ReseedTableDiff _table({List<String> mismatched = const []}) =>
    ReseedTableDiff(
      table: todosCollection,
      plannedCount: 1,
      reducedCount: 1,
      projectedRowCount: 1,
      onlyInLegacyIds: const [],
      onlyInReducedIds: const [],
      mismatchedIds: mismatched,
      heldBackIds: const [],
      legacyAnomalies: const [],
      reducedAnomalies: const [],
    );

void main() {
  group('reseedVerdictFor', () {
    test('converged when every table agrees and every row was carried', () {
      expect(
        reseedVerdictFor(
          preconditions: _clean,
          readOnlyProof: _proofUnchanged,
          plan: _plan(),
          tables: [_table()],
        ),
        ReseedVerdict.reseededAndConverged,
      );
    });

    test('partially reseeded when a legacy row could not be carried', () {
      expect(
        reseedVerdictFor(
          preconditions: _clean,
          readOnlyProof: _proofUnchanged,
          plan: _plan(excluded: const {'todos': ['untitled']}),
          tables: [_table()],
        ),
        ReseedVerdict.partiallyReseeded,
      );
    });

    test('diverged outranks a row left behind', () {
      // A table that disagrees is the more serious claim: it says what *did*
      // reach the spine is not the source.
      expect(
        reseedVerdictFor(
          preconditions: _clean,
          readOnlyProof: _proofUnchanged,
          plan: _plan(excluded: const {'todos': ['untitled']}),
          tables: [_table(mismatched: const ['entity-a'])],
        ),
        ReseedVerdict.diverged,
      );
    });

    test('a pending outbox outranks a divergence it would explain', () {
      expect(
        reseedVerdictFor(
          preconditions: const ReseedPreconditions(
            enrolled: true,
            rootPinned: true,
            pulledBeforeAuthoring: true,
            pendingOpCountAfterFlush: 3,
          ),
          readOnlyProof: _proofUnchanged,
          plan: _plan(),
          tables: [_table(mismatched: const ['entity-a'])],
        ),
        ReseedVerdict.uploadIncomplete,
      );
    });

    test('an un-enrolled device outranks a pending outbox', () {
      expect(
        reseedVerdictFor(
          preconditions: const ReseedPreconditions(
            enrolled: false,
            rootPinned: false,
            pulledBeforeAuthoring: false,
            pendingOpCountAfterFlush: 3,
          ),
          readOnlyProof: _proofUnchanged,
          plan: _plan(),
          tables: const [],
        ),
        ReseedVerdict.notEnrolled,
      );
    });

    test('a run that never pulled cannot report a reading', () {
      // The premise the whole comparison rests on. Without the pull the diff skip
      // measured emptiness, and `tables.any` is vacuously false over an empty
      // list — so this must not be the strongest verdict on the strength of the
      // caller happening to set `enrolled` too.
      expect(
        reseedVerdictFor(
          preconditions: const ReseedPreconditions(
            enrolled: true,
            rootPinned: true,
            pulledBeforeAuthoring: false,
            pendingOpCountAfterFlush: 0,
          ),
          readOnlyProof: _proofUnchanged,
          plan: _plan(),
          tables: const [],
        ),
        ReseedVerdict.notEnrolled,
      );
    });

    test('no tables is no reading, whatever the preconditions say', () {
      expect(
        reseedVerdictFor(
          preconditions: _clean,
          readOnlyProof: _proofUnchanged,
          plan: _plan(),
          tables: const [],
        ),
        ReseedVerdict.notEnrolled,
      );
    });

    test('a failed read-only proof outranks everything', () {
      expect(
        reseedVerdictFor(
          preconditions: const ReseedPreconditions(
            enrolled: false,
            rootPinned: false,
            pulledBeforeAuthoring: false,
            pendingOpCountAfterFlush: 9,
          ),
          readOnlyProof: _proofChanged,
          plan: _plan(excluded: const {'todos': ['untitled']}),
          tables: [_table(mismatched: const ['entity-a'])],
        ),
        ReseedVerdict.readOnlyProofFailed,
      );
    });

    test('an unknown PowerSync queue count still proves it did not change', () {
      // Null is "no engine attached", which is not zero — but two nulls are
      // still two readings of the same unknown, and the digests carry the claim.
      expect(
        const ReadOnlyProof(
          localDigestBefore: 'a',
          localDigestAfter: 'a',
          uploadQueueCountBefore: null,
          uploadQueueCountAfter: null,
        ).unchanged,
        isTrue,
      );
    });
  });

  group('ReseedOutcome', () {
    test('publishes the declared exclusions and survives a JSON round trip',
        () {
      final outcome = ReseedOutcome(
        verdict: ReseedVerdict.reseededAndConverged,
        plan: _plan(),
        upload: const ReseedUploadReport(
          plannedEntityCount: 1,
          authoredOpCount: 1,
          skippedEntityCount: 0,
          reassertedEntityCount: 0,
          refusedEntityCount: 0,
          anomalies: [],
        ),
        tables: [_table()],
        readOnlyProof: _proofUnchanged,
        preconditions: _clean,
      );
      final json =
          jsonDecode(jsonEncode(outcome.toJson())) as Map<String, dynamic>;

      expect(json['verdict'], 'reseededAndConverged');
      // Every judgment call named, so a reviewer sees them rather than inferring
      // them from the code.
      final exclusions = json['declared_exclusions'] as Map<String, dynamic>;
      expect(
        exclusions.keys,
        containsAll([
          'user_id',
          'todos.time_spent_minutes',
          'sync_dead_letters',
          'surplus todo_tags rows (ADR-0025)',
        ]),
      );
      expect(json['preconditions']['satisfied'], isTrue);
      expect(json['tables'][todosCollection]['converged'], isTrue);
      expect(json['upload']['authored_op_count'], 1);
    });

    test('gathers plan, upload and verification anomalies into one list', () {
      final outcome = ReseedOutcome(
        verdict: ReseedVerdict.diverged,
        plan: ReseedPlan(
          entities: const [],
          resolutions: const [],
          anomalies: const [
            ReseedAnomaly(
              table: todosCollection,
              kind: nullRequiredColumn,
              column: 'title',
            ),
          ],
          legacyRowCountByTable: const {},
          excludedRowIdsByTable: const {},
          endorsedEntityIdsByCollection: const {},
        ),
        upload: const ReseedUploadReport(
          plannedEntityCount: 1,
          authoredOpCount: 0,
          skippedEntityCount: 0,
          reassertedEntityCount: 0,
          refusedEntityCount: 1,
          anomalies: [
            ReseedAnomaly(table: todosCollection, kind: uploadRefused),
          ],
        ),
        tables: [
          ReseedTableDiff(
            table: todosCollection,
            plannedCount: 1,
            reducedCount: 1,
            projectedRowCount: 0,
            onlyInLegacyIds: const [],
            onlyInReducedIds: const [],
            mismatchedIds: const [],
            heldBackIds: const ['entity-a'],
            legacyAnomalies: const [],
            reducedAnomalies: const [
              ReseedAnomaly(table: todosCollection, kind: projectionHeldBack),
            ],
          ),
        ],
        readOnlyProof: _proofUnchanged,
        preconditions: _clean,
      );
      expect(
        outcome.anomalies.map((anomaly) => anomaly.kind),
        containsAll([nullRequiredColumn, uploadRefused, projectionHeldBack]),
      );
      expect(outcome.divergedTables, hasLength(1));
    });
  });
}
