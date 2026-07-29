/// End-to-end: two simulated devices converge through the op log.
///
/// This file is the acceptance criteria of #546 and, since #548, the trust half
/// too. Every case runs the whole spine — enrol → local write → signed envelope
/// → server log → pull → verify → reduce — in one process, on a fake clock,
/// with no PowerSync engine in sight. That last part is the point: `docs/SYNC.md`
/// records zero automated coverage of the engine path, and closing that gap is
/// one of ADR-0026's motivations.
///
/// The devices here enrol for real: device A generates the passphrase and Root,
/// device B is given the passphrase string and nothing else. No test hands a
/// key from one device to another.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Ed25519;
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/control_payload.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/root_authority.dart';
import 'package:jeeves/sync/sync_transport.dart';

import 'harness/author_fixture.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';
import 'vectors.dart';

/// The spec user, so the golden negative vectors — which are signed over the
/// spec workspace id — can be injected into this workspace verbatim.
const String _specUserId = 'spec-user-1';

const String _harnessCollection = 'harness_docs';

Uint8List _fromHex(String hex) {
  final bytes = Uint8List(hex.length ~/ 2);
  for (var index = 0; index < bytes.length; index++) {
    bytes[index] = int.parse(hex.substring(index * 2, index * 2 + 2), radix: 16);
  }
  return bytes;
}

/// A device's log for one Workspace, defaulting to the GTD one.
///
/// Scoped, because a device holds two Workspaces over the same store now — the GTD
/// one and the User-global preferences one — and every sync table is keyed by
/// workspace id.
Future<List<Uint8List>> _opLogEnvelopes(SimDevice device, {String? workspaceId}) async {
  final scope = workspaceId ?? device.client.workspaceId;
  final rows = await (device.database.select(device.database.opLog)
        ..where((row) => row.workspaceId.equals(scope))
        ..orderBy([(row) => OrderingTerm(expression: row.seq)]))
      .get();
  return [for (final row in rows) row.envelope];
}

/// The envelopes in a device's log that carry content — the registers every
/// device now also holds are chain evidence, not data.
Future<List<Uint8List>> _contentEnvelopes(SimDevice device, {String? workspaceId}) async => [
      for (final envelope in await _opLogEnvelopes(device, workspaceId: workspaceId))
        if (OpHeader.parse(envelope).opClass == opClassContent) envelope,
    ];

