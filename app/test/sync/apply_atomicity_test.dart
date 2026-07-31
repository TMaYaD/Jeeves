/// #618: the receive pipeline applies a control op — and a prune — atomically
/// across a crash.
///
/// Two windows have to stay closed, and each has its own tests here:
///
///  * The **rolled-back partial** — a process death mid-apply. A fault injected
///    into a durable write (`applied_control_log`, `pruned_attestations`) throws
///    the way a real `SQLITE_IOERR` would, the receive transaction rolls the
///    whole log-apply-stamp unit back, the store is reopened over the same file,
///    and the next pull re-serves the op and applies it exactly once — no raised
///    floor without its applied-control record, no false slot-collision alarm.
///
///  * The **committed-row, unsaved-cursor gap** — a crash between the receive
///    transaction's commit and `_saveCursor`. The op is fully applied but the
///    cursor never advanced, so the next pull re-serves it. `_logReceived` must
///    recognise its own byte-identical reserve and skip it silently, while a
///    server that genuinely serves *different* bytes for one slot still earns the
///    `author_chain_slot_collision` alarm. Both are asserted, distinctly.
///
/// Everything crash-recovered here is **self-authored**: the reopened client has
/// only this device's own keys (a real relaunch rebuilds no peer directory), so a
/// re-verified op must be one the device itself signed — which every #618 case
/// is.
@TestOn('!browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart'
    show BooleanExpressionOperators, OrderingTerm, Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/chain_verifier.dart';
import 'package:jeeves/sync/compaction.dart';
import 'package:jeeves/sync/control_payload.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/prune_payload.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:sqlite3/common.dart' show SqliteException;
import 'package:uuid/uuid.dart';

import 'harness/author_fixture.dart';
import 'harness/fake_sync_server.dart';
import 'harness/fault_injecting_store.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';

const String _collection = 'harness_docs';

const String _slotCollision = 'author_chain_slot_collision';

/// Rows in this device's GTD-Workspace `applied_control_log` of a given control
/// type — the chain's record of what actually applied, and the place a
/// double-apply would show up. Reads the *live* store, so it is correct after a
/// [SimDevice.reopenSyncStore]. Scoped to one Workspace because
/// `turnOnEncryption` rotates every Workspace the User holds.
Future<List<AppliedControlRow>> _appliedOfType(
  SimDevice device,
  String controlType,
) async =>
    (device.syncStore.select(device.syncStore.appliedControlLog)
          ..where((row) =>
              row.workspaceId.equals(device.client.workspaceId) &
              row.controlType.equals(controlType))
          ..orderBy([(row) => OrderingTerm(expression: row.seq)]))
        .get();

/// Force the persisted pull cursor back below [seq], staging the crash between
/// the receive transaction's commit and `_saveCursor`: the op is fully applied,
/// but the next pull re-serves it because the cursor never moved.
Future<void> _rewindCursorBelow(SimDevice device, int seq) async {
  await (device.syncStore.update(device.syncStore.syncCursors)
        ..where((row) => row.workspaceId.equals(device.client.workspaceId)))
      .write(SyncCursorsCompanion(lastSeq: Value(seq - 1)));
}

/// Count the `author_chain_slot_collision` alarms this device holds.
Future<int> _slotCollisionAlarms(SyncClient client) async =>
    (await client.integrityAlarms())
        .where((alarm) => alarm.kind == _slotCollision)
        .length;

/// This device's `pruned_attestations`, read off the *live* store.
Future<List<PrunedAttestationRow>> _attestations(SimDevice device) =>
    (device.syncStore.select(device.syncStore.prunedAttestations)
          ..orderBy([(row) => OrderingTerm(expression: row.authorSeq)]))
        .get();

/// Author [count] revisions of one entity from [device], then push and pull so
/// the log has enough live ops for a compaction to have something to prune.
Future<void> _fill(SimDevice device, String entityId, {int count = 24}) async {
  for (var index = 0; index < count; index++) {
    device.clock.advance(1000);
    await device.client.capture(
      collection: _collection,
      entityId: entityId,
      fields: {'body': 'revision $index'},
    );
  }
  await device.sync();
}

/// The shared entity the chain-successor cases author a peer's stream onto.
String _replayDocId(SimWorkspace workspace) =>
    preferenceEntityId(workspace.workspaceId, 'chain-replay-doc');

/// One content op from [peer] carrying `{step: value}` — a peer's stream so a
/// withheld predecessor can quarantine its successor, the shape the release scan
/// (and its #620 storage-fault path) exists for.
Future<Uint8List> _peerOp(
  SimWorkspace workspace,
  AuthorFixture peer,
  Object? value,
) async {
  workspace.clock.advance(10);
  return peer.nextEnvelope(
    workspace.workspaceId,
    payloadJson: jsonEncode({
      'collection': _collection,
      'id': _replayDocId(workspace),
      'fields': {
        'step': {'v': value},
      },
      'hlc': [workspace.clock.nowMs, 0, memberIdToHex(peer.memberId)],
    }),
  );
}

/// The reduced value of the shared chain-replay doc on [device].
Future<Map<String, Object?>?> _replayDoc(SimDevice device, SimWorkspace workspace) =>
    device.registry.register(_collection).readEntity(_replayDocId(workspace));

/// The quarantine rows on [device]'s live store carrying the #620 interrupted-
/// replay re-arm marker — the set `_hasInterruptedChainReplay` reads.
Future<List<QuarantineRow>> _reArmMarked(SimDevice device) =>
    (device.syncStore.select(device.syncStore.quarantinedOps)
          ..where((row) => row.releaseStartedAt.isNotNull()))
        .get();

/// Enrol [peer] into [workspace] and land its registration on device A, leaving
/// the peer's chain ready at its first content position (author_seq 3).
Future<FakeSyncServerMemberSession> _enrolPeer(
  SimWorkspace workspace,
  AuthorFixture peer,
) async {
  final session = await workspace.enrolFixture(peer);
  await workspace.a.client.pull();
  return session;
}

/// One integrity alarm of [kind] on [client], or fails the lookup.
Future<IntegrityAlarmRow> _alarmOfKind(SyncClient client, IntegrityAlarmKind kind) async =>
    (await client.integrityAlarms()).firstWhere((alarm) => alarm.kind == kind.code);

void main() {
  late FakeSyncServer server;

  setUp(() => server = FakeSyncServer());

  Future<SimDevice> loneDevice({
    FaultInjectingInterceptor? interceptor,
    Uint8List? seed,
    String? memberId,
  }) async {
    final device = await SimDevice.create(
      label: 'A',
      userId: 'atomicity-user',
      server: server,
      clock: FakeClock(simulationStartWallMs),
      fileBacked: true,
      seed: seed,
      memberId: memberId,
      syncStoreInterceptor: interceptor,
    );
    addTearDown(device.close);
    return device;
  }

  group('rolled-back partial (fault mid-apply, then reopen)', () {
    test('a rotate killed between the floor raise and the applied-control '
        'append converges on the next pull, with no false slot collision (AC#5)',
        () async {
      final faults = FaultInjectingInterceptor();
      final device = await loneDevice(interceptor: faults);

      // Kill the very next `applied_control_log` insert — the rotate's, and the
      // step after `raiseEpochFloor`, which is exactly AC#5's window. The receive
      // transaction rolls the raised floor and the op_log row back with it.
      faults.failNextInsertInto('applied_control_log');
      await expectLater(
        device.enrolment.turnOnEncryption(passphrase: device.outcome.passphrase),
        throwsA(isA<SqliteException>()),
      );
      expect(faults.firedCount, 1, reason: 'the rotate apply was interrupted');

      // Process death: reopen the store over the same file, with the transport
      // reattached so recovery can actually re-pull.
      final reopened = await device.reopenSyncStore(attachTransport: true);
      await reopened.pull();

      expect(
        await reopened.epochFloor(),
        1,
        reason: 'the re-served rotate raises the floor exactly once',
      );
      final applied = await _appliedOfType(device, controlTypeRotate);
      expect(applied, hasLength(1),
          reason: 'the applied-control log holds no duplicate for the rotate');
      expect(
        await _slotCollisionAlarms(reopened),
        0,
        reason: 'recovering an honest own op is not a slot collision (AC#3)',
      );
    });

    test('a prune killed between an attestation insert and the stamp converges '
        'on the next pull (the #592-deferred prune-apply window)', () async {
      final faults = FaultInjectingInterceptor();
      final device = await loneDevice(interceptor: faults);
      final entityId = const Uuid().v5(jeevesWorkspaceNamespace, 'atomicity/prune');
      await _fill(device, entityId);

      // Author the compaction + prune, push them, then kill the prune echo's
      // first `pruned_attestations` insert on the way back in.
      final compactor = Compactor(
        client: device.client,
        database: device.syncStore,
        now: () => device.clock.asDateTime,
      );
      await compactor.compactEntity(collection: _collection, entityId: entityId);
      await device.client.flushOutbox();

      faults.failNextInsertInto('pruned_attestations');
      await expectLater(device.client.pull(), throwsA(isA<SqliteException>()));
      expect(faults.firedCount, 1, reason: 'the prune apply was interrupted');

      final reopened = await device.reopenSyncStore(attachTransport: true);
      await reopened.pull();

      final attested = await _attestations(device);
      expect(attested, isNotEmpty,
          reason: 'the re-served prune lands its attestations');
      expect(
        attested.map((row) => (row.authorMemberId, row.authorSeq)).toSet(),
        hasLength(attested.length),
        reason: 'no duplicate attestation for any position',
      );
      expect(
        await _slotCollisionAlarms(reopened),
        0,
        reason: 'recovering an honest own prune is not a slot collision',
      );
    });
  });

  group('a non-rotate control type crashes and recovers the same way (AC#6)', () {
    test('a revoke killed between its applied-control append and the stamp '
        'converges on reopen, with no false slot collision', () async {
      // The crash window is not rotate-specific, so it is asserted for a second,
      // non-rotate control type. A revoke is self-authored (Root-signed by this
      // device), so the reopened client can re-verify it from its own keys alone.
      final clock = FakeClock(simulationStartWallMs);
      final faults = FaultInjectingInterceptor();
      final a = await SimDevice.create(
        label: 'A',
        userId: 'atomicity-pair',
        server: server,
        clock: clock,
        fileBacked: true,
        syncStoreInterceptor: faults,
      );
      addTearDown(a.close);
      final b = await SimDevice.create(
        label: 'B',
        userId: 'atomicity-pair',
        server: server,
        clock: clock,
        passphrase: a.outcome.passphrase,
      );
      addTearDown(b.close);
      // A learns B's registration and owner Grant, so it has a Grant to revoke.
      await b.sync();
      await a.sync();

      // Revoke (and rotate away from) B. The revoke is authored and applied
      // before the rotate, so killing the first `applied_control_log` insert
      // interrupts the revoke — the non-rotate op this case is about.
      faults.failNextInsertInto('applied_control_log');
      await expectLater(
        a.enrolment.revokeAndRotate(
          passphrase: a.outcome.passphrase,
          memberId: b.identity.memberId,
        ),
        throwsA(isA<SqliteException>()),
      );
      expect(faults.firedCount, 1, reason: 'the revoke apply was interrupted');
      expect(
        await _appliedOfType(a, controlTypeRevoke),
        isEmpty,
        reason: 'the injected fault interrupted the revoke itself, not a '
            'later applied-control insert (the rotate, or B\'s register/grant '
            'echo) landing in the same pull',
      );

      final reopened = await a.reopenSyncStore(attachTransport: true);
      await reopened.pull();

      expect(
        await _appliedOfType(a, controlTypeRevoke),
        hasLength(1),
        reason: 'the re-served revoke applies exactly once',
      );
      expect(await reopened.epochFloor(), 1,
          reason: 'the rotate chained behind the revoke also applies on recovery');
      expect(
        await _slotCollisionAlarms(reopened),
        0,
        reason: 'recovering an honest own revoke is not a slot collision',
      );
    });
  });

  group('committed row, unsaved cursor (the re-serve gap)', () {
    test('a fully-applied rotate re-served against a rewound cursor is skipped '
        'silently — no slot collision, no double apply (AC#3, AC#4)', () async {
      final device = await loneDevice();
      await device.enrolment.turnOnEncryption(passphrase: device.outcome.passphrase);
      expect(await device.client.epochFloor(), 1);

      final rotate = (await _appliedOfType(device, controlTypeRotate)).single;

      // The crash between commit and _saveCursor: the op is applied, the cursor
      // never advanced past it. The next pull re-serves it.
      await _rewindCursorBelow(device, rotate.seq);
      await device.client.pull();

      expect(
        await _slotCollisionAlarms(device.client),
        0,
        reason: 'a byte-identical own reserve heals silently, it does not accuse',
      );
      expect(await device.client.epochFloor(), 1,
          reason: 'the floor is not raised a second time');
      expect(
        await _appliedOfType(device, controlTypeRotate),
        hasLength(1),
        reason: 'the chain head advanced exactly once',
      );
    });

    test('a fully-applied prune re-served against a rewound cursor is skipped '
        'silently — no slot collision, no duplicate attestation', () async {
      final device = await loneDevice();
      final entityId = const Uuid().v5(jeevesWorkspaceNamespace, 'atomicity/prune-gap');
      await _fill(device, entityId);
      await Compactor(
        client: device.client,
        database: device.syncStore,
        now: () => device.clock.asDateTime,
      ).compactEntity(collection: _collection, entityId: entityId);
      await device.sync();

      final before = await _attestations(device);
      expect(before, isNotEmpty);
      final pruneSeq = before.first.pruneSeq;

      await _rewindCursorBelow(device, pruneSeq);
      await device.client.pull();

      expect(await _slotCollisionAlarms(device.client), 0,
          reason: 'a re-served own prune heals silently');
      expect(
        (await _attestations(device)).length,
        before.length,
        reason: 'no attestation is inserted a second time',
      );
    });

    test('a server that serves *different* bytes for one held slot still raises '
        'author_chain_slot_collision (AC#3, the guard against over-suppression)',
        () async {
      final seed = Uint8List.fromList(
        List<int>.generate(32, (index) => (index * 7 + 3) % 256),
      );
      final memberId = const Uuid().v5(jeevesWorkspaceNamespace, 'atomicity/self');
      final device = await loneDevice(seed: seed, memberId: memberId);
      await device.enrolment.turnOnEncryption(passphrase: device.outcome.passphrase);

      final rotate = (await _appliedOfType(device, controlTypeRotate)).single;
      final realEnvelope = server.storedOps
          .firstWhere((op) => op.workspaceId == device.client.workspaceId && op.seq == rotate.seq)
          .envelope;
      final realHeader = OpHeader.parse(splitEnvelope(realEnvelope).header);

      // A *different* rotate, validly signed by this same device (same seed and
      // member id), at the same chain position but a different HLC — so its bytes
      // diverge from the one already logged at that seq. `_receiveRotate` checks
      // the signature, the workspace and the owner grant at the seq; it does not
      // pin the digest, so this passes verification and reaches `_logReceived`.
      final impostor = await AuthorFixture.create(seed: seed, memberId: memberId);
      impostor.nextAuthorSeq = realHeader.authorSeq;
      impostor.lastEnvelopeHash = realHeader.prevAuthorHash;
      final divergent = await rotateEnvelope(
        device: impostor,
        workspaceId: device.client.workspaceId,
        prevControlHash: rotate.prevControlHash,
        keyWrapDigest: Uint8List.fromList(List<int>.filled(32, 9)),
        wallMs: device.clock.nowMs + 999,
        authorSeq: realHeader.authorSeq,
      );

      // Stage the crash-gap, then have the server double-spend the seq with the
      // divergent bytes.
      await _rewindCursorBelow(device, rotate.seq);
      server.injectUnchecked(
        device.client.workspaceId,
        divergent,
        atSeq: rotate.seq,
      );
      await device.client.pull();

      expect(
        await _slotCollisionAlarms(device.client),
        greaterThanOrEqualTo(1),
        reason: 'divergent bytes at one slot are a genuine double-serve, and the '
            'fix must not silence it',
      );
    });
  });

  // #620: a storage fault while re-receiving a released chain successor must not
  // strand the op. The winner is marked released *before* re-entry so the release
  // scan terminates, but that is exactly what loses a replay when `_receive`
  // rethrows a `SqliteException`: the cursor is long past the op's transport seq,
  // so nothing re-serves it, and re-serving its predecessor does not re-run the
  // scan (the predecessor is already logged). The fix rolls the release back and
  // re-arms the next pull off a durable `release_started_at` marker set only for
  // the winner — never for a standing fork, which keeps AC-4's occurrence
  // semantics.
  group('a storage fault mid chain-successor replay stays retryable (#620)', () {
    // Two chained peer ops, served successor-first so the successor quarantines
    // as a gap and the predecessor's arrival drives the release scan.
    Future<void> stageReorderedPair(
      SimWorkspace workspace,
      AuthorFixture peer,
      FakeSyncServerMemberSession peerSession,
    ) async {
      final predecessor = await _peerOp(workspace, peer, 'one');
      final successor = await _peerOp(workspace, peer, 'two');
      final appended = await peerSession.postOps(
        workspace.workspaceId,
        [predecessor, successor],
      );
      workspace.server.serveOrder = [appended[1].seq, appended[0].seq];
    }

    test('the fault keeps the successor a claimant, and the re-arm — not a '
        're-served predecessor — replays it (AC#1, AC#3)', () async {
      final faults = FaultInjectingInterceptor();
      final workspace = await SimWorkspace.create(
        deviceCount: 1,
        server: server,
        aSyncStoreInterceptor: faults,
      );
      addTearDown(workspace.close);
      final a = workspace.a;
      final peer = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 91)),
      );
      final peerSession = await _enrolPeer(workspace, peer);
      await stageReorderedPair(workspace, peer, peerSession);

      // The predecessor's own `op_log` write is the 1st insert in the pull; the
      // successor replay's is the 2nd — the write to interrupt.
      faults.failNthInsertInto('op_log', 2);
      await expectLater(a.client.pull(), throwsA(isA<SqliteException>()));
      expect(faults.firedCount, 1, reason: 'the successor replay was interrupted');

      // The rolled-back release left the winner a claimant, marked interrupted.
      final stranded = await a.client.quarantined(includeReleased: false);
      expect(stranded, hasLength(1));
      expect(stranded.single.releasedAt, isNull,
          reason: 'the transaction rolled `_markReleased` back');
      final marked = await _reArmMarked(a);
      expect(
        marked.map((row) => row.id).toSet(),
        stranded.map((row) => row.id).toSet(),
        reason: 'only the interrupted winner carries `release_started_at`',
      );

      // A subsequent pull that delivers NOTHING new: the cursor is already past
      // both transport seqs, so the server re-serves neither op. If the fix
      // leaned on a re-served predecessor re-running the scan, this would strand
      // the successor for ever — the durable re-arm is what replays it.
      await a.client.pull();

      expect(await a.client.quarantined(includeReleased: false), isEmpty,
          reason: 'the re-arm replayed and released the successor');
      expect(await _reArmMarked(a), isEmpty,
          reason: 'a clean scan clears the marker');
      expect(await _replayDoc(a, workspace), {'step': 'two'},
          reason: 'the successor applied over its predecessor');
      expect(
        (await _alarmOfKind(a.client, IntegrityAlarmKind.authorChainGap)).resolvedAt,
        isNotNull,
        reason: 'nothing is missing any more',
      );
    });

    test('the re-arm marker is durable: an interrupted replay survives a restart '
        'so a relaunched client re-arms from disk, not a lost in-memory flag',
        () async {
      final faults = FaultInjectingInterceptor();
      final workspace = await SimWorkspace.create(
        deviceCount: 1,
        server: server,
        aSyncStoreInterceptor: faults,
        fileBacked: true,
      );
      addTearDown(workspace.close);
      final a = workspace.a;
      final peer = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 71)),
      );
      final peerSession = await _enrolPeer(workspace, peer);
      await stageReorderedPair(workspace, peer, peerSession);

      faults.failNthInsertInto('op_log', 2);
      await expectLater(a.client.pull(), throwsA(isA<SqliteException>()));

      // Process death: reopen the store over the same file. The transient retry
      // flag dies with the old client, so only the durable marker can re-arm.
      final reopened = await a.reopenSyncStore();
      final onDisk = await (a.syncStore.select(a.syncStore.quarantinedOps)
            ..where((row) =>
                row.releasedAt.isNull() & row.releaseStartedAt.isNotNull()))
          .get();
      expect(onDisk, hasLength(1),
          reason: '`release_started_at` survived the reopen, so the row still '
              'reads "a release started that never finished" — the exact '
              'predicate the next pull re-arms on');
      expect(onDisk.single.reason, SyncRejectionReason.authorChainGap.code);
      expect(await reopened.quarantined(includeReleased: false), hasLength(1),
          reason: 'the reopened client still surfaces the unreleased claimant');
    });

    test('a cross-author prune winner whose attested-author replay faults still '
        'recovers the other author on the next pull, though only the prune '
        'author is marked (#620)', () async {
      final faults = FaultInjectingInterceptor();
      final workspace = await SimWorkspace.create(
        deviceCount: 1,
        server: server,
        aSyncStoreInterceptor: faults,
      );
      addTearDown(workspace.close);
      final a = workspace.a;

      // Two owner peers. `pruner` authors a prune that *also* attests `subject`'s
      // withheld position, so releasing the prune as a scan winner re-enters
      // `_receivePrune`, whose attested-author loop marks `subject` **inside** the
      // enclosing #620 replay transaction — the exact nesting the review flags.
      final pruner = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 11)),
      );
      final subject = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 151)),
      );
      final prunerSession = await _enrolPeer(workspace, pruner);
      final subjectSession = await _enrolPeer(workspace, subject);

      // `subject`'s chain: a predecessor withheld for good (the pruned op) and a
      // successor chained onto it that gaps until the prune attests the hole.
      final subjectPred = await _peerOp(workspace, subject, 'subject-pred');
      final subjectSucc = await _peerOp(workspace, subject, 'subject-succ');
      final subjectPosts = await subjectSession
          .postOps(workspace.workspaceId, [subjectPred, subjectSucc]);
      final subjectPredSeq = subjectPosts[0].seq;
      final subjectSuccSeq = subjectPosts[1].seq;

      // `pruner`'s chain: a head content op (author_seq 3) and, chained onto it, a
      // prune (author_seq 4) whose one target attests `subject`'s withheld
      // author_seq 3 with its genuine envelope hash — the hash `subject-succ`'s
      // `prev_author_hash` already carries, so the attestation makes it valid.
      final prunerHead = await _peerOp(workspace, pruner, 'pruner-head');
      final prune = await pruner.nextEnvelope(
        workspace.workspaceId,
        opClass: opClassPrune,
        payload: PrunePayload(
          compactionOpId: const Uuid().v4(),
          targets: [
            PruneTarget(
              seq: subjectPredSeq,
              authorMemberId: subject.memberId,
              authorSeq: 3,
              envelopeHash: envelopeHash(subjectPred),
            ),
          ],
        ).encode(),
      );
      final prunerPosts =
          await prunerSession.postOps(workspace.workspaceId, [prunerHead]);
      final prunerHeadSeq = prunerPosts[0].seq;
      // The prune is injected rather than posted: the fake server's POST-path
      // `_verifyPrune` demands a materialised compaction to back it, which is a
      // server-door concern orthogonal to the client re-arm under test. The client
      // still verifies the prune in full (signature, chain, attestation).
      final pruneSeq = server.injectUnchecked(workspace.workspaceId, prune);

      // Withhold `subject`'s predecessor (the pruned op), and serve the rest in one
      // page as successor (gaps), prune (gaps), then pruner-head — whose arrival
      // advances the pruner head and drives the release scan, prune winner and all.
      server.omitSeqs.add(subjectPredSeq);
      server.serveOrder = [subjectSuccSeq, pruneSeq, prunerHeadSeq];

      // op_log inserts in the driving pull: pruner-head (1st), the prune replay
      // (2nd), the subject-successor replay (3rd) — the write to interrupt.
      faults.failNthInsertInto('op_log', 3);
      await expectLater(a.client.pull(), throwsA(isA<SqliteException>()));
      expect(faults.firedCount, 1,
          reason: 'the attested-author replay was interrupted');

      // The premise the review rests on holds: the rolled-back replay transaction
      // took the subject's marker with it, so ONLY the prune author carries
      // `release_started_at` — the subject is not independently enumerable.
      final marked = await _reArmMarked(a);
      expect(marked.map((row) => row.authorMemberId).toSet(), {pruner.memberId},
          reason: 'only the prune winner is marked; the attested author is not');

      // The rollback left both the prune winner and the attested author's
      // successor unreleased claimants — the state the recovery pull must clear.
      final stranded = await a.client.quarantined(includeReleased: false);
      expect(stranded.map((row) => row.authorMemberId).toSet(),
          {pruner.memberId, subject.memberId},
          reason: 'the prune and the attested successor are both stranded');

      // The conclusion the review draws — "the subject is never retried" — does not
      // follow: the prune author IS marked, and re-driving its scan re-applies the
      // prune, whose attested-author loop re-releases the subject. The server
      // re-serves nothing (the cursor is already past every seq), so the re-arm is
      // the only thing that can drive this.
      faults.disarm();
      await a.client.pull();
      expect(await a.client.quarantined(includeReleased: false), isEmpty,
          reason: 'the prune-author re-drive re-released the attested author');
      expect(await _reArmMarked(a), isEmpty,
          reason: 'a clean scan clears the marker');
    });

    test('a standing fork never carries the marker, so repeated pulls do not '
        're-run the scan or inflate its occurrence count (AC#4)', () async {
      final workspace = await SimWorkspace.create(deviceCount: 1, server: server);
      addTearDown(workspace.close);
      final a = workspace.a;
      final peer = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 53)),
      );
      final peerSession = await _enrolPeer(workspace, peer);

      // Head at the peer's first content position (author_seq 3).
      const firstContentSeq = 3;
      final head = await _peerOp(workspace, peer, 'head');
      await peerSession.postOps(workspace.workspaceId, [head]);
      await a.client.pull();
      final headHash = envelopeHash(head);

      // A successor at author_seq 5 chained to a predecessor at 4 that never
      // arrives → quarantines as a gap.
      await _peerOp(workspace, peer, 'never-arrives'); // author_seq 4, withheld
      final successor = await _peerOp(workspace, peer, 'successor'); // author_seq 5
      workspace.server.injectUnchecked(workspace.workspaceId, successor);
      await a.client.pull();

      // A validly signed alternate at author_seq 4 chained to the real head, so
      // the head advances to 4 and the successor at 5 becomes a *fork* claimant:
      // its `prev_author_hash` names the never-arriving predecessor, not the
      // alternate now occupying seq 4.
      peer.nextAuthorSeq = firstContentSeq + 1;
      peer.lastEnvelopeHash = headHash;
      final alternate = await _peerOp(workspace, peer, 'alternate');
      workspace.server.injectUnchecked(workspace.workspaceId, alternate);
      await a.client.pull();

      final forkBefore =
          await _alarmOfKind(a.client, IntegrityAlarmKind.authorChainFork);
      expect(forkBefore.resolvedAt, isNull, reason: 'the fork stands');
      expect(await _reArmMarked(a), isEmpty,
          reason: 'a fork claimant is never selected as a winner, so it is never '
              'marked — the re-arm predicate cannot match it');

      // Repeated pulls that deliver nothing new must neither re-run the scan nor
      // re-raise the fork alarm. This fails if the marker were written for a
      // non-winner, or if the re-arm predicate matched any unreleased gap row.
      final occurrenceBefore = forkBefore.occurrenceCount;
      await a.client.pull();
      await a.client.pull();
      await a.client.pull();
      final forkAfter =
          await _alarmOfKind(a.client, IntegrityAlarmKind.authorChainFork);
      expect(forkAfter.occurrenceCount, occurrenceBefore,
          reason: 'the standing fork does not churn: its occurrence count is '
              'stable across pulls');
      expect(await _reArmMarked(a), isEmpty);
    });
  });
}
