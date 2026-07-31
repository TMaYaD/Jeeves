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

import 'dart:typed_data';

import 'package:drift/drift.dart'
    show BooleanExpressionOperators, OrderingTerm, Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/compaction.dart';
import 'package:jeeves/sync/control_payload.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/ids.dart';
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
}
