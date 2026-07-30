/// End-to-end: a Workspace with encryption turned on.
///
/// This file is the acceptance criteria of #554, and every case runs the whole
/// ceremony rather than any part of it in isolation: devices enrol for real, the
/// owner turns encryption on with the passphrase it was given, the wraps go through
/// the fake server's own key-plane routes, and the reading device recovers the epoch
/// key by a route a real client could take. No test hands an epoch key from one
/// device to another, exactly as no test hands one a Root.
///
/// The negative cases matter as much as the positive ones, and two of them are worth
/// naming up front because they look like the same test and are not:
///
/// * **Tampering an honest device's ciphertext yields `signature_invalid`, not
///   `aead_failure`.** The Ed25519 signature covers `header || body`, so moving one
///   ciphertext byte breaks the signature first — and the receive order is
///   verify-then-decrypt. An `aead_failure` therefore requires bytes that carry a
///   *valid* author signature and still do not open: a coerced or broken author, or a
///   substituted key. Both are asserted below, because "the alarm fires" and "the
///   alarm fires for the right reason" are different claims.
/// * **A revoked Device is locked out of the new epoch even by a server that keeps
///   serving it.** The transport refusal after revocation is the easy half; the half
///   that matters is that the new epoch's wrap set has no entry for it, so a hostile
///   server that un-revokes its own grant row still cannot hand it the key.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/chain_verifier.dart';
import 'package:jeeves/sync/control_payload.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/key_ceremony.dart';
import 'package:jeeves/sync/sync_transport.dart';
import 'package:uuid/uuid.dart';

import 'harness/author_fixture.dart';
import 'harness/fake_sync_server.dart';
import 'harness/reduced_state.dart';
import 'harness/rejection_matcher.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';

const String _collection = 'harness_docs';

/// Entity ids are canonical UUIDs on the wire, so a readable label is hashed into
/// one rather than used as one — deterministically, so a failure names the same id
/// twice.
String _entityId(String label) => const Uuid().v5(jeevesWorkspaceNamespace, label);

/// A string no padding byte, no length prefix and no id could produce, so finding it
/// in a stored body means the payload went out in the clear.
const String _marker = 'MARKER-e2ee-plaintext-canary-554';

/// Every content op the server holds for [workspaceId].
List<StoredOp> _contentOps(FakeSyncServer server, String workspaceId) => [
      for (final op in server.storedOps)
        if (op.workspaceId == workspaceId && op.header?.opClass == opClassContent) op,
    ];

