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

import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
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

/// The control types applied on [device]'s live store.
Future<List<AppliedControlRow>> _applied(SimDevice device) async =>
    (device.syncStore.select(device.syncStore.appliedControlLog)
          ..where((row) => row.workspaceId.equals(device.client.workspaceId)))
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
