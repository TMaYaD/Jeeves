/// The reclassification, at the spine: what still *stands* against what the User
/// is told is *wrong*.
///
/// Every case here runs a real fault through a real `SimWorkspace` — a hostile
/// reorder, a tampered envelope, a rolled-back server, a key that never arrived —
/// because the claim being made is about what the production health query says
/// after the production receive path has run, and a hand-written row would only
/// assert that the SQL reads the column it was handed.
///
/// The three that fail on the classification being wrong, rather than on any
/// other bug, are I1, I2 and I3: two conditions the app handled perfectly must
/// stop being errors, and one where the User's data really is stuck must stay one.
@TestOn('!browser')
library;

import 'dart:typed_data';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/chain_verifier.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/sync_condition_class.dart';
import 'package:jeeves/sync/sync_database.dart';

import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';

extension _Alarms on SimDevice {
  Future<Map<String, IntegrityAlarmRow>> alarmsByKind() async => {
        for (final alarm in await client.integrityAlarms()) alarm.kind: alarm,
      };

  Future<List<OpLogRow>> loggedOps() => (database.select(database.opLog)
        ..where((row) => row.workspaceId.equals(client.workspaceId))
        ..orderBy([(row) => OrderingTerm(expression: row.seq)]))
      .get();

  Future<void> authorLocal(String value) => client.capture(
        collection: 'harness_docs',
        entityId: '5f2a9c3e-8d41-4b7a-9e26-0c1d3f5b7a92',
        fields: {'step': value},
      );
}

