/// #996: a control op refused as `control_chain_break` because the control op
/// before it had not been applied yet is re-examined once that predecessor is
/// applied.
///
/// The case arises behind #988's defect: a device with an empty directory
/// refuses a peer's revoke/rotate as `member_not_chained_to_root`, and a device
/// that enrols afterwards posts a registration naming that rotate as its
/// predecessor. The registration verifies against its own certificate, so it
/// reaches the position check, finds a head it does not name, and is refused as
/// `control_chain_break` — logged-but-refused, so the `op_log` slot is taken.
///
/// The rules this file pins down:
///
///  * Once the predecessor is applied, the refused op is applied through the
///    ordinary control pipeline, in the same pull.
///  * Every other check still runs on the re-examination: a fork is resolved,
///    not skipped.
///  * An op that names no real predecessor stays refused and is never touched.
///  * A row the User has refused for good is not examined at all.
@TestOn('!browser')
library;

import 'dart:typed_data';

import 'package:drift/drift.dart'
    show BooleanExpressionOperators, OrderingTerm, Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/alarm_resolution.dart';
import 'package:jeeves/sync/chain_verifier.dart';
import 'package:jeeves/sync/control_payload.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/domain_projector.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/host/merge_state.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_health_detail.dart';

import 'harness/author_fixture.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';

final String _breakCode = SyncRejectionReason.controlChainBreak.code;

/// The collection D writes in, and the entity it writes.
const String _collection = 'harness_docs';
const String _docId = '33333333-3333-4333-8333-333333333333';

/// The reduced fields of one entity on [device]'s **live** store.
///
/// [SimDevice.registry] is bound to the database that was open before the
/// reopen, so a test that reopened the store has to read through a registry
/// bound to the reopened one — the pre-crash handle is closed.
Future<Map<String, Object?>?> _entity(SimDevice device, String entityId) async =>
    CollectionRegistry(device.syncStore)
        .register(_collection)
        .readEntity(entityId);

/// The control types applied on [device]'s live store, in transport order.
Future<List<AppliedControlRow>> _applied(SimDevice device) async =>
    (device.syncStore.select(device.syncStore.appliedControlLog)
          ..where((row) => row.workspaceId.equals(device.client.workspaceId))
          ..orderBy([(row) => OrderingTerm(expression: row.seq)]))
        .get();

Future<List<QuarantineRow>> _breakRows(SyncClient client) async =>
    (await client.quarantined())
        .where((row) => row.reason == _breakCode)
        .toList();

/// Three synced devices, the third revoked and the rotation published by A, with
/// B relaunched on a build that does not restore its directory and a fourth
/// device D enrolled afterwards.
class _Scene {
  _Scene(this.workspace, this.broken, this.dFixture);
  final SimWorkspace workspace;
  final SyncClient broken;
  final AuthorFixture dFixture;
}

Future<_Scene> _scene() async {
  final workspace = await SimWorkspace.create(deviceCount: 3, fileBacked: true);
  addTearDown(workspace.close);
  final a = workspace.a;
  final b = workspace.b;
  await a.enrolment.turnOnEncryption(passphrase: workspace.passphrase);
  await workspace.syncAll();

  final broken = await b.reopenSyncStore(
    attachTransport: true,
    restoreChainedMembers: false,
  );
  await a.enrolment.revokeAndRotate(
    passphrase: workspace.passphrase,
    memberId: workspace.devices[2].identity.memberId,
  );
  await a.sync();

  // D enrols after the rotate: its registration names the rotate as its
  // predecessor, which `broken` has refused as unchained.
  final d = await AuthorFixture.create(
    seed: Uint8List.fromList(List<int>.filled(32, 0x5d)),
  );
  await workspace.enrolFixture(d);
  await broken.pull();
  return _Scene(workspace, broken, d);
}

/// Inject one storage failure at the real projection boundary.
class _FailingOnceProjector extends DomainProjector {
  _FailingOnceProjector(DomainProjector inner)
      : super(registry: inner.registry, domain: inner.domain);

  Set<AffectedEntity>? failedAffected;
  Set<AffectedEntity>? retriedAffected;

  @override
  Future<Set<String>> project(
    Iterable<AffectedEntity> affected, {
    bool leaveEntitiesAwaitingMerge = false,
  }) async {
    final entities = affected.toSet();
    if (failedAffected == null) {
      failedAffected = entities;
      throw StateError('projection storage failure');
    }
    retriedAffected = entities;
    return super.project(
      entities,
      leaveEntitiesAwaitingMerge: leaveEntitiesAwaitingMerge,
    );
  }
}

