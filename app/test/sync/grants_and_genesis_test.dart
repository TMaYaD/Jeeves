/// End-to-end: membership and authority as signed facts in the log.
///
/// This file is the acceptance criteria of #549. Every case drives the whole
/// spine — genesis, Grants, roles, revocation, the epoch floor — and every
/// assertion is about what a *client* concludes, because that is where the
/// guarantee lives: the server's `workspaces` and `grants` tables are its own
/// index, authoritative for nobody (ADR-0028).
///
/// The four acceptance criteria, and where each is pinned:
///
/// * a content op with no live Grant is refused server-side **and** client-side,
///   independently — `no live Grant` and `authorization is independent`;
/// * a served pre-revocation grant row re-admits nobody — `a stale grant row`;
/// * role elevation via server tables is impossible — `role elevation`;
/// * `epoch_floor` survives restart and never decreases — `epoch floor`.
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
import 'package:jeeves/sync/sync_transport.dart';
import 'package:uuid/uuid.dart';

import 'harness/author_fixture.dart';
import 'harness/fake_sync_server.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';

const String _userId = 'grants-user';
const String _harnessCollection = 'harness_docs';
const Uuid _uuid = Uuid();

Matcher throwsStatus(int status, String code) => throwsA(
      predicate<Object>(
        (error) =>
            error is SyncTransportException &&
            error.statusCode == status &&
            error.code == code,
        'a SyncTransportException($status, $code)',
      ),
    );

String _docId(SimWorkspace workspace) =>
    preferenceEntityId(workspace.workspaceId, 'grants-doc');

/// One content op from [author] on a shared entity in the default Workspace.
Future<Uint8List> _contentOp(
  SimWorkspace workspace,
  AuthorFixture author,
  Object? value,
) async {
  workspace.clock.advance(10);
  return author.nextEnvelope(
    workspace.workspaceId,
    payloadJson: jsonEncode({
      'collection': _harnessCollection,
      'id': _docId(workspace),
      'fields': {
        'step': {'v': value},
      },
      'hlc': [workspace.clock.nowMs, 0, memberIdToHex(author.memberId)],
    }),
  );
}

Future<Map<String, Object?>?> _doc(SimDevice device, SimWorkspace workspace) =>
    device.registry.register(_harnessCollection).readEntity(_docId(workspace));

