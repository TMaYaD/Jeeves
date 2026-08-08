/// Entity-level compaction with soft-delete prunes, end to end (#555).
///
/// `backend/tests/sync/test_compaction_routes.py` pins the route contract; this
/// file is the thing the issue is actually about — a compacted log that a fresh
/// device bootstraps to **byte-identical** reduced state, with every original
/// author's clock preserved and no standing accusation left behind.
///
/// Four rules are load-bearing here and each has its own group below:
///
/// * a class-4 snapshot re-asserts `(joined value, winning clock)` per field, so
///   merging it is absorption rather than a fresh write by the compactor;
/// * a class-5 prune carries **per-op chain attestations**, because entity-level
///   pruning punches holes *inside* every contributing author's chain rather than
///   truncating a prefix (ADR-0038);
/// * those attestations bridge the verified chain floor over the holes, and the
///   quarantine-then-release fixpoint is what makes an honest bootstrap converge
///   inside one sync instead of raising an alarm storm;
/// * nothing is ever deleted. `compacted_by` hides a row from the default pull
///   and `include_compacted` serves it back.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/chain_verifier.dart';
import 'package:jeeves/sync/compaction.dart';
import 'package:jeeves/sync/control_payload.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/op_payload.dart';
import 'package:jeeves/sync/prune_payload.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_transport.dart';
import 'package:uuid/uuid.dart';

import 'harness/author_fixture.dart';
import 'harness/fake_sync_server.dart';
import 'harness/reduced_state.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';

const String _collection = 'harness_docs';

String _entityId(String label) =>
    const Uuid().v5(jeevesWorkspaceNamespace, 'compaction/entity/$label');

/// A device that enrols **after** the log was compacted, with the passphrase
/// alone — the bootstrap AC 1 is about.
Future<SimDevice> _freshDevice(SimWorkspace workspace, String label) => SimDevice.create(
      label: label,
      userId: workspace.userId,
      server: workspace.server,
      clock: workspace.clock,
      timers: workspace.timers,
      passphrase: workspace.passphrase,
      memberId: const Uuid().v5(jeevesWorkspaceNamespace, 'sim/device/fresh-$label'),
      seed: Uint8List.fromList(
        List<int>.generate(32, (byte) => (byte * 7 + label.codeUnitAt(0)) % 256),
      ),
      random: Random(label.codeUnitAt(0)),
    );

/// Author [count] writes to one entity from [device], then sync everyone online.
Future<void> _fill(
  SimWorkspace workspace,
  SimDevice device, {
  required String entityId,
  int count = 24,
}) async {
  for (var index = 0; index < count; index++) {
    workspace.clock.advance(1000);
    await device.client.capture(
      collection: _collection,
      entityId: entityId,
      fields: {'body': 'revision $index'},
    );
  }
  await workspace.syncAll();
}

Compactor _compactor(SimDevice device) => Compactor(
      client: device.client,
      database: device.database,
      now: () => device.clock.asDateTime,
    );

Future<List<PrunedAttestationRow>> _attestations(SimDevice device) =>
    (device.database.select(device.database.prunedAttestations)
          ..orderBy([(row) => OrderingTerm(expression: row.authorSeq)]))
        .get();

/// The stored envelopes of one author's content ops, oldest first — including the
/// ones a prune has since hidden, because a soft delete keeps every byte.
List<StoredOp> _contentOpsOf(SimWorkspace workspace, SimDevice author) => [
      for (final op in workspace.server.storedOps)
        if (op.workspaceId == workspace.workspaceId &&
            op.header?.authorMemberId == author.identity.memberId &&
            op.header?.opClass == opClassContent)
          op,
    ];