void main() {
  group('a control op refused as control_chain_break heals', () {
    test('a registration refused behind an unchained revoke is applied once '
        'the revoke is', () async {
      final scene = await _scene();
      final b = scene.workspace.b;
      final dId = scene.dFixture.memberId;

      final held = (await _breakRows(scene.broken))
          .where((row) => row.releasedAt == null)
          .toList();
      expect(held.where((row) => row.authorMemberId == dId), hasLength(1),
          reason: 'D\'s registration is refused for the missing predecessor');
      expect(scene.broken.directory.isChained(dId), isFalse);

      final fixed = await b.reopenSyncStore(attachTransport: true);
      await fixed.pull();

      // The registration is applied in the pull that recovers its predecessor:
      // the two scans feed each other, so one pull is enough.
      final row = (await _breakRows(fixed))
          .singleWhere((row) => row.authorMemberId == dId);
      expect(row.id, held.singleWhere((r) => r.authorMemberId == dId).id);
      expect(row.releasedAt, isNotNull);
      expect(fixed.directory.isChained(dId), isTrue);
      expect(
        (await _applied(b)).where((r) =>
            r.controlType == controlTypeMemberRegister &&
            ControlPayload.decode(r.payloadBytes).certificate().memberId == dId),
        hasLength(1),
      );
      final opLogRow = await (b.syncStore.select(b.syncStore.opLog)
            ..where((r) =>
                r.workspaceId.equals(fixed.workspaceId) & r.seq.equals(row.seq!)))
          .getSingle();
      expect(opLogRow.appliedAt, isNotNull);
      expect(opLogRow.refusedReason, isNull);
      expect(
        (await fixed.quarantined(includeReleased: false))
            .where((r) => r.authorMemberId == dId),
        isEmpty,
      );

      // A second pull changes nothing: the refusal is dealt with, and the
      // registration is applied.
      await fixed.pull();
      final after = (await _breakRows(fixed)).singleWhere((r) => r.id == row.id);
      expect(after.releasedAt, row.releasedAt);
      expect(fixed.directory.isChained(dId), isTrue);
      expect(
        (await _applied(b)).where((r) =>
            r.controlType == controlTypeMemberRegister &&
            ControlPayload.decode(r.payloadBytes).certificate().memberId == dId),
        hasLength(1),
      );
    });

    test('a device that lost its epoch key fetches it again after a restart',
        () async {
      final scene = await _scene();
      final b = scene.workspace.b;

      final fixed = await b.reopenSyncStore(attachTransport: true);
      await fixed.pull();
      final floor = await fixed.epochFloor();
      expect(floor, greaterThan(0),
          reason: 'the recovered rotate raised the epoch floor');
      expect(await fixed.workspaceKeys.keyFor(fixed.workspaceId, floor),
          isNotNull,
          reason: 'the pull that applied the rotate fetched the wraps');

      // The key is gone, as it would be if the process had exited between the
      // rotate applying and the wrap being fetched. The flag that owed that
      // fetch is memory, so a restart does not carry it.
      await fixed.workspaceKeys.clear(fixed.workspaceId);
      expect(await fixed.workspaceKeys.keyFor(fixed.workspaceId, floor), isNull);

      final restarted = await b.reopenSyncStore(attachTransport: true);
      await restarted.pull();

      expect(
          await restarted.workspaceKeys.keyFor(restarted.workspaceId, floor),
          isNotNull,
          reason: 'a device at a keyed epoch it cannot read fetches that '
              'epoch\'s wraps on its next pull');
    });

    test('rows with no real predecessor stay refused and untouched', () async {
      final workspace =
          await SimWorkspace.create(deviceCount: 3, fileBacked: true);
      addTearDown(workspace.close);
      final b = workspace.b;
      await workspace.a.enrolment.turnOnEncryption(
        passphrase: workspace.passphrase,
      );
      await workspace.syncAll();

      final root = await workspace.recoverRoot();
      final zeroLinked = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.filled(32, 0x71)),
      );
      final randomLinked = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.filled(32, 0x72)),
      );
      for (final entry in [
        (zeroLinked, zeroPrevControlHash),
        (randomLinked, Uint8List.fromList(List<int>.filled(32, 0x99))),
      ]) {
        workspace.server.injectUnchecked(
          workspace.workspaceId,
          await memberRegisterEnvelope(
            device: entry.$1,
            workspaceId: workspace.workspaceId,
            root: root,
            prevControlHash: entry.$2,
            wallMs: workspace.clock.nowMs,
          ),
        );
      }
      root.drop();
      await b.sync();
      final before = (await _breakRows(b.client))
          .map((row) => row.id)
          .toList()
        ..sort();
      expect(before, hasLength(2));

      // Move the head, then relaunch: neither row may be touched.
      await workspace.a.enrolment.revokeAndRotate(
        passphrase: workspace.passphrase,
        memberId: workspace.devices[2].identity.memberId,
      );
      await workspace.a.sync();
      await b.sync();
      final reopened = await b.reopenSyncStore(attachTransport: true);
      await reopened.pull();
      await reopened.pull();

      final after = await _breakRows(reopened);
      expect(after.map((row) => row.id).toList()..sort(), before);
      expect(after.every((row) => row.releasedAt == null), isTrue);
      expect(reopened.directory.isChained(zeroLinked.memberId), isFalse);
      expect(reopened.directory.isChained(randomLinked.memberId), isFalse);
    });

    test('a refused slot holding different bytes is not taken back', () async {
      final scene = await _scene();
      final b = scene.workspace.b;
      final dId = scene.dFixture.memberId;
      final held = (await _breakRows(scene.broken)).singleWhere(
          (row) => row.authorMemberId == dId && row.releasedAt == null);
      final seq = held.seq!;

      // Put a different envelope into the refused slot, as a forged or
      // corrupted copy would be.
      final slot = await (b.syncStore.select(b.syncStore.opLog)
            ..where((r) =>
                r.workspaceId.equals(scene.broken.workspaceId) &
                r.seq.equals(seq)))
          .getSingle();
      final different = Uint8List.fromList(slot.envelope)
        ..[slot.envelope.length - 1] ^= 0xff;
      await (b.syncStore.update(b.syncStore.opLog)
            ..where((r) =>
                r.workspaceId.equals(scene.broken.workspaceId) &
                r.seq.equals(seq)))
          .write(OpLogCompanion(envelope: Value(different)));

      final fixed = await b.reopenSyncStore(attachTransport: true);
      await fixed.pull();
      await fixed.pull();

      final after = await (b.syncStore.select(b.syncStore.opLog)
            ..where((r) =>
                r.workspaceId.equals(fixed.workspaceId) & r.seq.equals(seq)))
          .getSingle();
      expect(after.envelope, different);
      expect(after.appliedAt, isNull);
      expect(after.refusedReason, _breakCode);
      expect(
        (await _breakRows(fixed)).singleWhere((r) => r.id == held.id).releasedAt,
        isNull,
      );
    });

    test('a second registration naming the same predecessor is settled as a '
        'fork, not skipped', () async {
      final scene = await _scene();
      final b = scene.workspace.b;
      final dId = scene.dFixture.memberId;

      final held = (await _breakRows(scene.broken)).singleWhere(
          (row) => row.authorMemberId == dId && row.releasedAt == null);
      final predecessor = ControlPayload.decode(
        parseBody(splitEnvelope(held.envelope).body),
      ).prevControlHash;

      // A newcomer whose registration names the same predecessor as D's: two
      // registrations, one position. Its certificate is stamped later than D's,
      // so the fork tie-break — earliest certificate HLC — settles it against
      // the newcomer, whoever is examined first.
      final e = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.filled(32, 0x6e)),
      );
      final root = await scene.workspace.recoverRoot();
      final wallMs = scene.workspace.clock.nowMs + 1000;
      scene.workspace.server.injectUnchecked(
        scene.workspace.workspaceId,
        await memberRegisterEnvelope(
          device: e,
          workspaceId: scene.workspace.workspaceId,
          root: root,
          prevControlHash: predecessor,
          wallMs: wallMs,
          certificate: RegistrationCertificate(
            workspaceId: scene.workspace.workspaceId,
            memberId: e.memberId,
            signPk: e.signPk,
            kexPk: e.kexPk,
            registeredAtHlc: Hlc.forMember(e.memberId, wallMs),
          ),
        ),
      );
      root.drop();
      await scene.broken.pull();

      expect(
        (await _breakRows(scene.broken))
            .where((row) => row.authorMemberId == e.memberId && row.releasedAt == null),
        hasLength(1),
        reason: 'the newcomer is refused for the missing predecessor too',
      );

      final fixed = await b.reopenSyncStore(attachTransport: true);
      await fixed.pull();
      await fixed.pull();

      // Exactly one of the two registrations holds the position: the other is
      // settled by the fork, not left for a later pull.
      final registered = (await _applied(b))
          .where((row) => row.controlType == controlTypeMemberRegister)
          .map((row) => ControlPayload.decode(row.payloadBytes).certificate().memberId)
          .toSet();
      expect(registered.contains(dId), isTrue);
      expect(registered.contains(e.memberId), isFalse,
          reason: 'the later certificate loses the tie-break');

      final loser = (await _breakRows(fixed))
          .singleWhere((row) => row.authorMemberId == e.memberId);
      expect(loser.releasedAt, isNotNull,
          reason: 'the row left the scan set under its own reason');
      final fork = (await fixed.quarantined(includeReleased: false)).singleWhere(
          (row) =>
              row.reason == SyncRejectionReason.controlChainFork.code &&
              row.seq == loser.seq);
      expect(fork.releasedAt, isNull);
      final alarms = await fixed.integrityAlarms();
      expect(
        alarms.any((alarm) => alarm.kind == IntegrityAlarmKind.controlChainFork.code),
        isTrue,
        reason: 'a fork is an accusation, and it is raised',
      );
    });

    test('a registration served below the op it names is not admitted',
        () async {
      final workspace =
          await SimWorkspace.create(deviceCount: 3, fileBacked: true);
      addTearDown(workspace.close);
      final b = workspace.b;
      await workspace.a.enrolment.turnOnEncryption(
        passphrase: workspace.passphrase,
      );
      await workspace.syncAll();

      final root = await workspace.recoverRoot();
      final headHash = (await _applied(b)).last.payloadHash;

      // P: a registration for D, naming the head the device holds.
      final d = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.filled(32, 0x64)),
      );
      final pEnvelope = await memberRegisterEnvelope(
        device: d,
        workspaceId: workspace.workspaceId,
        root: root,
        prevControlHash: headHash,
        wallMs: workspace.clock.nowMs,
      );
      final pHash =
          controlPayloadHash(parseBody(splitEnvelope(pEnvelope).body));

      // F: a registration for E, naming P, and served *below* P. The transport
      // seq is the server's to hand out, so this is a server that reordered: E's
      // op sits in the log before the op it names.
      final e = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.filled(32, 0x65)),
      );
      final fEnvelope = await memberRegisterEnvelope(
        device: e,
        workspaceId: workspace.workspaceId,
        root: root,
        prevControlHash: pHash,
        wallMs: workspace.clock.nowMs,
      );

      // Q: a registration for G, also naming P, and served above it. Q is the
      // applied op that names P, so it is the rival F would be settled against
      // — and F's certificate is the earlier one, so F would win that
      // tie-break and take the position.
      final g = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.filled(32, 0x66)),
      );
      final qEnvelope = await memberRegisterEnvelope(
        device: g,
        workspaceId: workspace.workspaceId,
        root: root,
        prevControlHash: pHash,
        wallMs: workspace.clock.nowMs + 1000,
      );

      final base = workspace.server.storedOps
          .where((op) => op.workspaceId == workspace.workspaceId)
          .map((op) => op.seq)
          .fold(0, (highest, seq) => seq > highest ? seq : highest);
      root.drop();
      workspace.server.injectUnchecked(
        workspace.workspaceId,
        fEnvelope,
        atSeq: base + 1,
      );
      workspace.server.injectUnchecked(
        workspace.workspaceId,
        pEnvelope,
        atSeq: base + 2,
      );
      workspace.server.injectUnchecked(
        workspace.workspaceId,
        qEnvelope,
        atSeq: base + 3,
      );
      // The log now spends seqs the server's own bookkeeping has not reached;
      // hand the rest back so a later append does not collide with them.
      workspace.server.rollbackToSeq(base + 3);

      await b.sync();

      // F was served first, so it was refused for the op it named, which had
      // not been applied yet; P and Q arrived after it and were applied.
      final registered = (await _applied(b))
          .where((row) => row.controlType == controlTypeMemberRegister)
          .map((row) =>
              ControlPayload.decode(row.payloadBytes).certificate().memberId)
          .toSet();
      expect(registered, contains(d.memberId));
      expect(registered, contains(g.memberId));
      expect(
        registered,
        isNot(contains(e.memberId)),
        reason: 'an op below the op it names cannot be applied: the applied '
            'log is ordered by seq, and it would leave the log reading the '
            'op it names as the chain tip',
      );

      // F's row is left exactly as it was: refused, unreleased, untouched.
      final fBreak = (await _breakRows(b.client))
          .singleWhere((row) => row.authorMemberId == e.memberId);
      expect(fBreak.reason, _breakCode);
      expect(fBreak.releasedAt, isNull);
      final fSlot = await (b.syncStore.select(b.syncStore.opLog)
            ..where((r) =>
                r.workspaceId.equals(b.client.workspaceId) &
                r.seq.equals(fBreak.seq!)))
          .getSingle();
      expect(fSlot.appliedAt, isNull);
      expect(fSlot.refusedReason, _breakCode);
      expect(b.client.directory.isChained(e.memberId), isFalse);
      expect(b.client.directory.isChained(d.memberId), isTrue);
    });

    test('a second refusal at the same seq does not stop the first being '
        'reclaimed', () async {
      final scene = await _scene();
      final b = scene.workspace.b;
      final dId = scene.dFixture.memberId;

      final held = (await _breakRows(scene.broken)).singleWhere(
          (row) => row.authorMemberId == dId && row.releasedAt == null);
      final predecessor = ControlPayload.decode(
        parseBody(splitEnvelope(held.envelope).body),
      ).prevControlHash;

      // A second op refused at the same transport seq. The quarantine is filed
      // per **op**, not per slot, so a server that spends one seq twice leaves
      // two rows here — and the row that is examined first is the one whose
      // bytes the slot holds.
      final e = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.filled(32, 0x67)),
      );
      final root = await scene.workspace.recoverRoot();
      final otherEnvelope = await memberRegisterEnvelope(
        device: e,
        workspaceId: scene.workspace.workspaceId,
        root: root,
        prevControlHash: predecessor,
        wallMs: scene.workspace.clock.nowMs,
      );
      final store = scene.workspace.b.syncStore;
      root.drop();
      await store.into(store.quarantinedOps).insert(
            QuarantinedOpsCompanion.insert(
              workspaceId: scene.broken.workspaceId,
              seq: Value(held.seq),
              reason: _breakCode,
              detail: 'a second op refused at the same transport seq',
              envelope: otherEnvelope,
              detectedAt: DateTime.now(),
              authorMemberId: Value(e.memberId),
              authorSeq: const Value(1),
            ),
          );

      final fixed = await b.reopenSyncStore(attachTransport: true);
      await fixed.pull();
      await fixed.pull();

      // The first row's op is applied: the second row at the same seq does not
      // stop it, and the second row is left alone.
      expect(fixed.directory.isChained(dId), isTrue);
      expect(
        (await _applied(b)).where((r) =>
            r.controlType == controlTypeMemberRegister &&
            ControlPayload.decode(r.payloadBytes).certificate().memberId == dId),
        hasLength(1),
      );
      final other = (await _breakRows(fixed))
          .singleWhere((row) => row.authorMemberId == e.memberId);
      expect(other.releasedAt, isNull);
      expect(fixed.directory.isChained(e.memberId), isFalse);
    });

    test('a break whose re-examination is refused for another reason is '
        'released, and is not asked about again', () async {
      final workspace =
          await SimWorkspace.create(deviceCount: 3, fileBacked: true);
      addTearDown(workspace.close);
      final b = workspace.b;
      await workspace.a.enrolment.turnOnEncryption(
        passphrase: workspace.passphrase,
      );
      await workspace.syncAll();

      // A control op authored by a member this device has never seen: its
      // re-examination is refused for want of the author's key, which is a
      // different reason from the one that refused it the first time.
      final x = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.filled(32, 0x78)),
      );
      final head = (await _applied(b)).last;
      final root = await workspace.recoverRoot();
      final envelope = await grantEnvelope(
        device: x,
        workspaceId: workspace.workspaceId,
        root: root,
        prevControlHash: head.payloadHash,
        memberId: x.memberId,
        wallMs: workspace.clock.nowMs,
      );
      root.drop();
      final header = OpHeader.parse(splitEnvelope(envelope).header);

      // The shape the scan reads: the op is logged and refused for the missing
      // predecessor, and the refusal is filed. **Staged at the store level**,
      // because a served stream cannot produce it: an op is logged only once
      // its author is known, and the directory is restored whole from the
      // applied control log, so a re-examination cannot fail for want of a key
      // the device had. What it can do — against a server that serves an op
      // the chain would not — is fail for a reason the slot does not carry.
      final seq = head.seq + 1;
      final store = b.syncStore;
      await store.into(store.opLog).insert(
            OpLogCompanion.insert(
              seq: seq,
              workspaceId: b.client.workspaceId,
              envelope: envelope,
              opId: header.opId,
              authorMemberId: header.authorMemberId,
              authorSeq: header.authorSeq,
              receivedAt: workspace.clock.asDateTime,
              refusedReason: Value(_breakCode),
            ),
          );
      await store.into(store.quarantinedOps).insert(
            QuarantinedOpsCompanion.insert(
              workspaceId: b.client.workspaceId,
              seq: Value(seq),
              reason: _breakCode,
              detail: 'refused for the missing predecessor',
              envelope: envelope,
              detectedAt: workspace.clock.asDateTime,
              authorMemberId: Value(x.memberId),
              authorSeq: Value(header.authorSeq),
            ),
          );

      // The scan runs on the first pull after a launch.
      final reopened = await b.reopenSyncStore(attachTransport: true);
      await reopened.pull();

      // The break is answered: the row is released, and the reason the
      // re-examination found is the one the fresh row carries.
      final released =
          (await _breakRows(reopened)).singleWhere((row) => row.seq == seq);
      expect(released.releasedAt, isNotNull);
      final fresh = (await reopened.quarantined(includeReleased: false))
          .singleWhere((row) => row.seq == seq && row.reason != _breakCode);
      expect(fresh.reason, SyncRejectionReason.memberNotChainedToRoot.code);
      expect(fresh.releasedAt, isNull);
      expect(b.client.directory.isChained(x.memberId), isFalse);

      // And it is not asked about again: the row has left the scan set, so a
      // later pull neither retries it nor raises its accusation a second time.
      final alarmsBefore = (await reopened.integrityAlarms()).length;
      await reopened.pull();
      expect((await reopened.integrityAlarms()).length, alarmsBefore);
      expect(
        (await _breakRows(reopened)).singleWhere((row) => row.seq == seq).releasedAt,
        released.releasedAt,
      );
    });

    test('a break whose replacement refusal was never filed is filed, and the '
        'break is retired', () async {
      final workspace =
          await SimWorkspace.create(deviceCount: 3, fileBacked: true);
      addTearDown(workspace.close);
      final b = workspace.b;
      await workspace.a.enrolment.turnOnEncryption(
        passphrase: workspace.passphrase,
      );
      await workspace.syncAll();

      final applied = await _applied(b);

      // A control op naming an **earlier** applied op: a fork candidate, the
      // shape that reaches the tie-break and can lose it.
      final root = await workspace.recoverRoot();
      final x = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.filled(32, 0x79)),
      );
      final envelope = await memberRegisterEnvelope(
        device: x,
        workspaceId: workspace.workspaceId,
        root: root,
        prevControlHash: applied[applied.length - 2].payloadHash,
        wallMs: workspace.clock.nowMs,
      );
      root.drop();
      final header = OpHeader.parse(splitEnvelope(envelope).header);

      // The state a storage fault leaves behind. The re-examination reached a
      // verdict and the receive transaction stamped it on the slot; the refusal
      // it reached is filed in a second transaction, and that insert faulted.
      // So the slot carries the fork, the refusal is not filed, and the break
      // row is still unreleased.
      //
      // **Staged at the store level**, because the fault itself cannot be
      // staged in a served stream — the same way the re-examination's verdict
      // is staged above.
      final seq = applied.last.seq + 1;
      final store = b.syncStore;
      await store.into(store.opLog).insert(
            OpLogCompanion.insert(
              seq: seq,
              workspaceId: b.client.workspaceId,
              envelope: envelope,
              opId: header.opId,
              authorMemberId: header.authorMemberId,
              authorSeq: header.authorSeq,
              receivedAt: workspace.clock.asDateTime,
              refusedReason: Value(SyncRejectionReason.controlChainFork.code),
            ),
          );
      await store.into(store.quarantinedOps).insert(
            QuarantinedOpsCompanion.insert(
              workspaceId: b.client.workspaceId,
              seq: Value(seq),
              reason: _breakCode,
              detail: 'refused for the missing predecessor',
              envelope: envelope,
              detectedAt: workspace.clock.asDateTime,
              authorMemberId: Value(x.memberId),
              authorSeq: Value(header.authorSeq),
            ),
          );

      // The scan runs on the first pull after a launch.
      final reopened = await b.reopenSyncStore(attachTransport: true);
      await reopened.pull();

      // The replacement refusal is filed, and the break row is retired: the op
      // cannot apply, and the refusal that replaced the break says why.
      final replacement = (await reopened.quarantined(includeReleased: false))
          .singleWhere((row) => row.seq == seq && row.reason != _breakCode);
      expect(replacement.reason, SyncRejectionReason.controlChainFork.code);
      expect(replacement.releasedAt, isNull);
      final retired = (await _breakRows(reopened)).singleWhere((row) => row.seq == seq);
      expect(retired.releasedAt, isNotNull);

      // The accusation stands: a fork is not a row the User can read and
      // ignore, it is an alarm.
      expect(
        (await reopened.integrityAlarms())
            .where((alarm) => alarm.kind == IntegrityAlarmKind.controlChainFork.code),
        hasLength(1),
      );

      // The op itself is untouched: it stays refused and unapplied.
      final slot = await (b.syncStore.select(b.syncStore.opLog)
            ..where((r) =>
                r.workspaceId.equals(reopened.workspaceId) &
                r.seq.equals(seq)))
          .getSingle();
      expect(slot.appliedAt, isNull);
      expect(slot.refusedReason, SyncRejectionReason.controlChainFork.code);
    });

    test('a replacement refusal whose accusation was lost has it raised, and '
        'the break is retired', () async {
      final workspace =
          await SimWorkspace.create(deviceCount: 3, fileBacked: true);
      addTearDown(workspace.close);
      final b = workspace.b;
      await workspace.a.enrolment.turnOnEncryption(
        passphrase: workspace.passphrase,
      );
      await workspace.syncAll();

      final applied = await _applied(b);

      final root = await workspace.recoverRoot();
      final x = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.filled(32, 0x7a)),
      );
      final envelope = await memberRegisterEnvelope(
        device: x,
        workspaceId: workspace.workspaceId,
        root: root,
        prevControlHash: applied[applied.length - 2].payloadHash,
        wallMs: workspace.clock.nowMs,
      );
      root.drop();
      final header = OpHeader.parse(splitEnvelope(envelope).header);

      // The state a fault leaves behind when it hits **between** the two steps
      // of `_refuse`: the refusal is filed, and the alarm it raises is not.
      // Staged at the store level, like the case above.
      final seq = applied.last.seq + 1;
      final store = b.syncStore;
      await store.into(store.opLog).insert(
            OpLogCompanion.insert(
              seq: seq,
              workspaceId: b.client.workspaceId,
              envelope: envelope,
              opId: header.opId,
              authorMemberId: header.authorMemberId,
              authorSeq: header.authorSeq,
              receivedAt: workspace.clock.asDateTime,
              refusedReason: Value(SyncRejectionReason.controlChainFork.code),
            ),
          );
      await store.into(store.quarantinedOps).insert(
            QuarantinedOpsCompanion.insert(
              workspaceId: b.client.workspaceId,
              seq: Value(seq),
              reason: _breakCode,
              detail: 'refused for the missing predecessor',
              envelope: envelope,
              detectedAt: workspace.clock.asDateTime,
              authorMemberId: Value(x.memberId),
              authorSeq: Value(header.authorSeq),
            ),
          );
      await store.into(store.quarantinedOps).insert(
            QuarantinedOpsCompanion.insert(
              workspaceId: b.client.workspaceId,
              seq: Value(seq),
              reason: SyncRejectionReason.controlChainFork.code,
              detail: 'lost the fork tie-break',
              envelope: envelope,
              detectedAt: workspace.clock.asDateTime,
              authorMemberId: Value(x.memberId),
              authorSeq: Value(header.authorSeq),
            ),
          );

      // No alarm for the fork was ever raised: the fault ate it.
      expect(
        await (b.syncStore.select(b.syncStore.integrityAlarms)
              ..where((r) =>
                  r.workspaceId.equals(b.client.workspaceId) &
                  r.kind.equals(IntegrityAlarmKind.controlChainFork.code)))
            .get(),
        isEmpty,
      );

      // The scan runs on the first pull after a launch.
      final reopened = await b.reopenSyncStore(attachTransport: true);
      await reopened.pull();

      // The accusation the fault ate is raised, and the break row is retired.
      expect(
        (await reopened.integrityAlarms())
            .where((alarm) => alarm.kind == IntegrityAlarmKind.controlChainFork.code),
        hasLength(1),
      );
      final retired = (await _breakRows(reopened)).singleWhere((row) => row.seq == seq);
      expect(retired.releasedAt, isNotNull);
      // The refusal that was already filed is not filed a second time.
      expect(
        (await reopened.quarantined())
            .where((row) => row.seq == seq && row.reason != _breakCode),
        hasLength(1),
      );
    });

    test('a replacement refusal the user has answered raises nothing, and the '
        'break is retired', () async {
      final workspace =
          await SimWorkspace.create(deviceCount: 3, fileBacked: true);
      addTearDown(workspace.close);
      final b = workspace.b;
      await workspace.a.enrolment.turnOnEncryption(
        passphrase: workspace.passphrase,
      );
      await workspace.syncAll();

      final applied = await _applied(b);

      final root = await workspace.recoverRoot();
      final x = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.filled(32, 0x7b)),
      );
      final envelope = await memberRegisterEnvelope(
        device: x,
        workspaceId: workspace.workspaceId,
        root: root,
        prevControlHash: applied[applied.length - 2].payloadHash,
        wallMs: workspace.clock.nowMs,
      );
      root.drop();
      final header = OpHeader.parse(splitEnvelope(envelope).header);

      // The same state as the case above — the slot carries the verdict, the
      // break row is unreleased — except that the user has answered the
      // replacement refusal. An answer is the end of the question, so nothing
      // is raised for it.
      final seq = applied.last.seq + 1;
      final store = b.syncStore;
      await store.into(store.opLog).insert(
            OpLogCompanion.insert(
              seq: seq,
              workspaceId: b.client.workspaceId,
              envelope: envelope,
              opId: header.opId,
              authorMemberId: header.authorMemberId,
              authorSeq: header.authorSeq,
              receivedAt: workspace.clock.asDateTime,
              refusedReason: Value(SyncRejectionReason.controlChainFork.code),
            ),
          );
      await store.into(store.quarantinedOps).insert(
            QuarantinedOpsCompanion.insert(
              workspaceId: b.client.workspaceId,
              seq: Value(seq),
              reason: _breakCode,
              detail: 'refused for the missing predecessor',
              envelope: envelope,
              detectedAt: workspace.clock.asDateTime,
              authorMemberId: Value(x.memberId),
              authorSeq: Value(header.authorSeq),
            ),
          );
      await store.into(store.quarantinedOps).insert(
            QuarantinedOpsCompanion.insert(
              workspaceId: b.client.workspaceId,
              seq: Value(seq),
              reason: SyncRejectionReason.controlChainFork.code,
              detail: 'lost the fork tie-break',
              envelope: envelope,
              detectedAt: workspace.clock.asDateTime,
              authorMemberId: Value(x.memberId),
              authorSeq: Value(header.authorSeq),
              resolution: Value(AlarmResolution.rejectedPermanently.code),
              resolutionDecidedAt: Value(workspace.clock.asDateTime),
            ),
          );

      // The scan runs on the first pull after a launch.
      final reopened = await b.reopenSyncStore(attachTransport: true);
      await reopened.pull();

      // The answer is not taken back: no accusation is raised for a refusal the
      // user has already answered.
      expect(
        (await reopened.integrityAlarms())
            .where((alarm) => alarm.kind == IntegrityAlarmKind.controlChainFork.code),
        isEmpty,
      );
      // The break is answered either way: the op cannot apply, so the row is
      // retired.
      final retired = (await _breakRows(reopened)).singleWhere((row) => row.seq == seq);
      expect(retired.releasedAt, isNotNull);
    });

    test('the release is visible on Sync Health', () async {
      final scene = await _scene();
      final b = scene.workspace.b;
      final dId = scene.dFixture.memberId;

      final fixed = await b.reopenSyncStore(attachTransport: true);
      await fixed.pull();
      await fixed.pull();

      final row = (await _breakRows(fixed))
          .singleWhere((r) => r.authorMemberId == dId);
      final conditions = syncHealthConditionsFor(
        workspaceId: fixed.workspaceId,
        alarms: await fixed.integrityAlarms(),
        refusals: await fixed.quarantined(),
      );
      final condition = conditions.singleWhere((c) => c.rowId == row.id);
      expect(condition.reAdmitted, isTrue,
          reason: 'a refusal that healed is marked, not hidden');
    });

    test('a refusal whose change has been applied offers no decision', () async {
      final scene = await _scene();
      final b = scene.workspace.b;
      final dId = scene.dFixture.memberId;

      // The projection fails, so the pull that admits the registration ends
      // before the row is stamped released. The change is applied and the
      // refusal is still standing: the window in which the two disagree.
      final fixed = await b.reopenSyncStore(attachTransport: true);
      fixed.projector = _FailingOnceProjector(fixed.projector!);
      await expectLater(fixed.pull(), throwsA(isA<StateError>()));

      final row = (await _breakRows(fixed))
          .singleWhere((r) => r.authorMemberId == dId);
      expect(row.releasedAt, isNull,
          reason: 'the row waits for the projection before it is released');
      expect(fixed.directory.isChained(dId), isTrue,
          reason: 'the registration is applied');

      final applied = await fixed.watchAppliedRefusalRowIds().first;
      expect(applied, contains(row.id),
          reason: 'the refusal is listed as one the log has applied');

      final conditions = syncHealthConditionsFor(
        workspaceId: fixed.workspaceId,
        alarms: await fixed.integrityAlarms(),
        refusals: await fixed.quarantined(),
        appliedRefusalRowIds: applied,
      );
      final condition = conditions.singleWhere((c) => c.rowId == row.id);
      expect(condition.resolutions, isEmpty,
          reason: 'a change that is in has nothing left to decide');

      // The decision is refused as well, so it cannot be recorded and ignored.
      await expectLater(
        fixed.resolveRefusedItem(
          row.id,
          AlarmResolution.rejectedPermanently,
        ),
        throwsA(isA<StateError>()),
      );
      expect((await _breakRows(fixed)).singleWhere((r) => r.id == row.id).resolution,
          isNull,
          reason: 'nothing was written');
    });

    test('a late registration re-verdicts the content behind it', () async {
      // D is a device, not a fixture: it writes at the Workspace's current
      // epoch, which is what the content behind a late grant is written at.
      final workspace = await SimWorkspace.create(deviceCount: 3, fileBacked: true);
      addTearDown(workspace.close);
      final a = workspace.a;
      final b = workspace.b;
      await a.enrolment.turnOnEncryption(passphrase: workspace.passphrase);
      await workspace.syncAll();

      final broken = await b.reopenSyncStore(
        attachTransport: true,
        restoreChainedMembers: false,
      );
      await a.enrolment.revokeAndRotate(
        passphrase: workspace.passphrase,
        memberId: workspace.devices[2].identity.memberId,
      );
      await a.sync();

      final d = await SimDevice.create(
        label: 'D',
        userId: workspace.userId,
        server: workspace.server,
        clock: workspace.clock,
        timers: workspace.timers,
        passphrase: workspace.passphrase,
      );
      addTearDown(d.close);
      final dId = d.identity.memberId;

      // D writes before its registration is applied: this device cannot judge
      // the content yet, so it holds it.
      d.clock.advance(1000);
      await d.client.capture(
        collection: _collection,
        entityId: _docId,
        fields: {'body': 'from D'},
      );
      await d.sync();
      await broken.pull();

      expect(
        (await _breakRows(broken))
            .where((row) => row.authorMemberId == dId && row.releasedAt == null),
        isNotEmpty,
        reason: 'D\'s registration is refused for the missing predecessor',
      );

      final fixed = await b.reopenSyncStore(attachTransport: true);
      final failingProjector = _FailingOnceProjector(fixed.projector!);
      fixed.projector = failingProjector;
      await expectLater(fixed.pull(), throwsA(isA<StateError>()));
      final pending = (await _breakRows(fixed))
          .singleWhere((row) => row.authorMemberId == dId);
      expect(pending.releasedAt, isNull,
          reason: 'the durable recovery row stays until projection succeeds');
      expect(failingProjector.failedAffected, isNotEmpty);
      await fixed.pull();
      expect(failingProjector.retriedAffected,
          containsAll(failingProjector.failedAffected!),
          reason: 'an empty pull retries every affected entity from the rebuild');
      expect((await _breakRows(fixed))
          .singleWhere((row) => row.id == pending.id).releasedAt, isNotNull);

      expect(await _entity(b, _docId), isNotNull,
          reason: 'the content behind the late registration applies');
      final logged = await (b.syncStore.select(b.syncStore.opLog)
            ..where((r) =>
                r.workspaceId.equals(fixed.workspaceId) &
                r.authorMemberId.equals(dId)))
          .get();
      final contentRows = logged
          .where((row) =>
              OpHeader.parse(splitEnvelope(row.envelope).header).opClass ==
              opClassContent)
          .toList();
      expect(contentRows, hasLength(1));
      expect(contentRows.single.appliedAt, isNotNull);
      expect(contentRows.single.refusedReason, isNull);
    });

    test('a row the user refused for good is not examined again', () async {
      final scene = await _scene();
      final b = scene.workspace.b;
      final dId = scene.dFixture.memberId;

      final held = (await _breakRows(scene.broken)).singleWhere(
          (row) => row.authorMemberId == dId && row.releasedAt == null);

      // The user ends the question: the refused change is refused for good.
      await scene.broken.resolveRefusedItem(
        held.id,
        AlarmResolution.rejectedPermanently,
      );

      final fixed = await b.reopenSyncStore(attachTransport: true);
      await fixed.pull();
      await fixed.pull();

      final row = (await _breakRows(fixed)).singleWhere((r) => r.id == held.id);
      expect(row.releasedAt, isNull,
          reason: 'the decision is the end of the question');
      expect(fixed.directory.isChained(dId), isFalse);
      expect(
        (await _applied(b)).where((r) =>
            r.controlType == controlTypeMemberRegister &&
            ControlPayload.decode(r.payloadBytes).certificate().memberId == dId),
        isEmpty,
        reason: 'the registration was not applied behind the user\'s back',
      );
    });

    test('a slot with a different envelope is not reclaimed', () async {
      final scene = await _scene();
      final broken = scene.broken;
      final dId = scene.dFixture.memberId;

      // The original registration is refused; get its seq and envelope.
      final breakRows = await _breakRows(broken);
      final refused = breakRows.singleWhere((row) =>
          row.authorMemberId == dId &&
          row.releasedAt == null &&
          row.reason == _breakCode);
      final refusedSeq = refused.seq;
      final refusedEnvelope = refused.envelope;
      expect(refusedSeq, isNotNull);

      // Inject a different envelope at the same seq after fixing.
      final fixed = await scene.workspace.b
          .reopenSyncStore(attachTransport: true);
      // Create a different registration envelope for D (simulated by just
      // altering the refused one minimally for test purposes).
      final differentEnvelope = Uint8List.fromList(refusedEnvelope);
      if (differentEnvelope.isNotEmpty) {
        differentEnvelope[differentEnvelope.length - 1] ^= 1; // flip one bit
      }
      final store = scene.workspace.b.syncStore;
      await (store.update(store.opLog)
            ..where((r) =>
                r.workspaceId.equals(fixed.workspaceId) &
                r.seq.equals(refusedSeq!)))
          .write(OpLogCompanion(envelope: Value(differentEnvelope)));

      await fixed.pull();
      await fixed.pull();

      // The original refused row should still be refused (not reclaimed) because
      // the envelope in the slot does not match.
      final refusedAfter = (await _breakRows(fixed))
          .where((r) => r.seq == refusedSeq && r.reason == _breakCode)
          .toList();
      expect(refusedAfter, hasLength(1),
          reason: 'the refused row still exists');
      expect(refusedAfter.single.releasedAt, isNull,
          reason: 'the row was not released (slot envelope mismatch)');
      expect(refusedAfter.single.envelope, refusedEnvelope,
          reason: 'the quarantined envelope is unchanged');
      final slotAfter = await (store.select(store.opLog)
            ..where((row) =>
                row.workspaceId.equals(fixed.workspaceId) &
                row.seq.equals(refusedSeq!)))
          .getSingle();
      expect(slotAfter.envelope, differentEnvelope,
          reason: 'the slot envelope is unchanged');
      expect(slotAfter.appliedAt, isNull,
          reason: 'the mismatched slot was not applied');
    });
  });
}