void main() {
  late SimWorkspace workspace;

  setUp(() async {
    workspace = await SimWorkspace.create(userId: _userId);
  });

  tearDown(() => workspace.close());

  // --- Genesis ---------------------------------------------------------------

  group('genesis', () {
    test('is log-state-conditioned, not device-ordinal-conditioned', () async {
      // Every device runs one ceremony and branches on **what the log said**.
      // Device A observed both logs empty and founded both; device B observed
      // both populated and registered into them. Neither took a path the other
      // could not have taken.
      for (final scope in [workspace.workspaceId, workspace.preferencesWorkspaceId]) {
        final types = [
          for (final op in workspace.server.storedOps)
            if (op.workspaceId == scope && op.header?.opClass == opClassControl)
              ControlPayload.decode(parseBody(splitEnvelope(op.envelope).body))
                  .controlType,
        ];
        expect(
          types,
          [
            controlTypeWorkspaceGenesis,
            controlTypeGrant,
            controlTypeMemberRegister,
            controlTypeGrant,
          ],
          reason: scope,
        );
      }
    });

    test('a later device recovers a Workspace an earlier one never founded',
        () async {
      // The crash window the log-state rule exists to close: the prefs escrow PUT
      // lands, the process dies before the prefs genesis posts. Under a
      // first-device rule every later device would take the "Nth" path into a
      // genesis-less Workspace and be fork-refused for ever.
      final server = FakeSyncServer();
      final clock = FakeClock(simulationStartWallMs);

      // Device A enrols normally, and then the preferences Workspace is *forgotten*
      // — genesis, Grants and log rows alike. That is what a ceremony which wrote
      // the prefs escrow slot and died before posting the prefs genesis leaves
      // behind, and the escrow slot survives because the crash was after it.
      final a = await SimDevice.create(
        label: 'A',
        userId: _userId,
        server: server,
        clock: clock,
      );
      addTearDown(a.close);
      final prefsWorkspaceId = userPreferencesWorkspaceId(_userId);
      server.forgetWorkspace(prefsWorkspaceId);
      expect(
        await server.connectAsUser(_userId).fetchRecoveryEscrow(prefsWorkspaceId),
        isNotNull,
        reason: 'the crash was after the escrow PUT, which is the pinned order',
      );

      // Device B enrols with the passphrase alone, observes the prefs log empty,
      // and authors the genesis A never posted.
      final b = await SimDevice.create(
        label: 'B',
        userId: _userId,
        server: server,
        clock: clock,
        passphrase: a.outcome.passphrase,
      );
      addTearDown(b.close);

      final prefsControl = [
        for (final op in server.storedOps)
          if (op.workspaceId == prefsWorkspaceId &&
              op.header?.opClass == opClassControl)
            ControlPayload.decode(parseBody(splitEnvelope(op.envelope).body)),
      ];
      expect(prefsControl.first.controlType, controlTypeWorkspaceGenesis);
      expect(
        prefsControl.first.genesisCertificate().founder.memberId,
        b.identity.memberId,
        reason: 'B founded the Workspace A left genesis-less',
      );
      // And B is a full owner of it, by an explicit Root-signed Grant.
      final prefs = await b.preferencesClient;
      expect(
        (await prefs.grantsView()).liveRoles(b.identity.memberId),
        contains(roleOwner),
      );
    });

    test('the ceremony pulls before it claims a place in the chain', () async {
      // A device that authored before pulling would emit a fork-lie
      // `prev_control_hash`. The pull runs while it holds a member credential and
      // **no Grant whatsoever**, which is what the server's member-GET rule
      // exists to admit — so this is also the pre-grant read case.
      final joiner = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 61)),
      );
      final user = workspace.server.connectAsUser(_userId);
      await user.registerMember(
        memberId: joiner.memberId,
        signPk: joiner.signPk,
        kexPk: joiner.kexPk,
      );
      final nonce = await user.requestMemberChallenge(joiner.memberId);
      final session = await user.completeMemberChallenge(
        memberId: joiner.memberId,
        nonce: nonce,
        signature: await joiner.signChallenge(nonce),
      );

      // Holding no Grant, it can still read — and reading is how it learns the
      // head its own register must name.
      final page = await session.pullOps(workspace.workspaceId, since: 0, limit: 50);
      expect(page.ops, isNotEmpty);
      expect(
        (await session.pullOps(workspace.workspaceId, since: 0, limit: 50)).ops.length,
        page.ops.length,
      );

      // ...and it cannot write content, which is where the storage-DoS door is shut.
      await expectLater(
        () async => session.postOps(
          workspace.workspaceId,
          [await _contentOp(workspace, joiner, 'from an ungranted member')],
        ),
        throwsStatus(403, 'no_live_grant'),
      );
    });
  });

  // --- AC 1: no live Grant ---------------------------------------------------

  group('no live Grant', () {
    test('the server refuses a content op from an ungranted member', () async {
      final ungranted = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 71)),
      );
      // Chained but never granted: the register lands, the Grant does not.
      final session = await workspace.enrolFixture(ungranted, grant: false);
      await expectLater(
        () async => session.postOps(
          workspace.workspaceId,
          [await _contentOp(workspace, ungranted, 'unauthorized')],
        ),
        // No `revoked` marker: never granted is not the same claim as taken away.
        throwsStatus(403, 'no_live_grant'),
      );
    });

    test('a client refuses one the server let through, independently', () async {
      // AC 1's client half. The op is injected past every server check, so the
      // only thing standing between it and the reduced state is the client's own
      // authorization stage — which reads the log, never the server's tables.
      final ungranted = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 81)),
      );
      await workspace.enrolFixture(ungranted, grant: false);
      await workspace.a.sync();

      workspace.server.injectUnchecked(
        workspace.workspaceId,
        await _contentOp(workspace, ungranted, 'smuggled'),
      );
      await workspace.a.sync();

      expect(await _doc(workspace.a, workspace), isNull);
      final refused = await workspace.a.client.quarantined();
      expect(
        refused.map((row) => row.reason),
        contains(SyncRejectionReason.noLiveGrant.code),
      );
      // Surfaced, not merely skipped: the server served an op its own index says
      // it should have refused, and that is worth an accusation.
      expect(
        (await workspace.a.client.integrityAlarms()).map((alarm) => alarm.kind),
        contains(IntegrityAlarmKind.noLiveGrant.code),
      );
    });

    test('the verdict is positional: a pre-revocation op still applies',
        () async {
      // What keeps late arrivals honest. An op that predates a revocation must not
      // be retro-quarantined because the revocation has since applied, or a device
      // that saw it in time would diverge from one that saw it late.
      final peer = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 91)),
      );
      final session = await workspace.enrolFixture(peer, role: roleParticipant);

      final before = await _contentOp(workspace, peer, 'before the revocation');
      final appended = await session.postOps(workspace.workspaceId, [before]);

      final root = await workspace.recoverRoot();
      final grantId = workspace.server.storedOps
          .where((op) => op.header?.opClass == opClassControl)
          .map((op) => ControlPayload.decode(parseBody(splitEnvelope(op.envelope).body)))
          .where((payload) => payload.controlType == controlTypeGrant)
          .map((payload) => payload.grantCertificate())
          .firstWhere((grant) => grant.memberId == peer.memberId)
          .grantId;
      final revoke = await revokeEnvelope(
        device: peer,
        workspaceId: workspace.workspaceId,
        root: root,
        prevControlHash: workspace.controlChainHead(),
        grantId: grantId,
        wallMs: workspace.clock.nowMs,
      );
      // Authored by the peer itself under Root's signature — the authority is
      // Root's, and the envelope author only has to be a member the log knows.
      await session.postOps(workspace.workspaceId, [revoke]);
      root.drop();

      // Authored *after* the revoke, so the peer's own chain stays contiguous and
      // the op lands at a seq beyond the revocation boundary.
      final after = await _contentOp(workspace, peer, 'after the revocation');
      workspace.server.injectUnchecked(workspace.workspaceId, after);
      await workspace.a.sync();

      // The earlier op applied; the later one did not.
      expect(await _doc(workspace.a, workspace), {'step': 'before the revocation'});
      final view = await workspace.a.client.grantsView();
      final grant = view.grants[grantId]!;
      expect(grant.revokedBySeq, isNotNull);
      expect(grant.wasLiveAt(appended.single.seq), isTrue);
      expect(grant.wasLiveAt(grant.revokedBySeq! + 1), isFalse);
    });
  });

  // --- AC 3: role elevation is impossible -----------------------------------

  test('role elevation through the servers own grants index is impossible',
      () async {
    // AC 3. The server's index is flipped from participant to owner; every
    // client's verdict is unmoved, because a client derives roles from the signed
    // control ops in the log and never reads that table.
    final peer = await AuthorFixture.create(
      seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 121)),
    );
    await workspace.enrolFixture(peer, role: roleParticipant);
    await workspace.a.sync();

    final grantId = _grantIdFor(workspace, peer.memberId);
    final before = (await workspace.a.client.grantsView()).liveRoles(peer.memberId);
    expect(before, {roleParticipant});

    workspace.server.poisonGrantRole(workspace.workspaceId, grantId, roleOwner);
    await workspace.a.sync();

    expect(
      (await workspace.a.client.grantsView()).liveRoles(peer.memberId),
      before,
      reason: 'the log said participant, and the log is what a client reads',
    );
  });

  test('a stale grant row does not re-admit a revoked member on any client',
      () async {
    // AC 2. The revoke is in the log; the server's index is then un-revoked
    // behind it. Chain-gating is what makes the lie inert.
    final peer = await AuthorFixture.create(
      seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 131)),
    );
    final session = await workspace.enrolFixture(peer, role: roleParticipant);
    final grantId = _grantIdFor(workspace, peer.memberId);

    final root = await workspace.recoverRoot();
    await session.postOps(workspace.workspaceId, [
      await revokeEnvelope(
        device: peer,
        workspaceId: workspace.workspaceId,
        root: root,
        prevControlHash: workspace.controlChainHead(),
        grantId: grantId,
        wallMs: workspace.clock.nowMs,
      ),
    ]);
    root.drop();
    await workspace.a.sync();
    expect(
      (await workspace.a.client.grantsView()).isRevoked(peer.memberId),
      isTrue,
    );

    // The server changes its mind. The log has not.
    workspace.server.poisonGrantLiveness(workspace.workspaceId, grantId);
    expect(workspace.server.hasLiveGrant(workspace.workspaceId, peer.memberId), isTrue);
    await workspace.a.sync();

    expect(
      (await workspace.a.client.grantsView()).isRevoked(peer.memberId),
      isTrue,
      reason: 'a signed revocation outranks a served row',
    );
    // And content authored after the boundary still does not apply.
    workspace.server.injectUnchecked(
      workspace.workspaceId,
      await _contentOp(workspace, peer, 'after being revoked'),
    );
    await workspace.a.sync();
    expect(await _doc(workspace.a, workspace), isNull);
  });

  // --- AC 4: the epoch floor ------------------------------------------------

  group('epoch floor', () {
    test('genesis fixes it at zero and it never decreases', () async {
      final client = workspace.a.client;
      expect(await client.epochFloor(), 0);
      expect(await client.raiseEpochFloor(3), 3);
      expect(await client.epochFloor(), 3);
      // Raise-only: a request to lower it is the no-op it has to be, because a
      // floor that could fall would let a rotation be undone by an older op.
      expect(await client.raiseEpochFloor(1), 3);
      expect(await client.epochFloor(), 3);
      expect(await client.raiseEpochFloor(0), 3);
    });

    test('authoring below the floor is refused', () async {
      await workspace.a.client.raiseEpochFloor(2);
      await expectLater(
        workspace.a.client.capture(
          collection: _harnessCollection,
          entityId: _docId(workspace),
          fields: const {'step': 'below the floor'},
        ),
        throwsA(
          predicate<Object>(
            (error) =>
                error is SyncRejection &&
                error.reason == SyncRejectionReason.keyEpochBelowFloor,
            'a key_epoch_below_floor rejection',
          ),
        ),
      );
    });

    test('survives a restart', () async {
      final device = await SimDevice.create(
        label: 'R',
        userId: 'epoch-floor-user',
        server: FakeSyncServer(),
        clock: FakeClock(simulationStartWallMs),
        fileBacked: true,
      );
      addTearDown(device.close);
      await device.client.raiseEpochFloor(7);

      final reopened = await device.reopenSyncStore();
      expect(
        await reopened.epochFloor(),
        7,
        reason: 'a floor that did not survive a restart would not be a floor',
      );
    });
  });

  // --- The preferences Workspace -------------------------------------------

  test('the preferences Workspace refuses a Service grant on both sides',
      () async {
    final prefs = await workspace.a.preferencesClient;
    final service = await AuthorFixture.create(
      seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 141)),
    );
    final user = workspace.server.connectAsUser(_userId);
    await user.registerMember(
      memberId: service.memberId,
      signPk: service.signPk,
      kexPk: service.kexPk,
    );
    final nonce = await user.requestMemberChallenge(service.memberId);
    final session = await user.completeMemberChallenge(
      memberId: service.memberId,
      nonce: nonce,
      signature: await service.signChallenge(nonce),
    );

    // A genuinely Service-kind registration, Root-signed, into the preferences
    // Workspace's control chain.
    final root = await workspace.recoverRoot();
    final certificate = RegistrationCertificate(
      workspaceId: prefs.workspaceId,
      memberId: service.memberId,
      signPk: service.signPk,
      kexPk: service.kexPk,
      registeredAtHlc: Hlc.forMember(service.memberId, workspace.clock.nowMs),
      memberKind: memberKindService,
    );
    final register = await memberRegisterEnvelope(
      device: service,
      workspaceId: prefs.workspaceId,
      root: root,
      prevControlHash: workspace.controlChainHead(prefs.workspaceId),
      wallMs: workspace.clock.nowMs,
      certificate: certificate,
    );
    await session.postOps(prefs.workspaceId, [register]);

    // Server side: the Grant is refused outright.
    final grant = await grantEnvelope(
      device: service,
      workspaceId: prefs.workspaceId,
      root: root,
      prevControlHash: controlPayloadHash(parseBody(splitEnvelope(register).body)),
      memberId: service.memberId,
      role: roleSuggester,
      wallMs: workspace.clock.nowMs,
    );
    await expectLater(
      () => session.postOps(prefs.workspaceId, [grant]),
      throwsStatus(422, 'service_grant_forbidden'),
    );

    // Client side, independently: injected past the server, it still does not
    // enter the grants view.
    workspace.server.injectUnchecked(prefs.workspaceId, grant);
    await prefs.pull();
    root.drop();

    expect((await prefs.grantsView()).liveRoles(service.memberId), isEmpty);
    expect(
      (await prefs.quarantined()).map((row) => row.reason),
      contains(SyncRejectionReason.serviceGrantForbidden.code),
    );
  });

  test('the default Workspace admits a Service grant', () async {
    // The mirror: the rule is the preferences Workspace's, not a global ban.
    final service = await AuthorFixture.create(
      seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 151)),
    );
    final user = workspace.server.connectAsUser(_userId);
    await user.registerMember(
      memberId: service.memberId,
      signPk: service.signPk,
      kexPk: service.kexPk,
    );
    final nonce = await user.requestMemberChallenge(service.memberId);
    final session = await user.completeMemberChallenge(
      memberId: service.memberId,
      nonce: nonce,
      signature: await service.signChallenge(nonce),
    );

    final root = await workspace.recoverRoot();
    final register = await memberRegisterEnvelope(
      device: service,
      workspaceId: workspace.workspaceId,
      root: root,
      prevControlHash: workspace.controlChainHead(),
      wallMs: workspace.clock.nowMs,
      certificate: RegistrationCertificate(
        workspaceId: workspace.workspaceId,
        memberId: service.memberId,
        signPk: service.signPk,
        kexPk: service.kexPk,
        registeredAtHlc: Hlc.forMember(service.memberId, workspace.clock.nowMs),
        memberKind: memberKindService,
      ),
    );
    await session.postOps(workspace.workspaceId, [register]);
    final grant = await grantEnvelope(
      device: service,
      workspaceId: workspace.workspaceId,
      root: root,
      prevControlHash: controlPayloadHash(parseBody(splitEnvelope(register).body)),
      memberId: service.memberId,
      role: roleSuggester,
      wallMs: workspace.clock.nowMs,
    );
    final results = await session.postOps(workspace.workspaceId, [grant]);
    root.drop();
    expect(results.single.duplicate, isFalse);

    await workspace.a.sync();
    expect(
      (await workspace.a.client.grantsView()).liveRoles(service.memberId),
      {roleSuggester},
    );
  });

  // --- Roles ----------------------------------------------------------------

  test('a suggester Grant exists, is applied, and denies content', () async {
    // #557 owns the suggestion pipeline; this slice grants the role and enforces
    // it to *deny*, which is the whole of what it promises.
    final suggester = await AuthorFixture.create(
      seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 161)),
    );
    final session = await workspace.enrolFixture(suggester, role: roleSuggester);
    await workspace.a.sync();

    expect(
      (await workspace.a.client.grantsView()).liveRoles(suggester.memberId),
      {roleSuggester},
    );
    await expectLater(
      () async => session.postOps(
        workspace.workspaceId,
        [await _contentOp(workspace, suggester, 'from a suggester')],
      ),
      throwsStatus(403, 'role_forbids_op_class'),
    );

    // And a client refuses it independently, if a server ever let one through.
    workspace.server.injectUnchecked(
      workspace.workspaceId,
      await _contentOp(workspace, suggester, 'smuggled by a suggester'),
    );
    await workspace.a.sync();
    expect(await _doc(workspace.a, workspace), isNull);
  });

  test('an owning Device delegates a lesser role without the passphrase',
      () async {
    // Devices are owners because the User acts through them, and delegating is
    // what that authority is *for*. Minting an owner still takes Root.
    final grantee = await AuthorFixture.create(
      seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 171)),
    );
    final session = await workspace.enrolFixture(grantee, grant: false);
    await workspace.a.sync();

    final certificate = GrantCertificate(
      workspaceId: workspace.workspaceId,
      grantId: _uuid.v4(),
      memberId: grantee.memberId,
      role: roleParticipant,
      granter: workspace.a.identity.memberId,
      grantedAtHlc: Hlc.forMember(grantee.memberId, workspace.clock.nowMs),
    );
    final certBytes = certificate.encode();
    // Signed with the *Device's own* key — no Root anywhere in this path.
    final envelope = await workspace.a.identity.signer.buildEnvelope(
      OpHeader(
        workspaceId: workspace.workspaceId,
        opClass: opClassControl,
        opId: _uuid.v4(),
        authorMemberId: workspace.a.identity.memberId,
        authorKeyId: workspace.a.identity.keyId,
        authorSeq: (await workspace.a.client.authoredEnvelopes()).length + 1,
        prevAuthorHash: envelopeHash(
          (await workspace.a.client.authoredEnvelopes()).last,
        ),
      ),
      frameBody(
        ControlPayload(
          controlType: controlTypeGrant,
          prevControlHash: workspace.controlChainHead(),
          certBytes: certBytes,
          signature: await workspace.a.identity.signer.signBytes(
            domainSeparated(signingDomainGrantV1, [certBytes]),
          ),
          authority: workspace.a.identity.memberId,
        ).encode(),
      ),
    );
    final posted = await workspace.a.link.postOps(workspace.workspaceId, [envelope]);
    expect(posted.single.duplicate, isFalse);

    await workspace.b.sync();
    expect(
      (await workspace.b.client.grantsView()).liveRoles(grantee.memberId),
      {roleParticipant},
    );

    // ...and the delegated participant can actually write.
    final results = await session.postOps(
      workspace.workspaceId,
      [await _contentOp(workspace, grantee, 'from a delegated participant')],
    );
    expect(results.single.duplicate, isFalse);
  });
}

/// The grant id in the log for [memberId] — read from the signed control ops.
///
/// Never from a server table: a test that took the server's word for which Grant
/// is which could not then prove the server's word does not matter.
String _grantIdFor(SimWorkspace workspace, String memberId) {
  for (final op in workspace.server.storedOps) {
    if (op.header?.opClass != opClassControl) continue;
    if (op.workspaceId != workspace.workspaceId) continue;
    final payload = ControlPayload.decode(parseBody(splitEnvelope(op.envelope).body));
    if (payload.controlType != controlTypeGrant) continue;
    final grant = payload.grantCertificate();
    if (grant.memberId == memberId) return grant.grantId;
  }
  throw StateError('no Grant for $memberId in the log');
}
