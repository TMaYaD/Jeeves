/// The decision vocabulary: which decisions each standing condition may be
/// given, and the columns that record one.
///
/// The table below is the whole of it, written out rather than derived. A
/// derived table would be the implementation checking itself, and the claim
/// under test is exactly the table: that each kind offers one decision, or
/// none because a filed issue stands for it.
@TestOn('!browser')
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/alarm_resolution.dart';
import 'package:jeeves/sync/chain_verifier.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_rejection.dart';

import 'harness/resolution_columns.dart';

/// Every alarm kind, and the decisions it may be given.
///
/// A kind with **no** decision has a filed issue standing for it, and the
/// issue is where the work is:
///
/// * `own_write_refused_permanently` — #647
/// * `epoch_key_set_unpublishable` — #661
/// * `author_stream_reordered` — #656
/// * `stale_prefix_served` — #657
/// * `control_chain_fork` — #658
/// * `author_chain_slot_collision` — #659
/// * `prune_attestation_divergence` — #660
const Map<IntegrityAlarmKind, List<AlarmResolution>> _decisionsByKind = {
  // --- the server's chain is the one to keep ------------------------------
  IntegrityAlarmKind.authorChainGap: [AlarmResolution.tookUpstream],

  // --- this device's chain is the one to keep ----------------------------
  IntegrityAlarmKind.ownWritesRollback: [AlarmResolution.keptOurs],
  IntegrityAlarmKind.ownWritesDivergence: [AlarmResolution.keptOurs],

  // --- the condition is permanent; the User ends it -----------------------
  IntegrityAlarmKind.authorChainFork: [AlarmResolution.rejectedPermanently],
  IntegrityAlarmKind.prevAuthorHashMismatch: [
    AlarmResolution.rejectedPermanently
  ],
  IntegrityAlarmKind.authorChainRewrite: [AlarmResolution.rejectedPermanently],
  IntegrityAlarmKind.duplicateOpIdDivergence: [
    AlarmResolution.rejectedPermanently
  ],
  IntegrityAlarmKind.signatureInvalid: [AlarmResolution.rejectedPermanently],
  IntegrityAlarmKind.aeadFailure: [AlarmResolution.rejectedPermanently],
  IntegrityAlarmKind.plaintextAtEncryptedEpoch: [
    AlarmResolution.rejectedPermanently
  ],
  IntegrityAlarmKind.noLiveGrant: [AlarmResolution.rejectedPermanently],

  // --- nothing to decide: the condition closes by mechanism ---------------
  IntegrityAlarmKind.ownWriteRefusedPermanently: [],
  IntegrityAlarmKind.epochKeySetUnpublishable: [],
  IntegrityAlarmKind.authorStreamReordered: [],
  IntegrityAlarmKind.stalePrefixServed: [],
  IntegrityAlarmKind.controlChainFork: [],
  IntegrityAlarmKind.authorChainSlotCollision: [],
  IntegrityAlarmKind.pruneAttestationDivergence: [],
};

/// A row of the shape the decision functions read. The drift row is named
/// rather than reduced to loose arguments so that the call sites in later
/// steps are the same call.
IntegrityAlarmRow _alarmRow({
  required String kind,
  String? resolution,
  int? repostFromAuthorSeq,
}) =>
    IntegrityAlarmRow(
      id: 1,
      workspaceId: 'workspace-1',
      kind: kind,
      detail: 'a thing happened',
      occurrenceCount: 1,
      firstDetectedAt: DateTime.utc(2026, 8, 1),
      lastDetectedAt: DateTime.utc(2026, 8, 1),
      resolution: resolution,
      repostFromAuthorSeq: repostFromAuthorSeq,
    );