void main() {
  group('the classification itself', () {
    test('exactly four kinds are actionable, and every kind has a class', () {
      // U1's spine half. The switch is exhaustive, so "has a class" is a compile
      // obligation; what a test can still add is the *count*, which is the claim
      // a future contributor would break by quietly promoting a fifth.
      expect(IntegrityAlarmKind.values, hasLength(18));
      expect(
        [
          for (final kind in IntegrityAlarmKind.values)
            if (syncConditionClassOf(kind) == SyncConditionClass.actionable) kind,
        ],
        unorderedEquals([
          IntegrityAlarmKind.authorChainGap,
          IntegrityAlarmKind.ownWritesRollback,
          IntegrityAlarmKind.ownWriteRefusedPermanently,
          IntegrityAlarmKind.epochKeySetUnpublishable,
        ]),
      );
      expect(
        IntegrityAlarmKind.values
            .where((kind) => syncConditionClassOf(kind) == SyncConditionClass.reported),
        hasLength(14),
      );
      expect(
        IntegrityAlarmKind.values
            .where((kind) => syncConditionClassOf(kind) == SyncConditionClass.transient),
        isEmpty,
        reason: 'an alarm is an event that happened; only a refusal can be pending',
      );
    });

    test('exactly five refusal reasons are self-healing, and no more', () {
      // U4. The list is what the health query's `NOT IN` is generated from, so
      // it cannot drift from the SQL — but it can drift from the *intent*, and
      // a sixth reason silently treated as self-healing would be surfaced
      // nowhere at all.
      expect(
        [
          for (final reason in SyncRejectionReason.values)
            if (syncConditionClassOfRefusal(reason) == SyncConditionClass.transient)
              reason,
        ],
        unorderedEquals([
          SyncRejectionReason.missingEpochKey,
          SyncRejectionReason.keyEpochUnknown,
          SyncRejectionReason.keyEpochStale,
          SyncRejectionReason.keyEpochBelowFloor,
          SyncRejectionReason.unwrappableGrant,
        ]),
      );
      expect(
        SyncRejectionReason.values.where((reason) =>
            syncConditionClassOfRefusal(reason) == SyncConditionClass.actionable),
        isEmpty,
        reason: 'the app refused the bytes, which is the rule working',
      );
      expect(transientRefusalCodes, hasLength(5));
      expect(actionableAlarmCodes, hasLength(4));
    });

    test('an unknown stored code never throws, and reads as reported', () {
      // U2's spine half. `IntegrityAlarmKind.byCode` is a bare `firstWhere`, so
      // a store written by a newer build crashes every reader that uses it.
      expect(() => IntegrityAlarmKind.byCode('from_the_future'), throwsStateError);
      expect(integrityAlarmKindByCodeOrNull('from_the_future'), isNull);
      expect(syncRejectionReasonByCodeOrNull('from_the_future'), isNull);
    });
  });

  group('at the spine', () {
    late SimWorkspace workspace;

    tearDown(() async => workspace.close());

    test('I1 a hostile reorder the app healed is no longer an error', () async {
      workspace = await SimWorkspace.create();
      final a = workspace.a;
      final b = workspace.b;
      // A has to hold B's registration before the reorder, or the withheld
      // control ops would be a gap and the case would test the wrong fault.
      await workspace.syncAll();
      await b.authorLocal('one');
      await b.authorLocal('two');
      await b.sync();
      final peerSeqs = [
        for (final row in (await b.loggedOps()))
          if (row.authorMemberId == b.identity.memberId) row.seq,
      ]..sort();
      workspace.server.serveOrder = [peerSeqs.last, peerSeqs[peerSeqs.length - 2]];

      await a.sync();

      final alarms = await a.alarmsByKind();
      expect(
        alarms[IntegrityAlarmKind.authorStreamReordered.code]?.resolvedAt,
        isNull,
        reason: 'the server still reordered, and that accusation stands',
      );

      final health = await a.client.health();
      expect(
        health.unresolvedAlarmCount,
        greaterThan(0),
        reason: 'nothing about what stands changed',
      );
      expect(
        health.actionableAlarmCount,
        0,
        reason: 'a reorder that converged took nothing from the user',
      );
      expect(
        health.degraded,
        isFalse,
        reason: 'FAILS ON MAIN: the app did the right thing and painted itself red',
      );
      expect(health.hasSomethingToReport, isTrue);
    });

    test('I1b a correctly-refused forged envelope is no longer an error', () async {
      workspace = await SimWorkspace.create(deviceCount: 1);
      final a = workspace.a;
      await a.authorLocal('mine');
      await a.sync();
      // A tampered copy of this device's own op. The signature covers
      // `header || body`, so one flipped byte is refused at the first stage —
      // which is the fail-closed rule doing exactly its job.
      final authored = await a.client.authoredEnvelopes();
      final tampered = Uint8List.fromList(authored.last);
      tampered[headerLengthBytes + 8] ^= 0x01;
      workspace.server.injectUnchecked(workspace.workspaceId, tampered);

      await a.sync();

      final health = await a.client.health();
      expect((await a.alarmsByKind()).keys, {IntegrityAlarmKind.signatureInvalid.code});
      expect(health.unresolvedAlarmCount, 1);
      expect(health.quarantineCount, 1);
      expect(health.actionableAlarmCount, 0);
      expect(
        health.degraded,
        isFalse,
        reason: 'FAILS ON MAIN: refusing a forgery is the rule working, not a fault',
      );
      expect(
        health.hasSomethingToReport,
        isTrue,
        reason: 'not an error, but the user gets to know it happened',
      );
    });

    test('I2 a key that has not arrived is neither an error nor worth reporting',
        () async {
      workspace = await SimWorkspace.create(deviceCount: 2);
      final a = workspace.a;
      final b = workspace.b;
      await a.enrolment.turnOnEncryption(passphrase: workspace.passphrase);
      await workspace.syncAll();
      // A rotation B holds no wrap for. Reached here by revoking B and then
      // having a hostile server keep serving it anyway, because that is the one
      // way to hold a device keyless across a pull — a live member's client
      // re-fetches its wrap on the pull tail and heals itself, which is the
      // whole reason this condition is classified as self-healing.
      await a.enrolment.revokeAndRotate(
        passphrase: workspace.passphrase,
        memberId: b.identity.memberId,
      );
      await a.authorLocal('after the rotation');
      await a.sync();
      workspace.server.poisonGrantLiveness(
        workspace.workspaceId,
        workspace.ownerGrantIdOf(b.identity.memberId),
      );
      // The default Workspace's client alone: `SimDevice.sync` also pulls the
      // preferences Workspace, which a revoked member is refused outright.
      await b.client.sync();

      expect(
        (await b.client.quarantined(includeReleased: false))
            .map((row) => row.reason)
            .toSet(),
        contains(SyncRejectionReason.missingEpochKey.code),
      );
      final health = await b.client.health();
      expect(health.quarantineCount, greaterThan(0));
      expect(
        health.reportableQuarantineCount,
        0,
        reason: 'a wrap that has not arrived is a delivery gap, not an event',
      );
      expect(
        health.degraded,
        isFalse,
        reason: 'FAILS ON MAIN: the clearest instance of the defect — a red icon '
            'for a condition that heals itself and that the user cannot act on',
      );
      expect(
        health.hasSomethingToReport,
        isFalse,
        reason: 'FAILS ON MAIN: offering a screen to read about it would '
            'reintroduce the interruption this change exists to remove',
      );
    });

    test('I3 a rollback of the device\'s own writes is still an error', () async {
      workspace = await SimWorkspace.create(deviceCount: 1);
      final a = workspace.a;
      await a.authorLocal('one');
      await a.authorLocal('two');
      await a.sync();
      final ownSeqs = [
        for (final row in await a.loggedOps())
          if (row.authorMemberId == a.identity.memberId) row.seq,
      ]..sort();
      workspace.server.rollbackToSeq(ownSeqs.last - 1);
      await a.authorLocal('three');

      final health = await a.sync();

      expect(
        (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesRollback.code]?.resolvedAt,
        isNull,
      );
      expect(health.actionableAlarmCount, greaterThan(0));
      expect(
        health.degraded,
        isTrue,
        reason: 'changes the user made on this device were not saved — the one '
            'shape of condition that has always deserved the red icon',
      );
      expect(health.hasSomethingToReport, isTrue);
    });

    test('I4 the one-shot and the stream agree on both new counts', () async {
      workspace = await SimWorkspace.create(deviceCount: 1);
      final a = workspace.a;
      await a.authorLocal('mine');
      await a.sync();
      final authored = await a.client.authoredEnvelopes();
      final tampered = Uint8List.fromList(authored.last);
      tampered[headerLengthBytes + 8] ^= 0x01;
      workspace.server.injectUnchecked(workspace.workspaceId, tampered);
      await a.sync();

      final oneShot = await a.client.health();
      final streamed = await a.client.watchSyncHealth().first;
      expect(streamed, oneShot, reason: 'one SQL string stands behind both');
      expect(streamed.actionableAlarmCount, oneShot.actionableAlarmCount);
      expect(streamed.reportableQuarantineCount, oneShot.reportableQuarantineCount);
    });

    test('I5 what stands is unchanged, and still gates compaction', () async {
      // The deferral, pinned as a fact rather than left as an assumption: a
      // `reported` alarm still counts in `unresolvedAlarmCount`, so a Workspace
      // served one forgery still cannot compact. This slice fixes the indicator,
      // not the log — see ADR-0044 and #654.
      workspace = await SimWorkspace.create(deviceCount: 1);
      final a = workspace.a;
      await a.authorLocal('mine');
      await a.sync();
      final authored = await a.client.authoredEnvelopes();
      final tampered = Uint8List.fromList(authored.last);
      tampered[headerLengthBytes + 8] ^= 0x01;
      workspace.server.injectUnchecked(workspace.workspaceId, tampered);
      await a.sync();

      final health = await a.client.health();
      expect(health.unresolvedAlarmCount, 1);
      expect(health.quarantineCount, 1);
      expect(
        health.clean,
        isFalse,
        reason: '`clean` keeps its exact meaning: pending + unresolved alarms',
      );
      expect(health.degraded, isFalse, reason: 'but it is not called an error');
    });

    test('I6 a code from a later build is reported by the query too', () async {
      // The one case in this file a real fault cannot stage: an unknown code is
      // by definition one a *newer* build wrote, so the rows are written by
      // hand. What is under test is not the receive path but the two generated
      // predicates — `kind IN (…actionable…)` and `reason NOT IN (…transient…)`
      // — agreeing with the Dart classifiers about a code neither has heard of.
      // They are the same decision expressed twice, in SQL and in Dart, and this
      // is the only assertion that holds them together for an unmatched code.
      workspace = await SimWorkspace.create(deviceCount: 1);
      final a = workspace.a;
      final when = DateTime.utc(2026, 8, 1);
      await a.database.into(a.database.integrityAlarms).insert(
            IntegrityAlarmsCompanion.insert(
              workspaceId: a.client.workspaceId,
              kind: 'from_the_future',
              detail: '',
              occurrenceCount: 1,
              firstDetectedAt: when,
              lastDetectedAt: when,
            ),
          );
      await a.database.into(a.database.quarantinedOps).insert(
            QuarantinedOpsCompanion.insert(
              workspaceId: a.client.workspaceId,
              reason: 'from_the_future',
              detail: '',
              envelope: Uint8List(0),
              detectedAt: when,
            ),
          );

      final health = await a.client.health();
      expect(health.unresolvedAlarmCount, 1, reason: 'the accusation stands');
      expect(
        health.actionableAlarmCount,
        0,
        reason: 'an unclassifiable code is no evidence that anything is stuck',
      );
      expect(health.quarantineCount, 1);
      expect(
        health.reportableQuarantineCount,
        1,
        reason: 'unknown is not self-healing: erring toward telling the user',
      );
      expect(health.degraded, isFalse);
      expect(health.hasSomethingToReport, isTrue);

      expect(classOfAlarmCode('from_the_future'), SyncConditionClass.reported);
      expect(classOfRefusalCode('from_the_future'), SyncConditionClass.reported);
    });
  });
}