bool _containsMarker(Uint8List envelope) {
  final needle = ascii.encode(_marker);
  for (var start = 0; start + needle.length <= envelope.length; start++) {
    var matched = true;
    for (var index = 0; index < needle.length; index++) {
      if (envelope[start + index] != needle[index]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}

void main() {
  group('turn-on', () {
    test('every content op after turn-on is aead_v1 and carries no plaintext', () async {
      final workspace = await SimWorkspace.create(deviceCount: 1);
      addTearDown(workspace.close);
      final a = workspace.a;

      // Before: the pre-turn-on world, and it has to keep working byte for byte.
      await a.client.capture(
        collection: _collection,
        entityId: _entityId('before-turn-on'),
        fields: {'title': '$_marker-before'},
      );
      await a.sync();
      final before = _contentOps(workspace.server, workspace.workspaceId).single;
      expect(before.header!.suite, suitePlaintextV1);
      expect(before.header!.keyEpoch, 0);
      expect(_containsMarker(before.envelope), isTrue,
          reason: 'a pre-turn-on op is plaintext, which is the state turn-on leaves '
              'readable for ever');

      final epochs = await a.enrolment.turnOnEncryption(passphrase: workspace.passphrase);
      expect(epochs[workspace.workspaceId], 1,
          reason: 'turn-on mints K_{w,1} and leaves epoch 0 unkeyed, so the history '
              'above stays readable');
      expect(epochs[workspace.preferencesWorkspaceId], 1,
          reason: 'a User\'s preferences are exactly as private as their tasks');

      await a.client.capture(
        collection: _collection,
        entityId: _entityId('after-turn-on'),
        fields: {'title': '$_marker-after'},
      );
      await a.sync();

      final content = _contentOps(workspace.server, workspace.workspaceId);
      expect(content, hasLength(2));
      final after = content.last;
      expect(after.header!.suite, suiteAeadV1);
      expect(after.header!.keyEpoch, 1);
      expect(_containsMarker(after.envelope), isFalse,
          reason: 'the payload is inside the AEAD: no marker byte survives on the wire');
      expect(after.header!.nonce.any((byte) => byte != 0), isTrue,
          reason: 'an aead_v1 header carries a real nonce, not the zero one 0x00 uses');

      // The author reads its own history back across the turn-on boundary.
      await a.client.rebuildFromOpLog();
      final rebuilt = await canonicalReducedState(a.database);
      expect(rebuilt, contains(_entityId('after-turn-on')));
      expect(rebuilt, contains(_entityId('before-turn-on')),
          reason: 'a rebuild must decode both suites, or turn-on would silently '
              'un-reduce every pre-turn-on entity');
    });

    test('control ops stay plaintext_v1 at epoch 0 for ever', () async {
      final workspace = await SimWorkspace.create(deviceCount: 1);
      addTearDown(workspace.close);
      await workspace.a.enrolment.turnOnEncryption(passphrase: workspace.passphrase);
      await workspace.a.client.capture(
        collection: _collection,
        entityId: _entityId('after'),
        fields: {'title': 'x'},
      );
      await workspace.a.sync();

      final controlOps = [
        for (final op in workspace.server.storedOps)
          if (op.workspaceId == workspace.workspaceId &&
              op.header?.opClass == opClassControl)
            op,
      ];
      expect(controlOps, isNotEmpty);
      for (final op in controlOps) {
        expect(op.header!.suite, suitePlaintextV1);
        expect(op.header!.keyEpoch, 0);
      }
      expect(
        controlOps.where((op) =>
            ControlPayload.decode(parseBody(splitEnvelope(op.envelope).body))
                .controlType ==
            controlTypeRotate),
        hasLength(1),
        reason: 'exactly one rotate turned this Workspace on',
      );
    });
  });

  test('a second device converges on the passphrase alone', () async {
    final workspace = await SimWorkspace.create(deviceCount: 1);
    addTearDown(workspace.close);
    final a = workspace.a;

    await a.client.capture(
      collection: _collection,
      entityId: _entityId('pre'),
      fields: {'title': 'written before encryption'},
    );
    await a.sync();
    await a.enrolment.turnOnEncryption(passphrase: workspace.passphrase);
    await a.client.capture(
      collection: _collection,
      entityId: _entityId('post'),
      fields: {'title': 'written under K_w_1'},
    );
    await a.sync();

    // A genuinely fresh device: its own store, its own keypairs, and the passphrase
    // string as the only thing it is given. Nothing else is online.
    final b = await SimDevice.create(
      label: 'B',
      userId: workspace.userId,
      server: workspace.server,
      clock: workspace.clock,
      timers: workspace.timers,
      passphrase: workspace.passphrase,
    );
    addTearDown(b.close);
    await b.sync();

    expect(await b.workspaceKeys.read(workspace.workspaceId), contains(1),
        reason: 'the escrow wrap is what makes this work with no second device '
            'online: passphrase -> master_wrap_key -> every epoch key');
    expect(
      await canonicalReducedState(b.database),
      await canonicalReducedState(a.database),
      reason: 'byte-identical convergence across the turn-on boundary',
    );
    final health = await b.client.health();
    expect(health.quarantineCount, 0,
        reason: 'the history quarantined while it had no key was released once it '
            'adopted the epoch keys');
    expect(health.alarmKinds, isEmpty,
        reason: 'a delivery gap that healed accuses nobody');
    expect(await b.client.orphanedGrants(), isEmpty,
        reason: 'this device holds a live Grant and can read the current epoch');
  });

  group('aead failure is an alarm, never a skipped row', () {
    test('signed bytes that do not open raise aead_failure and quarantine', () async {
      final workspace = await SimWorkspace.create(deviceCount: 1);
      addTearDown(workspace.close);
      final a = workspace.a;
      await a.enrolment.turnOnEncryption(passphrase: workspace.passphrase);
      await a.sync();

      // A chained, granted author — so the envelope signature verifies against a key
      // this device learned from the log — whose body was never sealed under the
      // Workspace key. That is the only shape an `aead_failure` can have: bytes the
      // author really signed, at an epoch we really hold a key for, that do not open.
      final impostor = await AuthorFixture.create();
      final session = await workspace.enrolFixture(impostor);
      await session.postOps(workspace.workspaceId, [
        await impostor.nextEnvelopeWithBody(
          workspace.workspaceId,
          Uint8List.fromList(List<int>.filled(256 + aeadTagBytes, 0x5A)),
          suite: suiteAeadV1,
          keyEpoch: 1,
        ),
      ]);

      final health = await a.sync();
      expect(health.alarmKinds, contains(IntegrityAlarmKind.aeadFailure.code));
      expect(health.quarantineCount, 1,
          reason: 'quarantined *and* accused — never merely skipped (AC-5)');
      expect(health.degraded, isTrue);
      final quarantined = await a.client.quarantined(includeReleased: false);
      expect(quarantined.single.reason, SyncRejectionReason.aeadFailure.code);
    });

    test('a tampered ciphertext fails on the signature first, and still alarms',
        () async {
      final workspace = await SimWorkspace.create(deviceCount: 2);
      addTearDown(workspace.close);
      final a = workspace.a;
      await a.enrolment.turnOnEncryption(passphrase: workspace.passphrase);
      await workspace.syncAll();
      await a.client.capture(
        collection: _collection,
        entityId: _entityId('tampered'),
        fields: {'title': 'x'},
      );
      await a.sync();

      final target = _contentOps(workspace.server, workspace.workspaceId).single;
      // One ciphertext byte, inside the body. The signature covers `header || body`,
      // so this is caught by Ed25519 before the AEAD is reached — which is why the
      // case above needs a signing author, and why this one is a different alarm
      // rather than a duplicate of it.
      target.envelope[headerLengthBytes + 4] ^= 0x01;

      final b = workspace.b;
      final health = await b.sync();
      expect(health.alarmKinds, contains(IntegrityAlarmKind.signatureInvalid.code));
      expect(health.quarantineCount, 1);
    });

    test('a plaintext content op at a keyed epoch is refused and accused', () async {
      final workspace = await SimWorkspace.create(deviceCount: 1);
      addTearDown(workspace.close);
      final a = workspace.a;
      await a.enrolment.turnOnEncryption(passphrase: workspace.passphrase);
      await a.sync();

      final downgrader = await AuthorFixture.create();
      final session = await workspace.enrolFixture(downgrader);
      await session.postOps(workspace.workspaceId, [
        await downgrader.nextEnvelope(
          workspace.workspaceId,
          keyEpoch: 1,
          payloadJson:
              '{"collection":"$_collection","entity_id":"${_entityId('downgrade')}"}',
        ),
      ]);

      final health = await a.sync();
      expect(
        health.alarmKinds,
        contains(IntegrityAlarmKind.plaintextAtEncryptedEpoch.code),
        reason: 'the upgrade is one-way, and this is the read boundary that keeps it '
            'so — a coerced author cannot hand the Workspace back a plaintext op',
      );
      final quarantined = await a.client.quarantined(includeReleased: false);
      expect(
        quarantined.single.reason,
        SyncRejectionReason.plaintextAtEncryptedEpoch.code,
      );
    });

    test('a Device awaiting its wrap still refuses a plaintext op at a keyed epoch',
        () async {
      // The read boundary is judged on the epoch, never on local key availability.
      // A device whose wrap has not arrived is exactly the one that would
      // otherwise reduce cleartext its keyed peers refuse — one Workspace
      // disagreeing with itself about what applied.
      final workspace = await SimWorkspace.create(deviceCount: 1);
      addTearDown(workspace.close);
      final a = workspace.a;
      await a.enrolment.turnOnEncryption(passphrase: workspace.passphrase);
      await a.sync();

      final downgrader = await AuthorFixture.create();
      final session = await workspace.enrolFixture(downgrader);
      await session.postOps(workspace.workspaceId, [
        await downgrader.nextEnvelope(
          workspace.workspaceId,
          keyEpoch: 1,
          payloadJson:
              '{"collection":"$_collection","entity_id":"${_entityId('keyless-downgrade')}"}',
        ),
      ]);

      // Drop the key *after* the op is on the server: this device now stands at a
      // keyed epoch holding nothing, which is the delayed-wrap state.
      await a.workspaceKeys.clear(workspace.workspaceId);
      final health = await a.sync();
      expect(
        health.alarmKinds,
        contains(IntegrityAlarmKind.plaintextAtEncryptedEpoch.code),
        reason: 'the downgrade is misconduct by its author, and holding the key is '
            'not what makes it so',
      );
    });

    test('a Device without the epoch key refuses to author rather than downgrade',
        () async {
      // The *write* half of the one-way rule, and the reason it cannot be left to
      // the read boundary above: a device whose wrap has not arrived would
      // otherwise put the user's content on the server in the clear at an epoch
      // that is supposed to be encrypted, and every peer holding the key would
      // refuse it — a capture that looks saved here and reaches nobody.
      final workspace = await SimWorkspace.create(deviceCount: 1);
      addTearDown(workspace.close);
      final a = workspace.a;
      await a.enrolment.turnOnEncryption(passphrase: workspace.passphrase);
      await a.sync();
      final before = _contentOps(workspace.server, workspace.workspaceId).length;

      // The rotation window: the floor stands at the new epoch and this device
      // does not hold its key. Reached here by dropping the key, and reachable in
      // production whenever the wraps PUT has not landed yet.
      await a.workspaceKeys.clear(workspace.workspaceId);
      expect(await a.client.epochFloor(), 1);

      await expectLater(
        a.client.capture(
          collection: _collection,
          entityId: _entityId('keyless'),
          fields: {'title': '$_marker-keyless'},
        ),
        throwsA(
          predicate<Object>(
            (error) =>
                error is SyncRejection &&
                error.reason == SyncRejectionReason.missingEpochKey,
            'a missing_epoch_key rejection',
          ),
        ),
      );
      expect(
        _contentOps(workspace.server, workspace.workspaceId),
        hasLength(before),
        reason: 'nothing was authored, so nothing plaintext reached the server',
      );
    });
  });

  group('revoke and rotate', () {
    test('the revoked Device is locked out and the floor rose', () async {
      final workspace = await SimWorkspace.create(deviceCount: 2);
      addTearDown(workspace.close);
      final a = workspace.a;
      final b = workspace.b;

      await a.enrolment.turnOnEncryption(passphrase: workspace.passphrase);
      await workspace.syncAll();
      expect(await b.workspaceKeys.read(workspace.workspaceId), contains(1),
          reason: 'B was wrapped to at turn-on, so it reads epoch 1');

      final epochs = await a.enrolment.revokeAndRotate(
        passphrase: workspace.passphrase,
        memberId: b.identity.memberId,
      );
      expect(epochs[workspace.workspaceId], 2);
      expect(await a.client.epochFloor(), 2,
          reason: 'applying the verified rotate is the floor\'s only production '
              'raiser (AC-3)');
      expect(await a.workspaceKeys.read(workspace.workspaceId), contains(2));

      // The wrap set for the new epoch, as the *server's own table* holds it.
      final recipients = workspace.server.keyWrapRecipients(workspace.workspaceId, 2);
      expect(recipients, contains(a.identity.memberId));
      expect(recipients, isNot(contains(b.identity.memberId)),
          reason: 'the rotation is what makes the revocation mean something');

      await a.client.capture(
        collection: _collection,
        entityId: _entityId('after-rotation'),
        fields: {'title': 'only A can read this'},
      );
      await a.sync();

      // The easy half: the transport refuses a revoked Member outright.
      await expectLater(
        b.client.pull(),
        throwsA(isA<SyncTransportException>()
            .having((error) => error.code, 'code', 'no_live_grant')),
      );

      // The half that matters. A hostile server un-revokes its own grant row and
      // keeps serving B — chain-gating already makes the *row* inert, and now the
      // key plane makes the *content* unreadable too.
      workspace.server.poisonGrantLiveness(
        workspace.workspaceId,
        workspace.ownerGrantIdOf(b.identity.memberId),
      );
      final health = await b.client.sync();
      expect(await b.workspaceKeys.read(workspace.workspaceId), isNot(contains(2)),
          reason: 'no wrap exists for B at epoch 2, so no route hands it the key');
      expect(
        (await b.client.quarantined(includeReleased: false))
            .map((row) => row.reason)
            .toSet(),
        contains(SyncRejectionReason.missingEpochKey.code),
      );
      expect(health.alarmKinds, isNot(contains(IntegrityAlarmKind.aeadFailure.code)),
          reason: 'a key it was never given is a delivery gap, not an accusation — '
              'even when the gap is permanent and deliberate');
      expect((await b.client.grantsView()).isRevoked(b.identity.memberId), isTrue,
          reason: 'B learns of its own revocation from the signed log, whatever the '
              'server\'s grant row now claims');
      expect(await b.client.orphanedGrants(), isEmpty,
          reason: 'and it is therefore *revoked* rather than orphaned: the orphaned '
              'state is a live Grant with no readable epoch, which is the healable '
              'freshness window, not a lockout');
    });

    test('a survivor that cannot be wrapped to refuses the ceremony before authoring',
        () async {
      final workspace = await SimWorkspace.create(deviceCount: 2);
      addTearDown(workspace.close);
      final a = workspace.a;
      await a.enrolment.turnOnEncryption(passphrase: workspace.passphrase);
      await workspace.syncAll();

      // A Service with a live Grant in the default Workspace. Services hold no
      // per-User KEX subkey yet, so this Workspace has a survivor the ceremony
      // cannot wrap to.
      final service = await AuthorFixture.create();
      await workspace.enrolServiceFixture(service);
      await workspace.syncAll();

      final logLengthBefore = workspace.server.storedOps.length;
      final epochsBefore = workspace.server.keyedEpochs(workspace.workspaceId);

      await expectLater(
        a.enrolment.revokeAndRotate(
          passphrase: workspace.passphrase,
          memberId: workspace.b.identity.memberId,
        ),
        throwsRejection(SyncRejectionReason.unwrappableGrant),
      );

      expect(workspace.server.storedOps, hasLength(logLengthBefore),
          reason: 'nothing was authored: not the revoke, not the rotate (AC-4/F14a)');
      expect(workspace.server.keyedEpochs(workspace.workspaceId), epochsBefore,
          reason: 'and no epoch row was minted');
      expect(await a.client.epochFloor(), 1, reason: 'the floor did not move');
      expect(
        workspace.server.hasLiveGrant(
          workspace.workspaceId,
          workspace.b.identity.memberId,
        ),
        isTrue,
        reason: 'the Device the ceremony was going to revoke is untouched, which is '
            'the recoverable outcome — a half-run ceremony is not',
      );
    });
  });

  group('scheduled rotation', () {
    test('an epoch older than the interval is due, and a fresh one is not', () async {
      final workspace = await SimWorkspace.create(deviceCount: 1);
      addTearDown(workspace.close);
      final a = workspace.a;

      expect(await a.enrolment.workspacesDueForRotation(), isEmpty,
          reason: 'an unencrypted Workspace is never due: turning encryption on is '
              'an owner\'s decision, never a timer\'s');

      await a.enrolment.turnOnEncryption(passphrase: workspace.passphrase);
      await a.sync();
      expect(await a.enrolment.workspacesDueForRotation(), isEmpty);

      workspace.clock.advance(quarterlyRotationInterval.inMilliseconds + 1);
      expect(
        await a.enrolment.workspacesDueForRotation(),
        containsAll([workspace.workspaceId, workspace.preferencesWorkspaceId]),
        reason: 'the trigger reads the epoch\'s age off the signed log, so every '
            'device agrees about it',
      );

      // And running the ceremony clears it.
      await a.enrolment.turnOnEncryption(passphrase: workspace.passphrase);
      expect(await a.enrolment.workspacesDueForRotation(), isEmpty);
      expect(await a.client.epochFloor(), 2);
    });
  });

  group('a Workspace keyed at genesis', () {
    test('is encrypted from its first content op, at epoch 0', () async {
      final server = FakeSyncServer();
      final clock = FakeClock(simulationStartWallMs);
      final device = await SimDevice.create(
        label: 'A',
        userId: 'genesis-encrypted-user',
        server: server,
        clock: clock,
        encryptFromGenesis: true,
      );
      addTearDown(device.close);

      await device.client.capture(
        collection: _collection,
        entityId: _entityId('first'),
        fields: {'title': _marker},
      );
      await device.sync();

      final content = _contentOps(server, device.client.workspaceId).single;
      expect(content.header!.suite, suiteAeadV1);
      expect(content.header!.keyEpoch, 0,
          reason: 'nothing rotated *to* epoch 0 — a fresh Workspace is simply keyed '
              'there, and its digest travels in the wraps PUT');
      expect(_containsMarker(content.envelope), isFalse);
      expect(server.keyedEpochs(device.client.workspaceId), [0]);
      expect(await device.client.epochFloor(), 0);
    });
  });
}
