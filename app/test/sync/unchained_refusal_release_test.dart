/// #988: a change refused as `member_not_chained_to_root` is re-examined once
/// this device knows the author's key.
///
/// The defect was a restart: a device that came back with an empty directory
/// of other devices' keys refused every peer's change as
/// `member_not_chained_to_root`, and nothing ever looked at those rows again.
/// The rows are still here — a refusal quarantines the envelope and the pull
/// cursor moves past it, so the server never serves it again — so the only way
/// to heal them is to re-examine them.
///
/// The rules this file pins down:
///
///  * A row whose author's key the device now knows is re-received through the
///    **ordinary** receive pipeline, and applies.
///  * A row whose author's key the device does not know stays refused, and is
///    not examined again on every pull — a standing stranger row costs
///    nothing.
///  * The re-examination grants nothing: the pipeline's own verdict decides,
///    so a forged envelope naming a known key is still refused, with the real
///    reason.
@TestOn('!browser')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/chain_verifier.dart';
import 'package:jeeves/sync/host/merge_state.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_rejection.dart';

import 'harness/author_fixture.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';

const String _collection = 'harness_docs';

/// Two entities the peer writes. A canonical lowercase UUID, because that is
/// the only spelling of an entity id this protocol accepts.
const String _firstDocId = '11111111-1111-4111-8111-111111111111';
const String _secondDocId = '22222222-2222-4222-8222-222222222222';

/// The reduced fields of one entity on [device]'s **live** store.
///
/// [SimDevice.registry] is bound to the database that was open before the
/// reopen, so a test that reopened the store has to read through a registry
/// bound to the reopened one — the pre-crash handle is closed.
Future<Map<String, Object?>?> _entity(SimDevice device, String entityId) async =>
    CollectionRegistry(device.syncStore)
        .register(_collection)
        .readEntity(entityId);

/// One content change from [device], authored but not yet pushed.
Future<void> _write(SimDevice device, String entityId) async {
  device.clock.advance(1000);
  await device.client.capture(
    collection: _collection,
    entityId: entityId,
    fields: {'body': 'from ${device.identity.memberId}'},
  );
}

/// Two devices of one user, each holding the other's registration.
///
/// The registrations are what the directory is made of, so a case that means
/// "the device knows the author's key" starts by syncing both ways.
Future<SimWorkspace> _pair() async {
  final workspace = await SimWorkspace.create(deviceCount: 2, fileBacked: true);
  addTearDown(() async {
    for (final device in workspace.devices) {
      await device.close();
    }
  });
  await workspace.b.sync();
  await workspace.a.sync();
  expect(
    workspace.b.client.directory.hasSigningKeyFor(
      workspace.a.identity.memberId,
      workspace.a.identity.keyId,
    ),
    isTrue,
    reason: 'B must know A\'s key before the case removes it',
  );
  return workspace;
}

/// The quarantine rows this device holds for [authorMemberId].
Future<List<QuarantineRow>> _rowsFor(
  SyncClient client,
  String authorMemberId, {
  bool includeReleased = true,
}) async =>
    (await client.quarantined(includeReleased: includeReleased))
        .where((row) => row.authorMemberId == authorMemberId)
        .toList();