void main() {
  late SimWorkspace workspace;

  setUp(() async {
    workspace = await SimWorkspace.create(userId: _specUserId);
  });

  tearDown(() => workspace.close());

  // --- AC 1: enrolment ------------------------------------------------------

  test('a second device enrols with the passphrase alone and converges',
      () async {
    // Device B was handed a string. Not a key, not a store, not a session.
    expect(workspace.b.outcome.isFirstDevice, isFalse);
    expect(workspace.b.outcome.passphrase, workspace.a.outcome.passphrase);
    expect(workspace.b.outcome.rootPk, workspace.a.outcome.rootPk);
    expect(await workspace.b.client.pinnedRootPk(), workspace.a.outcome.rootPk);

    // Each device's **first** op is the control op that registers it — a
    // `member_register`, or the `workspace_genesis` that embeds one (ADR-0031) —
    // and each did it as its own op 1.
    for (final device in workspace.devices) {
      final authored = await device.client.authoredEnvelopes();
      final registering = OpHeader.parse(authored.first);
      expect(registering.opClass, opClassControl);
      expect(registering.authorSeq, 1);
      expect(registering.authorMemberId, device.identity.memberId);
      final payload =
          ControlPayload.decode(parseBody(splitEnvelope(authored.first).body));
      expect(registeringControlTypes, contains(payload.controlType));
      // Op 2 is the explicit root-signed owner Grant: roles are one
      // materialisation path, so nothing is implied — genesis included.
      final grant = ControlPayload.decode(
        parseBody(splitEnvelope(authored[1]).body),
      );
      expect(grant.controlType, controlTypeGrant);
      expect(grant.authority, granterRoot);
      expect(grant.grantCertificate().role, roleOwner);
      expect(grant.grantCertificate().memberId, device.identity.memberId);
    }

    // The default Workspace's control chain: A founds it and grants itself, then
    // B registers against what it observed and grants itself. Four ops, each
    // naming its predecessor by payload hash.
    final control = [
      for (final op in workspace.server.storedOps)
        if (op.workspaceId == workspace.workspaceId &&
            op.header?.opClass == opClassControl)
          parseBody(splitEnvelope(op.envelope).body),
    ];
    expect(control.length, 4);
    expect(
      [for (final bytes in control) ControlPayload.decode(bytes).controlType],
      [
        controlTypeWorkspaceGenesis,
        controlTypeGrant,
        controlTypeMemberRegister,
        controlTypeGrant,
      ],
    );
    // Genesis is the only op that may carry the zero link, and every successor
    // names the payload bytes of the one before it.
    expect(ControlPayload.decode(control.first).prevControlHash, zeroPrevControlHash);
    for (var index = 1; index < control.length; index++) {
      expect(
        ControlPayload.decode(control[index]).prevControlHash,
        controlPayloadHash(control[index - 1]),
        reason: 'control op $index does not name its predecessor',
      );
    }
    // The same shape, independently, in the preferences Workspace: two implicit
    // Workspaces per User, each with its own genesis.
    final prefsControl = [
      for (final op in workspace.server.storedOps)
        if (op.workspaceId == workspace.preferencesWorkspaceId &&
            op.header?.opClass == opClassControl)
          parseBody(splitEnvelope(op.envelope).body),
    ];
    expect(prefsControl.length, 4);
    expect(
      ControlPayload.decode(prefsControl.first).controlType,
      controlTypeWorkspaceGenesis,
    );

    await workspace.a.preferences.set('theme', '"dark"');
    await workspace.syncAll();
    expect(await workspace.b.preferences.get('theme'), '"dark"');

    workspace.clock.advance(1000);
    await workspace.b.preferences.set('theme', '"light"');
    await workspace.syncAll();
    expect(await workspace.a.preferences.get('theme'), '"light"');
  });

  test('each device learns the other only from a verified MemberRegister',
      () async {
    await workspace.syncAll();
    for (final device in workspace.devices) {
      for (final peer in workspace.devices) {
        expect(
          device.client.directory.isChained(peer.identity.memberId),
          isTrue,
          reason: '${device.label} should have chained ${peer.label}',
        );
      }
      expect(await device.client.quarantined(), isEmpty);
    }
  });

  test('two devices converge a user_preferences edit in both directions',
      () async {
    await workspace.a.preferences.set('theme', '"dark"');
    await workspace.syncAll();
    expect(await workspace.b.preferences.get('theme'), '"dark"');

    workspace.clock.advance(1000);
    await workspace.b.preferences.set('theme', '"light"');
    await workspace.syncAll();
    expect(await workspace.a.preferences.get('theme'), '"light"');
    expect(await workspace.b.preferences.get('theme'), '"light"');
  });

  test('a deletion converges as a tombstone, not as row absence', () async {
    await workspace.a.preferences.set('theme', '"dark"');
    await workspace.a.preferences.set('font', '"serif"');
    await workspace.syncAll();
    expect(await workspace.b.preferences.getAll(),
        {'theme': '"dark"', 'font': '"serif"'});

    workspace.clock.advance(1000);
    await workspace.b.preferences.delete('theme');
    await workspace.syncAll();
    expect(await workspace.a.preferences.get('theme'), isNull);
    expect(await workspace.a.preferences.getAll(), {'font': '"serif"'});
  });

  test('both devices creating the same preference offline converge as one row',
      () async {
    // The entity id is uuid5(workspace, key), so the two writes are edits of
    // one entity rather than two rows racing a unique constraint.
    workspace.b.goOffline();
    await workspace.a.preferences.set('theme', '"dark"');
    workspace.clock.advance(1000);
    await workspace.b.preferences.set('theme', '"light"');

    workspace.b.goOnline();
    await workspace.syncAll();

    expect(await workspace.a.preferences.getAll(), {'theme': '"light"'});
    expect(await workspace.b.preferences.getAll(), {'theme': '"light"'});
  });

  // --- AC 2 -----------------------------------------------------------------

  test('offline edits queue and converge on reconnect', () async {
    workspace.b.goOffline();
    for (final key in ['one', 'two', 'three']) {
      workspace.clock.advance(100);
      await workspace.b.preferences.set(key, '"$key"');
    }
    workspace.clock.advance(100);
    await workspace.a.preferences.set('from_a', '"a"');
    await workspace.syncAll();
    expect(await workspace.a.preferences.getAll(), {'from_a': '"a"'});

    workspace.b.goOnline();
    await workspace.syncAll();

    const expected = {
      'one': '"one"',
      'two': '"two"',
      'three': '"three"',
      'from_a': '"a"',
    };
    expect(await workspace.a.preferences.getAll(), expected);
    expect(await workspace.b.preferences.getAll(), expected);
  });

  test('replaying an already-accepted batch is a no-op', () async {
    workspace.clock.advance(100);
    await workspace.b.preferences.set('one', '"one"');
    workspace.clock.advance(100);
    await workspace.b.preferences.set('two', '"two"');
    await workspace.syncAll();

    final stateBefore = await workspace.a.preferences.getAll();
    final logBefore = await _opLogEnvelopes(workspace.a);

    final replayed = await workspace.b.client.authoredEnvelopes();
    final results = await workspace.b.link.postOps(workspace.workspaceId, replayed);
    expect(results.map((result) => result.duplicate), everyElement(isTrue));

    await workspace.syncAll();
    expect(await workspace.a.preferences.getAll(), stateBefore);
    expect(await _opLogEnvelopes(workspace.a), logBefore);
  });

  test('a lost POST response re-sends and dedupes rather than duplicating',
      () async {
    workspace.clock.advance(100);
    await workspace.a.preferences.set('theme', '"dark"');

    // The server appended; the acknowledgement never came back. Flushed through
    // the *preferences* client, because that is the Workspace the write landed
    // in — a flush of the GTD Workspace has nothing pending to lose.
    final prefs = await workspace.a.preferencesClient;
    workspace.a.link.dropPostResponse = true;
    await expectLater(
      prefs.flushOutbox(),
      throwsA(isA<SyncTransportException>()),
    );
    // The flag is one-shot, so the re-send below reaches the server and observes
    // the duplicate result — the thing this case is actually about.
    expect(workspace.a.link.dropPostResponse, isFalse);

    await workspace.syncAll();
    expect(await workspace.b.preferences.getAll(), {'theme': '"dark"'});
    expect(
      (await _contentEnvelopes(
        workspace.b,
        workspaceId: workspace.preferencesWorkspaceId,
      ))
          .length,
      1,
    );
  });

  // --- AC 5 -----------------------------------------------------------------

  test('concurrent edits to different fields of one row both survive',
      () async {
    // user_preferences rows have one field that changes, so the field-grain
    // case needs a two-field collection. Registering one here also exercises
    // the extension point #550 hangs its collections off.
    final docId = preferenceEntityId(workspace.workspaceId, 'harness-doc');
    final viewA = workspace.a.registry.register(_harnessCollection);
    final viewB = workspace.b.registry.register(_harnessCollection);

    // Same fake-clock reading on both devices: genuinely concurrent HLCs.
    await workspace.a.client.capture(
      collection: _harnessCollection,
      entityId: docId,
      fields: {'a': 'from_a'},
    );
    await workspace.b.client.capture(
      collection: _harnessCollection,
      entityId: docId,
      fields: {'b': 'from_b'},
    );
    await workspace.syncAll();

    const expected = {'a': 'from_a', 'b': 'from_b'};
    expect(await viewA.readEntity(docId), expected);
    expect(await viewB.readEntity(docId), expected);
  });

  test('concurrent edits to the same field resolve identically on both devices',
      () async {
    final docId = preferenceEntityId(workspace.workspaceId, 'harness-doc');
    final viewA = workspace.a.registry.register(_harnessCollection);
    final viewB = workspace.b.registry.register(_harnessCollection);

    await workspace.a.client.capture(
      collection: _harnessCollection,
      entityId: docId,
      fields: {'a': 'from_a'},
    );
    await workspace.b.client.capture(
      collection: _harnessCollection,
      entityId: docId,
      fields: {'a': 'from_b'},
    );
    await workspace.syncAll();

    // Equal wall_ms and counter, so the member id decides — and the point is
    // that both devices decide the same way, not which one wins.
    final winner = (await viewA.readEntity(docId))!['a'];
    expect(await viewB.readEntity(docId), {'a': winner});
    final membersAscending = [
      workspace.a.identity.memberIdHex,
      workspace.b.identity.memberIdHex,
    ]..sort();
    expect(
      winner,
      membersAscending.last == workspace.a.identity.memberIdHex ? 'from_a' : 'from_b',
    );
  });

  // --- AC 4: nothing the server says is trusted -----------------------------

  test('the golden negative vectors quarantine and never apply', () async {
    final document = envelopeVectors();
    final identities = document['identities'] as Map<String, dynamic>;

    // The spec keys must be chained, or every vector would stop at the
    // not-chained check instead of reaching the rule it exists to exercise.
    // Chaining them means real Root-signed registers — the only way in.
    await workspace.syncAll();
    final root = await workspace.recoverRoot();
    for (final entry in identities['keys'] as List<dynamic>) {
      final key = entry as Map<String, dynamic>;
      final fixture = await AuthorFixture.create(
        memberId: key['member_id'] as String,
        seed: _fromHex(key['seed_hex'] as String),
      );
      workspace.server.injectUnchecked(
        workspace.workspaceId,
        await memberRegisterEnvelope(
          device: fixture,
          workspaceId: workspace.workspaceId,
          root: root,
          prevControlHash: workspace.controlChainHead(),
          wallMs: workspace.clock.nowMs,
        ),
      );
    }
    root.drop();

    final negatives = vectorList(document, 'negative_vectors');
    for (final vector in negatives) {
      workspace.server.injectUnchecked(
        workspace.workspaceId,
        _fromHex(vector['envelope_hex'] as String),
      );
    }

    // A valid op after the bad ones: the stream must not stall on refusal.
    workspace.clock.advance(1000);
    await workspace.a.preferences.set('theme', '"dark"');
    await workspace.syncAll();

    for (final device in workspace.devices) {
      final quarantined = await device.client.quarantined();
      expect(
        quarantined.map((row) => row.reason).toList(),
        negatives.map((vector) => vector['reason']).toList(),
        reason: 'device ${device.label}',
      );
      expect(await device.preferences.getAll(), {'theme': '"dark"'});
      // Nothing refused reached the log: quarantine is not a soft filter. The
      // preference write is the only content op, and it is in the preferences
      // Workspace — the injected vectors went into the GTD one and stayed out.
      expect(
        (await _contentEnvelopes(
          device,
          workspaceId: workspace.preferencesWorkspaceId,
        ))
            .length,
        1,
      );
      expect(await _contentEnvelopes(device), isEmpty);
    }
  });

  test('the golden negative control vectors fail closed', () async {
    // Signed by the *spec* Root, which is not this workspace's Root — so
    // `control_bad_root_signature` is not the only one that would fail. Each is
    // injected on its own and asserted for its own reason.
    //
    // Three refusals a *stateful* receiver reaches before the codec's are accepted
    // alongside the vector's own, and all three are strictly stronger. Every entry
    // here widens the accepted alternative for *every* vector in this loop, not
    // just for the ones that motivated it — so each has to be a refusal that is
    // stronger than any pinned reason, whichever vector produces it:
    //
    // * `member_not_chained_to_root` — a Grant or Revoke is authored by an
    //   already-registered member, so this device verifies the envelope against
    //   its chain-gated directory first. The spec's authors are strangers to it,
    //   and refusing a stranger before examining the authority it claims is the
    //   whole point of chain-gating.
    // * `control_chain_break` — the vector names a predecessor this device's
    //   applied control log does not hold. A codec has no chain state to check
    //   against; a receiver does, and a control op that does not fit its chain is
    //   refused whatever its certificate says.
    // * `bad_root_signature` — every certificate here is signed by the *spec*
    //   Root, which is not the Root this workspace pinned. A receiver that pinned
    //   a different Root refuses a foreign-Root certificate before examining what
    //   it binds to, which is why the two certificate-mismatch vectors never reach
    //   their own reason here: refusing a certificate outright is stronger than
    //   objecting to the member or key it names.
    const strongerRefusals = {
      SyncRejectionReason.memberNotChainedToRoot,
      SyncRejectionReason.controlChainBreak,
      SyncRejectionReason.badRootSignature,
    };
    await workspace.syncAll();
    // Every device this loop enrols grants itself, so the set of legitimate
    // grantees grows as it runs. Accumulating them is what keeps the assertion
    // below about *strangers* rather than about a count.
    final enrolledMembers = {
      for (final peer in workspace.devices) peer.identity.memberId,
    };
    final document = envelopeVectors();
    for (final vector in vectorList(document, 'negative_control_vectors')) {
      final device = await SimDevice.create(
        label: 'X',
        userId: _specUserId,
        server: workspace.server,
        clock: workspace.clock,
        passphrase: workspace.passphrase,
      );
      addTearDown(device.close);
      workspace.server.injectUnchecked(
        workspace.workspaceId,
        _fromHex(vector['envelope_hex'] as String),
      );
      await device.sync();
      final refusals = (await device.client.quarantined())
          .map((row) => SyncRejectionReason.byCode(row.reason))
          .toSet();
      expect(
        refusals.any((reason) =>
            reason.code == vector['reason'] || strongerRefusals.contains(reason)),
        isTrue,
        reason: '${vector['name']} produced $refusals, '
            'not ${vector['reason']} nor a stronger refusal',
      );
      // Whatever the reason, nothing was applied: the whole family fails closed.
      // Asserted by *identity* rather than by a count — a count would pass if one
      // Grant were swapped for another. Every Grant this device holds must name
      // one of the Workspace's own devices, so a vector's synthetic grantee
      // entering the view would show up here.
      enrolledMembers.add(device.identity.memberId);
      for (final grant in await device.client.grants()) {
        expect(
          enrolledMembers,
          contains(grant.memberId),
          reason: '${vector['name']} put a stranger in the grants view',
        );
      }
    }
  });

  test('an op from a member not chained to Root quarantines', () async {
    // Registered with the server, and therefore in `GET /members` — and still
    // refused, because the registry is not what a client believes.
    final stranger = await AuthorFixture.create(
      seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 11)),
    );
    workspace.server.poisonRegistry(
      _specUserId,
      MemberRecord(
        memberId: stranger.memberId,
        signPk: stranger.signPk,
        keyId: deriveKeyId(stranger.signPk),
        kexPk: stranger.kexPk,
        chained: true,
      ),
    );
    workspace.server.injectUnchecked(
      workspace.workspaceId,
      await stranger.nextEnvelope(workspace.workspaceId),
    );

    await workspace.a.sync();
    final quarantined = await workspace.a.client.quarantined();
    expect(
      quarantined.single.reason,
      SyncRejectionReason.memberNotChainedToRoot.code,
    );
  });

  test('a fabricated MemberRegister with a foreign certificate is refused',
      () async {
    // The poisoned-registry attack, aimed at the log instead: a server can
    // serve any control op it likes, and without Root behind the certificate it
    // is a claim rather than a registration.
    await workspace.syncAll();
    final impostor = await AuthorFixture.create(
      seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 61)),
    );
    final foreignRoot = await RootAuthority.generate();
    workspace.server.injectUnchecked(
      workspace.workspaceId,
      await memberRegisterEnvelope(
        device: impostor,
        workspaceId: workspace.workspaceId,
        root: foreignRoot,
        prevControlHash: workspace.controlChainHead(),
        wallMs: workspace.clock.nowMs,
      ),
    );

    await workspace.a.sync();
    expect(
      (await workspace.a.client.quarantined()).single.reason,
      SyncRejectionReason.badRootSignature.code,
    );
    expect(workspace.a.client.directory.isChained(impostor.memberId), isFalse);
  });

  test('a genuine certificate around a forged envelope is refused', () async {
    // Step 4 of the verification, and the reason it exists: a certificate is
    // public once it is in the log, so without checking the envelope signature
    // against the certificate's own key anyone could wrap a copy around
    // self-signed envelopes and fork the victim's chain.
    await workspace.syncAll();
    final victim = await AuthorFixture.create(
      seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 71)),
    );
    final root = await workspace.recoverRoot();
    final certificate = RegistrationCertificate(
      workspaceId: workspace.workspaceId,
      memberId: victim.memberId,
      signPk: victim.signPk,
      kexPk: victim.kexPk,
      registeredAtHlc: Hlc.forMember(victim.memberId, workspace.clock.nowMs),
    );
    // The forger authors the envelope under its *own* key, wrapping the
    // victim's genuine certificate.
    final forger = await AuthorFixture.create(
      memberId: victim.memberId,
      seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 81)),
    );
    final certBytes = certificate.encode();
    workspace.server.injectUnchecked(
      workspace.workspaceId,
      await forger.nextEnvelope(
        workspace.workspaceId,
        opClass: opClassControl,
        payload: ControlPayload(
          controlType: controlTypeMemberRegister,
          prevControlHash: workspace.controlChainHead(),
          certBytes: certBytes,
          signature: await root.signCertificateBytes(certBytes),
        ).encode(),
      ),
    );
    root.drop();

    await workspace.a.sync();
    expect(
      (await workspace.a.client.quarantined()).single.reason,
      SyncRejectionReason.badSignature.code,
    );
  });

  test('a zero prev_control_hash into a populated chain is a chain break',
      () async {
    await workspace.syncAll();
    final newcomer = await AuthorFixture.create(
      seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 91)),
    );
    final root = await workspace.recoverRoot();
    workspace.server.injectUnchecked(
      workspace.workspaceId,
      await memberRegisterEnvelope(
        device: newcomer,
        workspaceId: workspace.workspaceId,
        root: root,
        // A device that skipped the pull would emit exactly this.
        prevControlHash: zeroPrevControlHash,
        wallMs: workspace.clock.nowMs,
      ),
    );
    root.drop();

    await workspace.a.sync();
    expect(
      (await workspace.a.client.quarantined()).single.reason,
      SyncRejectionReason.controlChainBreak.code,
    );
    expect(workspace.a.client.directory.isChained(newcomer.memberId), isFalse);
  });

  test('an author_seq beyond 2^53 quarantines as unrepresentable', () async {
    // The header field is a true u64, but `dart:typed_data` has no 64-bit
    // accessors on the web, so the client recombines two 32-bit halves and is
    // exact only to 2^53. A larger value is refused rather than silently
    // rounded into a *different* sequence number — which would make one device
    // read a chain slot its peers never wrote.
    final seed = Uint8List.fromList(List<int>.generate(32, (index) => index + 41));
    final author = await AuthorFixture.create(seed: seed);
    await workspace.enrolFixture(author);

    // The 158 header bytes are assembled by hand because `OpHeader.serialize`
    // refuses to *write* a value it could not read back. That asymmetry is the
    // point: only a broken or hostile server can put one on the wire, so only
    // raw bytes can stage the case.
    final template = await author.nextEnvelope(workspace.workspaceId);
    final header = Uint8List.fromList(template.sublist(0, headerLengthBytes));
    final authorSeqOffset = headerFieldOffset('author_seq');
    final view = ByteData.view(header.buffer);
    // 0x0020000000000000 == 2^53, one past the largest representable value.
    view.setUint32(authorSeqOffset, 0x00200000, Endian.big);
    view.setUint32(authorSeqOffset + 4, 0, Endian.big);

    final body = frameBody(Uint8List.fromList(utf8.encode('{"collection":"test"}')));
    // Signed over the doctored header, so neither the signature check nor the
    // key lookup can be what fires: the only thing wrong is the field itself.
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);
    final signature =
        await Ed25519().sign(signingInput(header, body), keyPair: keyPair);
    final envelope = Uint8List.fromList([
      ...header,
      ...body,
      ...signature.bytes,
    ]);
    expect(envelope.length, headerLengthBytes + body.length + signatureLengthBytes);

    workspace.server.injectUnchecked(workspace.workspaceId, envelope);
    await workspace.a.sync();

    final quarantined = await workspace.a.client.quarantined();
    expect(
      quarantined.single.reason,
      SyncRejectionReason.unrepresentableAuthorSeq.code,
    );
    // Nothing was applied: a refusal is not a soft filter.
    expect(await workspace.a.preferences.getAll(), isEmpty);
  });

  test('the quarantine count is watchable so a refusal can be surfaced',
      () async {
    expect(await workspace.a.client.watchQuarantineCount().first, 0);
    workspace.server.injectUnchecked(
      workspace.workspaceId,
      _fromHex(
        vectorList(envelopeVectors(), 'negative_vectors')
            .firstWhere((vector) => vector['name'] == 'unknown_suite')['envelope_hex']
            as String,
      ),
    );
    await workspace.a.sync();
    expect(await workspace.a.client.watchQuarantineCount().first, 1);
  });

  // --- Reducer guards over the full path ---------------------------------------

  group('reducer guards', () {
    /// The server is content-blind for content ops, so these bodies go through
    /// the *real* POST path: nothing server-side could have caught them, which
    /// is exactly why the guards live on the receiving client.
    Future<(AuthorFixture, SyncTransport)> registerRogue() async {
      final rogue = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 21)),
      );
      return (rogue, await workspace.enrolFixture(rogue));
    }

    Future<void> postPayload(
      AuthorFixture rogue,
      SyncTransport session,
      Map<String, Object?> payload,
    ) async {
      await session.postOps(workspace.workspaceId, [
        await rogue.nextEnvelope(
          workspace.workspaceId,
          payloadJson: jsonEncode(payload),
        ),
      ]);
    }

    test('an op-level HLC far in the future quarantines', () async {
      final (rogue, session) = await registerRogue();
      await postPayload(rogue, session, {
        'collection': _harnessCollection,
        'id': preferenceEntityId(workspace.workspaceId, 'harness-doc'),
        'fields': {
          'a': {'v': 'from_the_future'},
        },
        'hlc': [
          workspace.clock.nowMs + 3600000,
          0,
          memberIdToHex(rogue.memberId),
        ],
      });

      await workspace.a.sync();
      final quarantined = await workspace.a.client.quarantined();
      expect(quarantined.single.reason, SyncRejectionReason.hlcInTheFuture.code);
      expect(
        await workspace.a.registry.register(_harnessCollection).readAll(),
        isEmpty,
      );
    });

    test('an op whose HLC member is not the header author quarantines',
        () async {
      final (rogue, session) = await registerRogue();
      await postPayload(rogue, session, {
        'collection': _harnessCollection,
        'id': preferenceEntityId(workspace.workspaceId, 'harness-doc'),
        'fields': {
          'a': {'v': 'impersonated'},
        },
        'hlc': [
          workspace.clock.nowMs,
          0,
          workspace.a.identity.memberIdHex,
        ],
      });

      await workspace.a.sync();
      final quarantined = await workspace.a.client.quarantined();
      expect(
        quarantined.single.reason,
        SyncRejectionReason.hlcMemberIsNotAuthor.code,
      );
    });

    test('a per-field HLC from another member in the past still applies',
        () async {
      // The F15 exemption, end to end: this is the shape a compaction op
      // (#555) has, and quarantining it would make compaction impossible.
      final (rogue, session) = await registerRogue();
      final docId = preferenceEntityId(workspace.workspaceId, 'harness-doc');
      await postPayload(rogue, session, {
        'collection': _harnessCollection,
        'id': docId,
        'fields': {
          'a': {
            'v': 'reasserted',
            'hlc': [
              workspace.clock.nowMs - 60000,
              7,
              workspace.b.identity.memberIdHex,
            ],
          },
        },
        'hlc': [workspace.clock.nowMs, 0, memberIdToHex(rogue.memberId)],
      });

      await workspace.a.sync();
      expect(await workspace.a.client.quarantined(), isEmpty);
      expect(
        await workspace.a.registry.register(_harnessCollection).readEntity(docId),
        {'a': 'reasserted'},
      );
    });
  });

  // --- Chain and evidence ---------------------------------------------------

  test('authored envelopes chain by author_seq and prev_author_hash', () async {
    // The **preferences** Workspace, because that is where preference writes go
    // now. A device's chain is per Workspace, so this asserts the chain of the log
    // the ops actually land in rather than of a log they never touch.
    final prefs = await workspace.a.preferencesClient;
    for (var index = 0; index < 3; index++) {
      workspace.clock.advance(100);
      await workspace.a.preferences.set('key$index', '"$index"');
    }
    final authored = await prefs.authoredEnvelopes();
    // Genesis is op 1 and the owner self-grant op 2; the three writes follow.
    expect(authored.length, 5);

    var expectedPrevHash = Uint8List(prevAuthorHashBytes);
    for (var index = 0; index < authored.length; index++) {
      final header = OpHeader.parse(authored[index]);
      expect(header.authorSeq, index + 1);
      expect(header.prevAuthorHash, expectedPrevHash);
      expect(header.authorMemberId, workspace.a.identity.memberId);
      expect(header.workspaceId, workspace.preferencesWorkspaceId);
      expectedPrevHash = envelopeHash(authored[index]);
    }
  });

  test('two un-awaited captures claim two chain slots, not one', () async {
    // The chain head is read before the envelope is signed and advanced after,
    // so authoring has to be serialised or two interleaved `capture()` calls
    // both observe the same head — a fork this device signs against itself,
    // which no constraint catches on the authoring side (`op_log`'s unique
    // `(workspace, author, author_seq)` index guards the *receive* path, and
    // neither `outbox` nor `author_state` constrains the slot).
    final docId = preferenceEntityId(workspace.workspaceId, 'harness-doc');
    await Future.wait([
      workspace.a.client.capture(
        collection: _harnessCollection,
        entityId: docId,
        fields: {'a': 'first'},
      ),
      workspace.a.client.capture(
        collection: _harnessCollection,
        entityId: docId,
        fields: {'b': 'second'},
      ),
    ]);

    final authored = await workspace.a.client.authoredEnvelopes();
    final headers = [for (final envelope in authored) OpHeader.parse(envelope)];
    expect(
      headers.map((header) => header.authorSeq),
      List<int>.generate(authored.length, (index) => index + 1),
      reason: 'every authored op holds its own slot',
    );
    var expectedPrevHash = Uint8List(prevAuthorHashBytes);
    for (var index = 0; index < authored.length; index++) {
      expect(headers[index].prevAuthorHash, expectedPrevHash);
      expectedPrevHash = envelopeHash(authored[index]);
    }
    // And the server takes the whole chain: a fork would be refused at the
    // second envelope with `author_chain_conflict`.
    await workspace.syncAll();
    expect(await workspace.a.client.health().then((health) => health.pendingOpCount), 0);
  });

  test('the op log keeps received envelopes byte-identical', () async {
    await workspace.a.preferences.set('theme', '"dark"');
    await workspace.syncAll();
    // Both Workspaces: the guarantee is per log, and A authors in each of them.
    for (final scope in [workspace.workspaceId, workspace.preferencesWorkspaceId]) {
      final fromA = [
        for (final envelope in await _opLogEnvelopes(workspace.b, workspaceId: scope))
          if (OpHeader.parse(envelope).authorMemberId == workspace.a.identity.memberId)
            envelope,
      ];
      final authored = scope == workspace.workspaceId
          ? await workspace.a.client.authoredEnvelopes()
          : await (await workspace.a.preferencesClient).authoredEnvelopes();
      expect(fromA, authored, reason: scope);
    }
  });
}