void main() {
  group('AC 1 — a fresh device bootstraps a compacted log', () {
    test('to byte-identical reduced state, with no standing accusation', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final entityId = _entityId('bootstrap');
      await _fill(workspace, workspace.a, entityId: entityId);

      final result = await _compactor(workspace.a)
          .compactEntity(collection: _collection, entityId: entityId);
      expect(result.prunedOpCount, greaterThanOrEqualTo(compactionThresholdLiveOps));
      await workspace.syncAll();

      final before = await canonicalReducedState(workspace.a.database);
      final fresh = await _freshDevice(workspace, 'F');
      addTearDown(fresh.close);
      await fresh.sync();

      expect(await canonicalReducedState(fresh.database), before);
      final health = await fresh.client.health();
      expect(health.unresolvedAlarmCount, 0, reason: '${health.alarmKinds}');
      expect(health.quarantineCount, 0);
      expect(health.clean, isTrue);
    });

    test('and the prune attestations are what bridged its chain floor', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final entityId = _entityId('floor');
      await _fill(workspace, workspace.a, entityId: entityId);
      await _compactor(workspace.a).compactEntity(
        collection: _collection,
        entityId: entityId,
      );
      await workspace.syncAll();

      final fresh = await _freshDevice(workspace, 'G');
      addTearDown(fresh.close);
      await fresh.sync();

      final attested = await _attestations(fresh);
      expect(attested, isNotEmpty);
      expect(
        attested.map((row) => row.authorMemberId).toSet(),
        {workspace.a.identity.memberId},
      );
      // Every attested position is one the fresh device never received bytes
      // for, which is precisely why the verdict needed a floor at all.
      final logged = await fresh.database.select(fresh.database.opLog).get();
      final loggedPositions = {
        for (final row in logged)
          if (row.authorMemberId == workspace.a.identity.memberId) row.authorSeq,
      };
      expect(
        attested.map((row) => row.authorSeq).toSet().intersection(loggedPositions),
        isEmpty,
      );
    });

    test('and a full-history device applies the snapshot idempotently', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final entityId = _entityId('idempotent');
      await _fill(workspace, workspace.a, entityId: entityId);
      final before = await canonicalReducedState(workspace.b.database);

      await _compactor(workspace.a).compactEntity(
        collection: _collection,
        entityId: entityId,
      );
      await workspace.syncAll();

      // B held every original, so the snapshot re-asserts clocks it already has:
      // equal HLC is an idempotent skip per field.
      expect(await canonicalReducedState(workspace.b.database), before);
      expect((await workspace.b.client.health()).unresolvedAlarmCount, 0);
    });
  });

  group('AC 2 — the original clocks survive compaction', () {
    test('an offline older-HLC edit loses exactly as it would have', () async {
      final workspace = await SimWorkspace.create(deviceCount: 3);
      addTearDown(workspace.close);
      final entityId = _entityId('older');
      final c = workspace.devices[2];

      // Authored *before* every write A is about to make, and never uploaded: the
      // edit has to lose against the snapshot exactly as it would have lost
      // against the op the snapshot supersedes.
      c.goOffline();
      await c.client.capture(
        collection: _collection,
        entityId: entityId,
        fields: {'body': 'stale offline edit'},
      );
      await _fill(workspace, workspace.a, entityId: entityId);

      await _compactor(workspace.a).compactEntity(
        collection: _collection,
        entityId: entityId,
      );
      await workspace.syncAll();
      c.goOnline();
      await workspace.syncAll();
      await workspace.syncAll();

      final settled = await canonicalReducedState(workspace.a.database);
      expect(settled, contains('revision 23'));
      expect(settled, isNot(contains('stale offline edit')));
      expect(await canonicalReducedState(c.database), settled);
    });

    test('an offline newer-HLC edit wins over the snapshot', () async {
      final workspace = await SimWorkspace.create(deviceCount: 3);
      addTearDown(workspace.close);
      final entityId = _entityId('newer');
      await _fill(workspace, workspace.a, entityId: entityId);

      final c = workspace.devices[2];
      c.goOffline();
      workspace.clock.advance(600000);
      await c.client.capture(
        collection: _collection,
        entityId: entityId,
        fields: {'body': 'fresh offline edit'},
      );

      await _compactor(workspace.a).compactEntity(
        collection: _collection,
        entityId: entityId,
      );
      await workspace.syncAll();
      c.goOnline();
      await workspace.syncAll();
      await workspace.syncAll();

      final settled = await canonicalReducedState(workspace.a.database);
      expect(settled, contains('fresh offline edit'));
      expect(await canonicalReducedState(c.database), settled);
    });

    test('a compacted tombstone is re-asserted at its own clock', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final entityId = _entityId('tombstoned');
      await _fill(workspace, workspace.a, entityId: entityId);
      workspace.clock.advance(1000);
      await workspace.b.client.capture(
        collection: _collection,
        entityId: entityId,
        tombstone: true,
      );
      await workspace.syncAll();
      final before = await canonicalReducedState(workspace.a.database);

      await _compactor(workspace.a).compactEntity(
        collection: _collection,
        entityId: entityId,
      );
      await workspace.syncAll();

      // The tombstone clock is device B's, not compacting device A's: a tombstone
      // re-stamped with the compactor's newer clock would bury a resurrection the
      // original could never have buried.
      expect(await canonicalReducedState(workspace.a.database), before);
      final fresh = await _freshDevice(workspace, 'H');
      addTearDown(fresh.close);
      await fresh.sync();
      expect(await canonicalReducedState(fresh.database), before);
    });

    test('a class-4 payload whose field carries no clock is refused', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      await expectLater(
        workspace.a.client.captureCompaction(OpPayload(
          collection: _collection,
          entityId: _entityId('no-clock'),
          hlc: workspace.a.hlc.send(),
          fields: const {'body': FieldWrite('unstamped')},
        )),
        throwsA(isA<SyncRejection>().having(
          (rejection) => rejection.reason,
          'reason',
          SyncRejectionReason.compactionFieldWithoutHlc,
        )),
      );
    });

    test('a class-4 tombstone with no tombstone clock is refused', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      await expectLater(
        workspace.a.client.captureCompaction(OpPayload(
          collection: _collection,
          entityId: _entityId('no-tombstone-clock'),
          hlc: workspace.a.hlc.send(),
          tombstone: true,
        )),
        throwsA(isA<SyncRejection>().having(
          (rejection) => rejection.reason,
          'reason',
          SyncRejectionReason.compactionTombstoneWithoutHlc,
        )),
      );
    });

    test('a tombstone clock outside class 4 is refused', () async {
      final payload = OpPayload(
        collection: _collection,
        entityId: _entityId('leaked-tombstone-hlc'),
        hlc: Hlc(1, 0, const Uuid().v4().replaceAll('-', '')),
        tombstone: true,
        tombstoneHlc: Hlc(1, 0, const Uuid().v4().replaceAll('-', '')),
      );
      expect(
        () => guardOpClassShape(payload, opClass: opClassContent),
        throwsA(isA<SyncRejection>().having(
          (rejection) => rejection.reason,
          'reason',
          SyncRejectionReason.tombstoneHlcOutsideCompaction,
        )),
      );
    });
  });

  group('AC 3 — the history view', () {
    test('a compacted row is hidden by default and served on request', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final entityId = _entityId('history');
      await _fill(workspace, workspace.a, entityId: entityId);
      final result = await _compactor(workspace.a).compactEntity(
        collection: _collection,
        entityId: entityId,
      );
      await workspace.syncAll();

      final defaultPage = await workspace.a.link.pullOps(
        workspace.workspaceId,
        since: 0,
        limit: 1000,
      );
      final history = await workspace.a.link.pullOps(
        workspace.workspaceId,
        since: 0,
        limit: 1000,
        includeCompacted: true,
      );
      expect(history.ops.length - defaultPage.ops.length, result.prunedOpCount);
      expect(await workspace.a.client.history(), hasLength(history.ops.length));
    });

    test('the history read never feeds the receive pipeline', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final entityId = _entityId('history-inert');
      await _fill(workspace, workspace.a, entityId: entityId);
      await _compactor(workspace.a).compactEntity(
        collection: _collection,
        entityId: entityId,
      );
      await workspace.syncAll();

      final quarantinedBefore = (await workspace.a.client.quarantined()).length;
      final stateBefore = await canonicalReducedState(workspace.a.database);
      await workspace.a.client.history();
      expect((await workspace.a.client.quarantined()).length, quarantinedBefore);
      expect(await canonicalReducedState(workspace.a.database), stateBefore);
    });
  });

  group('AC 4 — authority, holes and interleaving', () {
    test('a prune from a participant is refused by role', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final participant = await AuthorFixture.create();
      final session = await workspace.enrolFixture(participant, role: roleParticipant);

      await expectLater(
        session.postOps(workspace.workspaceId, [
          await participant.nextEnvelope(
            workspace.workspaceId,
            opClass: opClassPrune,
            payload: PrunePayload(
              compactionOpId: const Uuid().v4(),
              targets: [
                PruneTarget(
                  seq: 1,
                  authorMemberId: participant.memberId,
                  authorSeq: 1,
                  envelopeHash: Uint8List(32),
                ),
              ],
            ).encode(),
          ),
        ]),
        throwsA(isA<SyncTransportException>()
            .having((error) => error.code, 'code', 'role_forbids_op_class')),
      );
    });

    test('a mid-chain hole with interleaved survivors bootstraps clean', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final compacted = _entityId('interleaved-compacted');
      final survivor = _entityId('interleaved-survivor');
      for (var index = 0; index < 22; index++) {
        workspace.clock.advance(1000);
        await workspace.a.client.capture(
          collection: _collection,
          entityId: compacted,
          fields: {'body': 'compacted $index'},
        );
        workspace.clock.advance(1000);
        await workspace.a.client.capture(
          collection: _collection,
          entityId: survivor,
          fields: {'body': 'survivor $index'},
        );
      }
      await workspace.syncAll();

      await _compactor(workspace.a).compactEntity(
        collection: _collection,
        entityId: compacted,
      );
      await workspace.syncAll();
      final settled = await canonicalReducedState(workspace.a.database);

      final fresh = await _freshDevice(workspace, 'I');
      addTearDown(fresh.close);
      await fresh.sync();
      // The survivor's ops sit *between* the pruned ones in A's chain, so the
      // floor bridges many separate holes rather than one prefix.
      expect(await canonicalReducedState(fresh.database), settled);
      final health = await fresh.client.health();
      expect(health.unresolvedAlarmCount, 0, reason: '${health.alarmKinds}');
      expect(health.quarantineCount, 0);
    });

    test('a freshly reseeded log is not a compaction candidate', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final entityId = _entityId('young');
      await _fill(workspace, workspace.a, entityId: entityId);
      // Every op is young, so the grace window protects the whole log — which is
      // what keeps compaction out of the reseed's way by construction.
      expect(await _compactor(workspace.a).compactionCandidates(), isEmpty);
    });

    test('an aged entity over the threshold is a candidate', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final entityId = _entityId('aged');
      await _fill(workspace, workspace.a, entityId: entityId);
      workspace.clock.advance(pruneGraceWindow.inMilliseconds + 1000);
      expect(
        await _compactor(workspace.a).compactionCandidates(),
        contains((collection: _collection, entityId: entityId)),
      );
    });
  });

  group('AC 5 — the quarantine race at a bridged position', () {
    test('a genuine claimant quarantined before the prune is settled', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final entityId = _entityId('settled');
      await _fill(workspace, workspace.a, entityId: entityId, count: 22);

      // Withhold A's first few content ops for the duration of the fresh device's
      // bootstrap, so the ops after them quarantine as gap claimants — and *then*
      // compact them away. The attestation is what settles them: each claimant and
      // the compactor agree byte for byte, so there is nothing left to accuse
      // anybody of. The withholding has to be in place before the device enrols,
      // because the enrolment ceremony is what pulls.
      final aOps = _contentOpsOf(workspace, workspace.a);
      workspace.server.omitSeqs.addAll([for (final op in aOps.take(5)) op.seq]);
      final fresh = await _freshDevice(workspace, 'J');
      addTearDown(fresh.close);
      await fresh.sync();
      workspace.server.omitSeqs.clear();
      expect(
        await fresh.client.quarantined(includeReleased: false),
        isNotEmpty,
        reason: 'the withheld predecessors should have gapped their successors',
      );

      await _compactor(workspace.a).compactEntity(
        collection: _collection,
        entityId: entityId,
      );
      await workspace.syncAll();
      await fresh.sync();

      final health = await fresh.client.health();
      expect(
        health.alarmKinds,
        isNot(contains(IntegrityAlarmKind.pruneAttestationDivergence.code)),
      );
      expect(health.quarantineCount, 0, reason: 'the attestation settles it');
      expect(health.unresolvedAlarmCount, 0, reason: '${health.alarmKinds}');
      expect(
        await canonicalReducedState(fresh.database),
        await canonicalReducedState(workspace.a.database),
      );
    });

    test('a pruned original re-served at a bridged position is skipped', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final entityId = _entityId('late-original');
      await _fill(workspace, workspace.a, entityId: entityId, count: 22);
      final originals = _contentOpsOf(workspace, workspace.a);
      await _compactor(workspace.a).compactEntity(
        collection: _collection,
        entityId: entityId,
      );
      await workspace.syncAll();

      final fresh = await _freshDevice(workspace, 'L');
      addTearDown(fresh.close);
      await fresh.sync();
      final quarantinedBefore =
          (await fresh.client.quarantined(includeReleased: false)).length;
      final alarmsBefore = (await fresh.client.health()).unresolvedAlarmCount;
      final stateBefore = await canonicalReducedState(fresh.database);

      // A chatty server re-serving bytes it already pruned. The hash matches the
      // attestation, so this is a skip and an accusation of nothing.
      workspace.server.injectUnchecked(workspace.workspaceId, originals[3].envelope);
      await fresh.sync();

      expect(
        (await fresh.client.quarantined(includeReleased: false)).length,
        quarantinedBefore,
      );
      expect((await fresh.client.health()).unresolvedAlarmCount, alarmsBefore);
      expect(await canonicalReducedState(fresh.database), stateBefore);
    });

    test('an attestation that contradicts the log stands accused', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final entityId = _entityId('divergent');
      await _fill(workspace, workspace.a, entityId: entityId, count: 22);
      final originals = _contentOpsOf(workspace, workspace.a);

      // A lying compactor, injected past the server's own POST-time cross-check:
      // device B attests one of A's positions with bytes A never signed. B holds
      // the originals, so B can catch it — which is the whole point of the check.
      final target = originals[4];
      final lie = await workspace.b.client.capturePrune(PrunePayload(
        compactionOpId: const Uuid().v4(),
        targets: [
          PruneTarget(
            seq: target.seq,
            authorMemberId: target.header!.authorMemberId,
            authorSeq: target.header!.authorSeq,
            envelopeHash: Uint8List(32),
          ),
        ],
      ));
      expect(lie, isNotEmpty);
      final authored = await workspace.b.client.authoredEnvelopes();
      workspace.server.injectUnchecked(workspace.workspaceId, authored.last);
      await workspace.b.client.pull();

      final health = await workspace.b.client.health();
      expect(
        health.alarmKinds,
        contains(IntegrityAlarmKind.pruneAttestationDivergence.code),
      );
      // The accusation stands and the device keeps its own copy, so nothing of
      // the user's was lost — the condition is `reported`, not an error.
      // It still counts in `unresolvedAlarmCount`, so this Workspace
      // still cannot compact.
      expect(health.unresolvedAlarmCount, greaterThan(0));
      expect(health.clean, isFalse);
      expect(health.degraded, isFalse);
      expect(health.hasSomethingToReport, isTrue);
    });
  });

  group('AC 6 — the compactor checks its own echo', () {
    test('its attestations land on the echo and nothing was accused', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final entityId = _entityId('echo');
      await _fill(workspace, workspace.a, entityId: entityId);
      final stateBefore = await canonicalReducedState(workspace.a.database);

      final result = await _compactor(workspace.a).compactEntity(
        collection: _collection,
        entityId: entityId,
      );
      // Authoring writes the outbox and `author_state`, never `op_log`, so the
      // attestations exist only once the prune's own echo comes back through the
      // ordinary class-5 receive path — one code path for every device.
      expect(await _attestations(workspace.a), isEmpty);

      await workspace.a.client.sync();
      expect(await _attestations(workspace.a), hasLength(result.prunedOpCount));
      // The cross-check ran against the very rows the attestations were minted
      // from, so a mismatch here would be the compactor accusing itself.
      final health = await workspace.a.client.health();
      expect(health.unresolvedAlarmCount, 0, reason: '${health.alarmKinds}');
      // A class-4 self-apply is a provable no-op: every field's clock equals the
      // stored winning clock, so the snapshot changes nothing.
      expect(await canonicalReducedState(workspace.a.database), stateBefore);
    });

    test('compaction is refused while this device is not caught up', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final entityId = _entityId('blocked');
      await _fill(workspace, workspace.a, entityId: entityId);
      workspace.a.goOffline();
      workspace.clock.advance(1000);
      await workspace.a.client.capture(
        collection: _collection,
        entityId: entityId,
        fields: {'body': 'unsent'},
      );

      await expectLater(
        _compactor(workspace.a).compactEntity(
          collection: _collection,
          entityId: entityId,
        ),
        throwsA(isA<CompactionBlocked>().having(
          (blocked) => blocked.blocker,
          'blocker',
          CompactionBlocker.notCaughtUp,
        )),
      );
    });

    test('compaction is refused below the live-op threshold', () async {
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final entityId = _entityId('too-few');
      await _fill(workspace, workspace.a, entityId: entityId, count: 3);

      await expectLater(
        _compactor(workspace.a).compactEntity(
          collection: _collection,
          entityId: entityId,
        ),
        throwsA(isA<CompactionBlocked>().having(
          (blocked) => blocked.blocker,
          'blocker',
          CompactionBlocker.tooFewLiveOps,
        )),
      );
    });
  });

  group('a rotated Workspace still compacts (#555 regression)', () {
    test('a prune authors and materialises at key_epoch >= 1', () async {
      // The prune op is `plaintext_v1` for ever — the server materialises its
      // payload and holds no key — so [capturePrune] forces its workspace key null.
      // The author-time missing-key guard used to exempt only control ops, so on any
      // rotated Workspace (epoch >= 1) the prune tripped `missing_epoch_key` and
      // compaction pruning died on exactly the Workspaces that had rotated keys.
      final workspace = await SimWorkspace.create(deviceCount: 1);
      addTearDown(workspace.close);
      final a = workspace.a;

      await a.enrolment.turnOnEncryption(passphrase: workspace.passphrase);
      expect(await a.client.epochFloor(), 1,
          reason: 'turn-on rotated the Workspace to epoch 1');

      final entityId = _entityId('rotated');
      await _fill(workspace, a, entityId: entityId);

      final result = await _compactor(a).compactEntity(
        collection: _collection,
        entityId: entityId,
      );
      expect(result.prunedOpCount, greaterThanOrEqualTo(compactionThresholdLiveOps));

      await a.client.sync();
      final pruneOp = workspace.server.storedOps.firstWhere(
        (op) =>
            op.workspaceId == workspace.workspaceId &&
            op.header?.opClass == opClassPrune,
      );
      expect(pruneOp.header!.suite, suitePlaintextV1,
          reason: 'the prune reached the server as plaintext_v1 despite epoch 1');
      expect(pruneOp.header!.keyEpoch, 1);

      final health = await a.client.health();
      expect(health.unresolvedAlarmCount, 0, reason: '${health.alarmKinds}');
    });
  });

  group('the prune payload codec', () {
    test('refuses an empty target list', () {
      expect(
        () => PrunePayload(compactionOpId: const Uuid().v4(), targets: const [])
            .encode(),
        throwsA(isA<SyncRejection>().having(
          (rejection) => rejection.reason,
          'reason',
          SyncRejectionReason.pruneTargetsEmpty,
        )),
      );
    });

    test('refuses a duplicate target on either key', () {
      final target = PruneTarget(
        seq: 7,
        authorMemberId: const Uuid().v4(),
        authorSeq: 3,
        envelopeHash: Uint8List(32),
      );
      expect(
        () => PrunePayload(
          compactionOpId: const Uuid().v4(),
          targets: [target, target],
        ).encode(),
        throwsA(isA<SyncRejection>().having(
          (rejection) => rejection.reason,
          'reason',
          SyncRejectionReason.pruneDuplicateTarget,
        )),
      );
      expect(
        () => PrunePayload(
          compactionOpId: const Uuid().v4(),
          targets: [
            target,
            PruneTarget(
              seq: 8,
              authorMemberId: target.authorMemberId,
              authorSeq: target.authorSeq,
              envelopeHash: Uint8List(32),
            ),
          ],
        ).encode(),
        throwsA(isA<SyncRejection>().having(
          (rejection) => rejection.reason,
          'reason',
          SyncRejectionReason.pruneDuplicateTarget,
        )),
      );
    });

    test('round-trips a well-formed payload', () {
      final payload = PrunePayload(
        compactionOpId: const Uuid().v5(jeevesWorkspaceNamespace, 'compaction'),
        targets: [
          PruneTarget(
            seq: 12,
            authorMemberId: const Uuid().v5(jeevesWorkspaceNamespace, 'author'),
            authorSeq: 4,
            envelopeHash: Uint8List.fromList(List<int>.filled(32, 0xAB)),
          ),
        ],
      );
      expect(PrunePayload.decode(payload.encode()), payload);
    });

    test('refuses an encrypted prune op at the codec level', () {
      final header = OpHeader(
        workspaceId: const Uuid().v5(jeevesWorkspaceNamespace, 'ws'),
        opId: const Uuid().v4(),
        authorMemberId: const Uuid().v4(),
        authorKeyId: Uint8List(8),
        authorSeq: 1,
        opClass: opClassPrune,
        suite: suiteAeadV1,
        keyEpoch: 1,
        nonce: Uint8List(nonceBytes),
      );
      expect(
        header.checkServed,
        throwsA(isA<SyncRejection>().having(
          (rejection) => rejection.reason,
          'reason',
          SyncRejectionReason.encryptedPruneOp,
        )),
      );
    });
  });
}
