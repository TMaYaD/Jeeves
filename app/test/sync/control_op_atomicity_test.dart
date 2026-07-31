/// #618: a control op is applied atomically across a crash, and a re-served op
/// resumes rather than accusing an honest peer.
///
/// `SyncClient._receive` used to apply a control op in four separate writes — log,
/// authority effect, applied-control record, applied stamp — with no enclosing
/// transaction. A process death between any two left a partial apply; the pull
/// cursor is saved only after `_receive` returns, so the op was re-served, its
/// `op_log` row was already there, and `_logReceived` mislabelled that as a taken
/// author-chain slot: a false `author_chain_slot_collision` against an honest
/// author, and an op stuck unapplied for ever. The rotate is the sharpest case,
/// because its floor raise is durable state of its own.
///
/// The fix commits the `op_log` row first (evidence), then lands the authority
/// effects and the applied stamp in one transaction, and teaches `_logReceived` to
/// tell "my own bytes, re-served" from "the server put two ops in one slot". The
/// crash is staged at the store (a bad disk) rather than behind a seam in the
/// client, so the client runs its real code — see [StoreWriteFault].
///
/// The *other* half of the slot-collision distinction — the alarm still firing on a
/// genuine double-serve — is asserted here too, and again in
/// `chain_integrity_test.dart`'s "refuses a second op served under a seq it has
/// already spent", so both halves are covered distinctly.
@TestOn('!browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/chain_verifier.dart';
import 'package:jeeves/sync/control_payload.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/recovery_escrow.dart';
import 'package:jeeves/sync/root_authority.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:sqlite3/common.dart' show SqliteException;
import 'package:uuid/uuid.dart';

import 'harness/author_fixture.dart';
import 'harness/fake_sync_server.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';
import 'harness/store_fault.dart';

const String _collection = 'harness_docs';
const Uuid _uuid = Uuid();

/// Every non-quarantined applied-control record for [workspaceId] — the count
/// that must not grow under a re-serve, filtered in Dart to keep the query a
/// single condition.
Future<List<AppliedControlRow>> _appliedControlRows(
  SyncDatabase store,
  String workspaceId,
) async {
  final rows = await (store.select(store.appliedControlLog)
        ..where((row) => row.workspaceId.equals(workspaceId)))
      .get();
  return [for (final row in rows) if (row.quarantinedAt == null) row];
}

/// The non-quarantined applied-control records of one [controlType].
Future<List<AppliedControlRow>> _appliedOfType(
  SyncDatabase store,
  String workspaceId,
  String controlType,
) async {
  final rows = await _appliedControlRows(store, workspaceId);
  return [for (final row in rows) if (row.controlType == controlType) row];
}

/// The `op_log` row carrying the control op of [controlType], or null.
Future<OpLogRow?> _loggedControlOfType(
  SyncDatabase store,
  String workspaceId,
  String controlType,
) async {
  final rows = await (store.select(store.opLog)
        ..where((row) => row.workspaceId.equals(workspaceId)))
      .get();
  for (final row in rows) {
    final parts = splitEnvelope(row.envelope);
    if (OpHeader.parse(parts.header).opClass != opClassControl) continue;
    if (ControlPayload.decode(parseBody(parts.body)).controlType == controlType) {
      return row;
    }
  }
  return null;
}

/// The alarm kinds this device holds, unresolved or not.
Future<Set<String>> _alarmKinds(SyncClient client) async =>
    {for (final alarm in await client.integrityAlarms()) alarm.kind};

/// Recover Root the way a device would — fetch the escrow slot, unwrap it with the
/// passphrase — so a test that authors a Grant does it through a genuine Root
/// rather than a key handed to it.
Future<RootAuthority> _recoverRoot(SimDevice device, FakeSyncServer server) async {
  final record = await server
      .connectAsUser(device.userId)
      .fetchRecoveryEscrow(device.client.workspaceId);
  final secrets = await unwrapEscrowBlob(
    blob: record!.blob,
    passphrase: device.outcome.passphrase,
    floor: harnessKdfParameters,
  );
  return RootAuthority.fromSecretKey(secrets.rootSecretKey);
}

/// A Root-signed owner Grant of [device] to itself, authored and posted but not
/// applied — a non-rotate control op the applying pull can be interrupted on.
Future<String> _authorSelfGrant(SimDevice device, FakeSyncServer server) async {
  final root = await _recoverRoot(device, server);
  final grantId = _uuid.v4();
  try {
    final certificate = GrantCertificate(
      workspaceId: device.client.workspaceId,
      grantId: grantId,
      memberId: device.identity.memberId,
      role: roleOwner,
      granter: granterRoot,
      grantedAtHlc: Hlc.forMember(device.identity.memberId, device.clock.nowMs),
    );
    final certBytes = certificate.encode();
    final payload = ControlPayload(
      controlType: controlTypeGrant,
      prevControlHash: await device.client.appliedControlHead(),
      certBytes: certBytes,
      signature: await root.signGrantCertificateBytes(certBytes),
      authority: granterRoot,
    ).encode();
    await device.client.captureControl(payload);
    await device.client.flushOutbox();
    return grantId;
  } finally {
    root.drop();
  }
}

String _docId(String workspaceId) =>
    _uuid.v5(jeevesWorkspaceNamespace, '$workspaceId/atomicity-doc');

/// One content op from [author] on a shared entity — the double-serve half needs
/// two independently valid envelopes contending for one slot.
Future<Uint8List> _contentOp(
  SimWorkspace workspace,
  AuthorFixture author,
  Object? value,
) async {
  workspace.clock.advance(10);
  return author.nextEnvelope(
    workspace.workspaceId,
    payloadJson: jsonEncode({
      'collection': _collection,
      'id': _docId(workspace.workspaceId),
      'fields': {
        'step': {'v': value},
      },
      'hlc': [workspace.clock.nowMs, 0, memberIdToHex(author.memberId)],
    }),
  );
}

void main() {
  group('control-op apply is atomic and resumable across a crash', () {
    test(
        're-serving already-applied control ops raises no slot-collision alarm '
        'and never advances the control chain head twice', () async {
      final device = await SimDevice.create(
        label: 'A',
        userId: 'atomicity-replay-user',
        server: FakeSyncServer(),
        clock: FakeClock(simulationStartWallMs),
      );
      addTearDown(device.close);
      await device.enrolment
          .turnOnEncryption(passphrase: device.outcome.passphrase);
      await device.sync();
      expect(await device.client.epochFloor(), 1);

      final workspaceId = device.client.workspaceId;
      final before = await _appliedControlRows(device.store, workspaceId);
      expect(
        before.map((row) => row.controlType),
        containsAll(<String>[controlTypeWorkspaceGenesis, controlTypeRotate]),
        reason: 'genesis and the rotate are applied control ops to re-serve',
      );

      // The pull cursor never advanced past them — a crash after apply, before the
      // cursor saved — so the whole log is re-served on the next pull.
      await device.client.resetCursorForReplay();
      await device.client.pull();

      expect(
        await _alarmKinds(device.client),
        isNot(contains(IntegrityAlarmKind.authorChainSlotCollision.code)),
        reason: 'a device re-serving its own logged control op is not a server '
            'double-serving a slot',
      );
      expect(
        (await _appliedControlRows(device.store, workspaceId)).length,
        before.length,
        reason: 'no re-served control op advanced the head a second time',
      );
      expect(await device.client.epochFloor(), 1,
          reason: 'the floor stands, unraised a second time');
      expect(await device.client.quarantined(includeReleased: false), isEmpty);
    });

    test('a genuinely double-served slot still raises the slot-collision alarm',
        () async {
      final workspace = await SimWorkspace.create(deviceCount: 1);
      addTearDown(workspace.close);
      final peer = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (byte) => byte + 7)),
      );
      final peerSession = await workspace.enrolFixture(peer);

      final first = await _contentOp(workspace, peer, 'one');
      final second = await _contentOp(workspace, peer, 'two');
      final appended = await peerSession.postOps(workspace.workspaceId, [first]);
      // A *different* chain-valid envelope forced onto the seq the first already
      // spent: the log must keep the first and accuse, not overwrite.
      workspace.server.injectUnchecked(
        workspace.workspaceId,
        second,
        atSeq: appended.single.seq,
      );

      await workspace.a.sync();

      expect(
        await _alarmKinds(workspace.a.client),
        contains(IntegrityAlarmKind.authorChainSlotCollision.code),
        reason: 'two different envelopes at one slot is a server-integrity event',
      );
    });

    test(
        'a rotate interrupted between the floor raise and the applied-control '
        'append converges on the next pull', () async {
      final fault = StoreWriteFault('applied_control_log');
      final device = await SimDevice.create(
        label: 'R',
        userId: 'atomicity-rotate-user',
        server: FakeSyncServer(),
        clock: FakeClock(simulationStartWallMs),
        fileBacked: true,
        storeFault: fault,
      );
      addTearDown(device.close);
      await device.sync();
      final workspaceId = device.client.workspaceId;
      expect(await device.client.epochFloor(), 0);

      // Kill the applied-control append. `turnOnEncryption` authors and flushes
      // the rotate and publishes the wraps, then pulls to apply it — and it is
      // that pull, inside `_applyControlOp`, that raises the floor and attempts
      // the append the armed fault fails.
      fault.armed = true;
      await expectLater(
        device.enrolment.turnOnEncryption(passphrase: device.outcome.passphrase),
        throwsA(isA<SqliteException>()),
      );
      expect(fault.fired, isTrue,
          reason: 'the applied-control append was actually interrupted');

      // Atomicity, before any reopen: the floor raise rolled back with the append
      // it shared a transaction with, and no applied-control record exists for the
      // rotate. The `op_log` row does — committed before the apply, as evidence,
      // so the re-serve resumes rather than re-fetching.
      expect(await device.client.epochFloor(), 0,
          reason: 'a raised floor with no applied-control record is exactly what '
              'the transaction rules out');
      expect(await _appliedOfType(device.store, workspaceId, controlTypeRotate),
          isEmpty);
      final loggedRotate =
          await _loggedControlOfType(device.store, workspaceId, controlTypeRotate);
      expect(loggedRotate, isNotNull,
          reason: 'the rotate is logged evidence even though its apply was cut off');
      expect(loggedRotate!.appliedAt, isNull);
      expect(loggedRotate.refusedReason, isNull,
          reason: 'neither applied nor refused: an apply still owed, to resume');

      // Process death: reopen the store and pull again.
      final reopened = await device.reopenSyncStore();
      expect(await reopened.epochFloor(), 0,
          reason: 'the interrupted state persisted across the restart');
      await reopened.pull();

      expect(await reopened.epochFloor(), 1,
          reason: 'the re-served rotate applied on recovery');
      expect(
        (await _appliedOfType(device.store, workspaceId, controlTypeRotate)).length,
        1,
        reason: 'the applied-control log holds no duplicate — the head advanced '
            'exactly once for a re-served op',
      );
      expect(
        (await _loggedControlOfType(
                device.store, workspaceId, controlTypeRotate))!
            .appliedAt,
        isNotNull,
      );
      expect(
        await _alarmKinds(reopened),
        isNot(contains(IntegrityAlarmKind.authorChainSlotCollision.code)),
        reason: 'recovery accuses nobody',
      );
      expect(await reopened.quarantined(includeReleased: false), isEmpty);
    });

    test(
        'a non-rotate control op interrupted before its applied-control append '
        'converges on the next pull', () async {
      final server = FakeSyncServer();
      final fault = StoreWriteFault('applied_control_log');
      final device = await SimDevice.create(
        label: 'G',
        userId: 'atomicity-grant-user',
        server: server,
        clock: FakeClock(simulationStartWallMs),
        fileBacked: true,
        storeFault: fault,
      );
      addTearDown(device.close);
      await device.sync();
      final workspaceId = device.client.workspaceId;

      final grantId = await _authorSelfGrant(device, server);
      expect(
        (await device.client.grants()).map((grant) => grant.grantId),
        isNot(contains(grantId)),
        reason: 'the grant is authored and posted but not yet applied',
      );

      fault.armed = true;
      await expectLater(
        device.client.pull(),
        throwsA(isA<SqliteException>()),
      );
      expect(fault.fired, isTrue);

      // The grant's only durable effect is its applied-control record, and it did
      // not land; its `op_log` row did.
      expect(await _appliedOfType(device.store, workspaceId, controlTypeGrant),
          hasLength(1),
          reason: 'only the enrolment owner Grant is applied; the new one is not');
      expect(
        (await device.client.grants()).map((grant) => grant.grantId),
        isNot(contains(grantId)),
      );

      final reopened = await device.reopenSyncStore();
      // Recover through the *whole device*, not just the returned client: a
      // relaunch reopens the store and runs its entire stack over it, so
      // `device.sync()` (which drives the rebuilt per-Workspace factory as well
      // as the default client) must reach the reopened store rather than the
      // closed one it replaced.
      await device.sync();

      expect(
        (await reopened.grants()).map((grant) => grant.grantId),
        contains(grantId),
        reason: 'the re-served grant applied on recovery',
      );
      expect(await _appliedOfType(device.store, workspaceId, controlTypeGrant),
          hasLength(2),
          reason: 'the applied-control log holds the grant exactly once');
      expect(
        await _alarmKinds(reopened),
        isNot(contains(IntegrityAlarmKind.authorChainSlotCollision.code)),
      );
      expect(await reopened.quarantined(includeReleased: false), isEmpty);
    });
  });
}