void main() {
  group('the decision each condition may be given', () {
    test('every kind offers exactly the decisions the table gives it', () {
      expect(
        _decisionsByKind.keys.toSet(),
        IntegrityAlarmKind.values.toSet(),
        reason: 'a kind added without a decision or a filed issue is a condition '
            'the User can do nothing about and is told nothing about',
      );
      for (final kind in IntegrityAlarmKind.values) {
        expect(
          resolutionsForAlarm(kind),
          _decisionsByKind[kind],
          reason: '$kind',
        );
      }
    });

    test('the kinds with no decision are the ones with a filed issue', () {
      expect(
        IntegrityAlarmKind.values.where((kind) => _decisionsByKind[kind]!.isEmpty),
        unorderedEquals([
          IntegrityAlarmKind.ownWriteRefusedPermanently,
          IntegrityAlarmKind.epochKeySetUnpublishable,
          IntegrityAlarmKind.authorStreamReordered,
          IntegrityAlarmKind.stalePrefixServed,
          IntegrityAlarmKind.controlChainFork,
          IntegrityAlarmKind.authorChainSlotCollision,
          IntegrityAlarmKind.pruneAttestationDivergence,
        ]),
      );
    });

    test('an unknown code offers nothing and throws nothing', () {
      // A store written by a build that knew codes this one does not must not
      // make a reader fail.
      expect(resolutionsForAlarmCode('from_the_future'), isEmpty);
      expect(resolutionsForRefusalCode('from_the_future'), isEmpty);
    });

    test('a refusal offers a decision only when nothing else offers one', () {
      // A codec or certificate refusal that will still be there tomorrow, and
      // that no alarm carries: the User's is to end.
      expect(
        resolutionsForRefusalCode(SyncRejectionReason.unsupportedSuite.code),
        [AlarmResolution.rejectedPermanently],
      );
      expect(
        resolutionsForRefusalCode(SyncRejectionReason.certMemberMismatch.code),
        [AlarmResolution.rejectedPermanently],
      );
      // A delivery gap heals by itself and needs no decision.
      expect(
        resolutionsForRefusalCode(SyncRejectionReason.missingEpochKey.code),
        isEmpty,
      );
      // A refusal that escalates is settled on the alarm that carries it.
      expect(
        resolutionsForRefusalCode(SyncRejectionReason.badSignature.code),
        isEmpty,
      );
    });

    test('a decision is stored under a code that reads back', () {
      for (final resolution in AlarmResolution.values) {
        expect(alarmResolutionByCodeOrNull(resolution.code), resolution);
      }
      expect(alarmResolutionByCodeOrNull('from_the_future'), isNull);
    });
  });

  group('the decisions a row may still be given', () {
    test('a decided row is offered nothing', () {
      expect(
        resolutionsOfferedForAlarmRow(_alarmRow(
          kind: IntegrityAlarmKind.authorChainGap.code,
          resolution: AlarmResolution.tookUpstream.code,
        )),
        isEmpty,
      );
    });

    test('the rollback offers keep-ours only when there is a position to repost from', () {
      // The server lost a write it had acknowledged: the agreed position is
      // known, so keeping this device's work is a decision the User can take.
      expect(
        resolutionsOfferedForAlarmRow(_alarmRow(
          kind: IntegrityAlarmKind.ownWritesRollback.code,
          repostFromAuthorSeq: 12,
        )),
        [AlarmResolution.keptOurs],
      );
      // The server holds a position this device never wrote: there is no agreed
      // position to repost from, so there is nothing to offer — and no filed
      // issue for it either (#974).
      expect(
        resolutionsOfferedForAlarmRow(_alarmRow(
          kind: IntegrityAlarmKind.ownWritesRollback.code,
        )),
        isEmpty,
      );
    });

    test('a row of an unknown kind is offered nothing', () {
      expect(
        resolutionsOfferedForAlarmRow(_alarmRow(kind: 'from_the_future')),
        isEmpty,
      );
    });
  });

  group('the store', () {
    test('a v11 sync store upgrades to the current version and keeps every row',
        () async {
      final directory = Directory.systemTemp.createTempSync('sync-v11-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/sync.sqlite');

      final seed = SyncDatabase(NativeDatabase(file));
      // Take the columns v14 and v15 brought back out, and the tables v12 and
      // v16 brought, so the file on disk is what a v11 store held.
      await seed.customStatement('DROP TABLE unauthored_changes');
      await dropColumnsAddedAfter(seed, 11);
      await seed.customStatement(
        'INSERT INTO integrity_alarms (workspace_id, kind, detail, '
        'occurrence_count, first_detected_at, last_detected_at) '
        "VALUES ('workspace-1', 'own_writes_rollback', 'the server lost a write', "
        "1, '2026-08-01T00:00:00.000Z', '2026-08-01T00:00:00.000Z')",
      );
      await seed.customStatement(
        'INSERT INTO quarantined_ops (workspace_id, reason, detail, envelope, '
        "detected_at) VALUES ('workspace-1', 'bad_signature', 'forged', X'', "
        "'2026-08-01T00:00:00.000Z')",
      );
      await seed.customStatement('PRAGMA user_version = 11');
      await seed.close();

      final upgraded = SyncDatabase(NativeDatabase(file));
      addTearDown(upgraded.close);
      expect(upgraded.schemaVersion, SyncDatabase.supportedSchemaVersion);

      final alarm = await upgraded.select(upgraded.integrityAlarms).getSingle();
      expect(alarm.kind, IntegrityAlarmKind.ownWritesRollback.code);
      expect(alarm.detail, 'the server lost a write');
      expect(alarm.occurrenceCount, 1);
      expect(
        alarm.resolution,
        isNull,
        reason: 'nothing was decided before the decision existed',
      );
      expect(alarm.resolutionDecidedAt, isNull);
      expect(alarm.repostFromAuthorSeq, isNull);

      final quarantine = await upgraded.select(upgraded.quarantinedOps).getSingle();
      expect(quarantine.reason, SyncRejectionReason.badSignature.code);
      expect(quarantine.detail, 'forged');
      expect(quarantine.resolution, isNull);
      expect(quarantine.resolutionDecidedAt, isNull);
      expect(quarantine.resolutionProjectedAt, isNull);

      final tables = (await upgraded
              .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
              .get())
          .map((r) => r.read<String>('name'));
      expect(tables, contains('unauthored_changes'));
    });

    test('a v12 sync store upgrades to the current version and keeps every row', () async {
      final directory = Directory.systemTemp.createTempSync('sync-v12-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/sync.sqlite');

      final seed = SyncDatabase(NativeDatabase(file));
      // A v12 store had the table for a merged change that still needs an op,
      // and none of the decision columns.
      await dropColumnsAddedAfter(seed, 12);
      await seed.customStatement(
        'INSERT INTO integrity_alarms (workspace_id, kind, detail, '
        'occurrence_count, first_detected_at, last_detected_at) '
        "VALUES ('workspace-1', 'own_writes_rollback', 'the server lost a write', "
        "1, '2026-08-01T00:00:00.000Z', '2026-08-01T00:00:00.000Z')",
      );
      await seed.customStatement(
        'INSERT INTO quarantined_ops (workspace_id, reason, detail, envelope, '
        "detected_at) VALUES ('workspace-1', 'bad_signature', 'forged', X'', "
        "'2026-08-01T00:00:00.000Z')",
      );
      await seed.customStatement(
        "INSERT INTO unauthored_changes (change_id, collection, entity_id, "
        "member_id_hex, wall_ms, counter, change_json) VALUES "
        "('change-1', 'todos', 't1', '${'a' * 32}', 5, 1, '{}')",
      );
      await seed.customStatement('PRAGMA user_version = 12');
      await seed.close();

      final upgraded = SyncDatabase(NativeDatabase(file));
      addTearDown(upgraded.close);
      expect(upgraded.schemaVersion, SyncDatabase.supportedSchemaVersion);

      final alarm = await upgraded.select(upgraded.integrityAlarms).getSingle();
      expect(alarm.kind, IntegrityAlarmKind.ownWritesRollback.code);
      expect(
        alarm.resolution,
        isNull,
        reason: 'nothing was decided before the decision existed',
      );
      expect(alarm.resolutionDecidedAt, isNull);
      expect(alarm.repostFromAuthorSeq, isNull);

      final quarantine = await upgraded.select(upgraded.quarantinedOps).getSingle();
      expect(quarantine.reason, SyncRejectionReason.badSignature.code);
      expect(quarantine.resolution, isNull);
      expect(quarantine.resolutionDecidedAt, isNull);
      expect(quarantine.resolutionProjectedAt, isNull);

      final unauthed = await upgraded.select(upgraded.unauthoredChanges).getSingle();
      expect(unauthed.changeId, 'change-1');
      expect(unauthed.collection, 'todos');
      expect(unauthed.entityId, 't1');
    });

    test('a v13 sync store upgrades to the current version and keeps every row', () async {
      final directory = Directory.systemTemp.createTempSync('sync-v13-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/sync.sqlite');

      final seed = SyncDatabase(NativeDatabase(file));
      // A v13 store is the one a device on the base writes today: it holds
      // the vault's table and none of the decision columns.
      await dropColumnsAddedAfter(seed, 13);
      await seed.customStatement(
        'INSERT INTO integrity_alarms (workspace_id, kind, detail, '
        'occurrence_count, first_detected_at, last_detected_at) '
        "VALUES ('workspace-1', 'own_writes_rollback', 'the server lost a write', "
        "1, '2026-08-01T00:00:00.000Z', '2026-08-01T00:00:00.000Z')",
      );
      await seed.customStatement(
        'INSERT INTO quarantined_ops (workspace_id, reason, detail, envelope, '
        "detected_at) VALUES ('workspace-1', 'bad_signature', 'forged', X'', "
        "'2026-08-01T00:00:00.000Z')",
      );
      await seed.customStatement('PRAGMA user_version = 13');
      await seed.close();

      final upgraded = SyncDatabase(NativeDatabase(file));
      addTearDown(upgraded.close);
      expect(upgraded.schemaVersion, SyncDatabase.supportedSchemaVersion);

      final alarm = await upgraded.select(upgraded.integrityAlarms).getSingle();
      expect(alarm.kind, IntegrityAlarmKind.ownWritesRollback.code);
      expect(alarm.detail, 'the server lost a write');
      expect(
        alarm.resolution,
        isNull,
        reason: 'nothing was decided before the decision existed',
      );
      expect(alarm.resolutionDecidedAt, isNull);
      expect(alarm.repostFromAuthorSeq, isNull);

      final quarantine = await upgraded.select(upgraded.quarantinedOps).getSingle();
      expect(quarantine.reason, SyncRejectionReason.badSignature.code);
      expect(quarantine.detail, 'forged');
      expect(quarantine.resolution, isNull);
      expect(quarantine.resolutionDecidedAt, isNull);
      expect(quarantine.resolutionProjectedAt, isNull);

      // The table the vault brought at v13 is still there: the upgrade past
      // it adds columns, it does not rebuild the store.
      final tables = (await upgraded
              .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
              .get())
          .map((r) => r.read<String>('name'));
      expect(tables, contains('vault_page_bases'));
    });

    test('a v14 sync store upgrades to the current version and keeps its decisions', () async {
      final directory = Directory.systemTemp.createTempSync('sync-v14-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/sync.sqlite');

      final seed = SyncDatabase(NativeDatabase(file));
      // A v14 store had the decision columns but not the projection marker.
      await dropColumnsAddedAfter(seed, 14);
      await seed.customStatement(
        'INSERT INTO quarantined_ops (workspace_id, reason, detail, envelope, '
        "detected_at, resolution, resolution_decided_at) VALUES "
        "('workspace-1', 'bad_signature', 'forged', X'', "
        "'2026-08-01T00:00:00.000Z', 'took_upstream', "
        "'2026-08-01T00:00:00.000Z')",
      );
      await seed.customStatement('PRAGMA user_version = 14');
      await seed.close();

      final upgraded = SyncDatabase(NativeDatabase(file));
      addTearDown(upgraded.close);
      expect(upgraded.schemaVersion, SyncDatabase.supportedSchemaVersion);

      final quarantine = await upgraded.select(upgraded.quarantinedOps).getSingle();
      expect(quarantine.reason, SyncRejectionReason.badSignature.code);
      expect(
        quarantine.resolution,
        AlarmResolution.tookUpstream.code,
        reason: 'the decision was made before the projection marker existed',
      );
      expect(quarantine.resolutionDecidedAt, isNotNull);
      expect(
        quarantine.resolutionProjectedAt,
        isNull,
        reason: 'nothing has been projected, so nothing has been stamped',
      );
    });
  });
}