void main() {
  group('a held member_not_chained_to_root row heals once the key is known', () {
    test('a change refused while the directory was empty is applied after the '
        'next relaunch', () async {
      final workspace = await _pair();
      final a = workspace.a;
      final b = workspace.b;

      // A relaunch of a build that does not restore the directory: this device
      // comes back knowing nobody but itself.
      final brokenClient = await b.reopenSyncStore(
        attachTransport: true,
        restoreChainedMembers: false,
      );
      expect(
        brokenClient.directory.hasSigningKeyFor(
          a.identity.memberId,
          a.identity.keyId,
        ),
        isFalse,
        reason: 'the pre-#980 relaunch leaves the directory empty of other '
            'devices\' keys',
      );

      // A writes one change and pushes it.
      await _write(a, _firstDocId);
      await a.sync();

      await brokenClient.pull();

      final refused = await _rowsFor(brokenClient, a.identity.memberId,
          includeReleased: false);
      expect(refused, hasLength(1));
      expect(
        refused.single.reason,
        SyncRejectionReason.memberNotChainedToRoot.code,
      );
      expect(
        await _entity(b, _firstDocId),
        isNull,
        reason: 'the change did not apply while the key was unknown',
      );

      // The next relaunch is a current build: the directory is restored from
      // the applied control log.
      final fixedClient = await b.reopenSyncStore(attachTransport: true);
      expect(
        fixedClient.directory.hasSigningKeyFor(
          a.identity.memberId,
          a.identity.keyId,
        ),
        isTrue,
      );

      await fixedClient.pull();

      expect(
        await _entity(b, _firstDocId),
        isNotNull,
        reason: 'the held change applies once the author\'s key is known',
      );
      expect(
        await _rowsFor(fixedClient, a.identity.memberId,
            includeReleased: false),
        isEmpty,
        reason: 'the row left the scan set',
      );
      final released = (await fixedClient.quarantined())
          .firstWhere((row) => row.id == refused.single.id);
      expect(released.reason, SyncRejectionReason.memberNotChainedToRoot.code,
          reason: 'the row keeps the reason it was filed under');
      expect(released.releasedAt, isNotNull,
          reason: 'the release is recorded on the row itself');
    });

    test('a successor held as a chain gap follows its predecessor', () async {
      final workspace = await _pair();
      final a = workspace.a;
      final b = workspace.b;

      final brokenClient = await b.reopenSyncStore(
        attachTransport: true,
        restoreChainedMembers: false,
      );

      await _write(a, _firstDocId);
      await a.sync();
      await brokenClient.pull();
      expect(
        await _rowsFor(brokenClient, a.identity.memberId,
            includeReleased: false),
        hasLength(1),
      );

      // The relaunch restores the directory; A writes a **second** change
      // before B pulls, so the second change arrives with its predecessor
      // still missing from B's chain.
      final fixedClient = await b.reopenSyncStore(attachTransport: true);
      await _write(a, _secondDocId);
      await a.sync();

      await fixedClient.pull();

      expect(await _entity(b, _firstDocId), isNotNull);
      expect(
        await _entity(b, _secondDocId),
        isNotNull,
        reason: 'the change held as a chain gap follows its re-admitted '
            'predecessor',
      );

      final gapRows = (await _rowsFor(fixedClient, a.identity.memberId))
          .where((row) =>
              row.reason == SyncRejectionReason.authorChainGap.code)
          .toList();
      expect(gapRows, hasLength(1));
      expect(gapRows.single.releasedAt, isNotNull,
          reason: 'the gap row was released, not merely overtaken');

      final alarms = await fixedClient.integrityAlarms();
      final gapAlarm = alarms.firstWhere(
        (alarm) => alarm.kind == IntegrityAlarmKind.authorChainGap.code,
      );
      expect(gapAlarm.resolvedAt, isNotNull,
          reason: 'nothing is still missing, so the gap alarm is resolved');
    });
  });

  group('the re-examination grants nothing', () {
    test('a stranger stays refused', () async {
      final workspace = await _pair();
      final b = workspace.b;
      final stranger = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.filled(32, 0x5a)),
      );

      workspace.server.injectUnchecked(
        workspace.workspaceId,
        await stranger.nextEnvelope(workspace.workspaceId),
      );
      await b.client.pull();

      final before = await _rowsFor(b.client, stranger.memberId,
          includeReleased: false);
      expect(before, isNotEmpty);
      expect(
        before.every((row) =>
            row.reason == SyncRejectionReason.memberNotChainedToRoot.code),
        isTrue,
      );

      final reopened = await b.reopenSyncStore(attachTransport: true);
      await reopened.pull();
      await reopened.pull();

      final after = await _rowsFor(reopened, stranger.memberId,
          includeReleased: false);
      expect(
        after.map((row) => row.id).toList(),
        before.map((row) => row.id).toList(),
        reason: 'the stranger row was examined and left standing — not '
            'examined again, and not replaced by a fresh row',
      );
      expect(
        after.every((row) =>
            row.reason == SyncRejectionReason.memberNotChainedToRoot.code),
        isTrue,
      );
      expect(after.every((row) => row.releasedAt == null), isTrue);

      final logged = b.syncStore.select(b.syncStore.opLog)
        ..where((row) => row.authorMemberId.equals(stranger.memberId));
      expect(await logged.get(), isEmpty,
          reason: 'nothing the stranger wrote reached the log');
    });

    test('a stranger naming a known member stays refused', () async {
      final workspace = await _pair();
      final a = workspace.a;
      final b = workspace.b;
      // The member id is known; the key id is not, so the slot is empty and
      // the refusal is the same one.
      final impostor = await AuthorFixture.create(
        memberId: a.identity.memberId,
        seed: Uint8List.fromList(List<int>.filled(32, 0x3c)),
      );

      final injectedSeq = workspace.server.injectUnchecked(
        workspace.workspaceId,
        await impostor.nextEnvelope(workspace.workspaceId),
      );
      await b.client.pull();

      Future<List<QuarantineRow>> rowsAtSeq(SyncClient client) async =>
          (await client.quarantined(includeReleased: false))
              .where((row) => row.seq == injectedSeq)
              .toList();

      final before = await rowsAtSeq(b.client);
      expect(before, isNotEmpty);
      expect(
        before.single.reason,
        SyncRejectionReason.memberNotChainedToRoot.code,
      );

      final reopened = await b.reopenSyncStore(attachTransport: true);
      await reopened.pull();
      await reopened.pull();

      final after = await rowsAtSeq(reopened);
      expect(
        after.map((row) => row.id).toList(),
        before.map((row) => row.id).toList(),
        reason: 'a known member id with an unknown key is still a stranger',
      );
      expect(after.single.releasedAt, isNull);
      expect(
        after.single.reason,
        SyncRejectionReason.memberNotChainedToRoot.code,
      );
    });
  });
}
