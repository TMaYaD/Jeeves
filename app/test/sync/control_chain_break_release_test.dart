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
@TestOn('!browser')
library;

import 'dart:typed_data';

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/control_payload.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_rejection.dart';

import 'harness/author_fixture.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';

final String _breakCode = SyncRejectionReason.controlChainBreak.code;

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
      await fixed.pull();

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
  });
}
