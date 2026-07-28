/// The server contract, asserted against the in-process fake.
///
/// This file is the twin of `backend/tests/sync/test_ops_routes.py`,
/// `test_recovery_escrow_routes.py` and `test_member_auth_routes.py`: the same
/// cases under the same names. The harness's convergence tests are only
/// evidence about the real system if the double they run against behaves like
/// the real server, and a missing or failing twin here is how a divergence
/// announces itself.
///
/// Every assertion is on the structured `detail.code`, never on a message —
/// the codes are the contract and the prose is not.
///
/// Cases with no twin, and why. `POST /members` accepts an optional `key_id`
/// claim the server must re-derive; [UserTransport] has no way to send one (a
/// client has no reason to), and the derivation itself is covered below.
/// `test_ops_require_authentication` and `test_the_escrow_requires_authentication`
/// have no twin because the fake has no unauthenticated state to be in: a
/// session *is* the credential here. The author-chain race in
/// `test_ops_author_chain_race_postgres.py` is a statement about a database
/// under concurrency, and the fake is a single-threaded list.
///
/// The refresh-rotation cases — `test_a_member_refresh_token_rotates`,
/// `test_a_user_refresh_token_cannot_be_rotated_as_a_member`,
/// `test_a_member_refresh_token_cannot_mint_a_user_session` — have no twin
/// because the fake issues no refresh tokens at all: a session here is an
/// object, not a bearer token with a row behind it, so there is nothing to
/// rotate and nothing to launder. That is a real gap in what the harness can
/// witness, and it is the gap the *server* suite has to cover — which is why
/// `test_member_auth_routes.py` walks the whole laundering graph itself rather
/// than trusting this file to notice.
///
/// The two credential-separation cases the fake *can* speak to,
/// `test_a_member_token_is_not_a_user_session` and
/// `test_a_user_credential_cannot_post_ops`, are twinned in the
/// `credential separation` group below — but as assertions about the type split
/// rather than about a 401, because that is the form the guarantee takes here.
/// The real server refuses the wrong credential at runtime; the fake makes the
/// wrong credential unrepresentable. Pinning the split matters precisely because
/// nothing else would notice if a later "harness simplification" gave one object
/// both surfaces, and the fake would then be looser than the server in the one
/// place the server had a hole.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/control_payload.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/recovery_escrow.dart';
import 'package:jeeves/sync/root_authority.dart';
import 'package:jeeves/sync/sync_transport.dart';

import 'harness/author_fixture.dart';
import 'harness/fake_sync_server.dart';

const String _userId = 'contract-user';
const String _otherUserId = 'contract-neighbour';

Matcher throwsStatus(int status, [String? code]) => throwsA(
      predicate<Object>(
        (error) =>
            error is SyncTransportException &&
            error.statusCode == status &&
            (code == null || error.code == code),
        'a SyncTransportException with status $status'
        '${code == null ? '' : ' and code $code'}',
      ),
    );

Uint8List _seedOf(int offset) =>
    Uint8List.fromList(List<int>.generate(32, (index) => (index + offset) % 256));

void main() {
  late FakeSyncServer server;
  late FakeSyncServerUserSession userSession;
  late FakeSyncServerMemberSession session;
  late AuthorFixture author;
  late RootAuthority root;
  final workspaceId = implicitWorkspaceId(_userId);

  /// Escrow a Root so the server has something to check certificates against,
  /// then register a device and take its member credential — the same order a
  /// real ceremony runs in.
  Future<FakeSyncServerMemberSession> enrol(
    FakeSyncServerUserSession user,
    AuthorFixture device,
  ) async {
    await user.registerMember(
      memberId: device.memberId,
      signPk: device.signPk,
      kexPk: device.kexPk,
    );
    final nonce = await user.requestMemberChallenge(device.memberId);
    return await user.completeMemberChallenge(
          memberId: device.memberId,
          nonce: nonce,
          signature: await device.signChallenge(nonce),
        ) as FakeSyncServerMemberSession;
  }

  setUp(() async {
    server = FakeSyncServer();
    userSession = server.connectAsUser(_userId);
    root = await RootAuthority.fromSecretKey(_seedOf(200));
    await userSession.putRecoveryEscrow(
      workspaceId,
      await root.escrowRecord(
        workspaceId: workspaceId,
        version: firstEscrowVersion,
        blob: harnessEscrowBlob(),
      ),
    );
    author = await AuthorFixture.create(seed: _seedOf(1));
    session = await enrol(userSession, author);
  });

  group('POST /w/{w}/ops', () {
    test('assigns increasing seq and indexes the header', () async {
      final first = await author.nextEnvelope(workspaceId);
      final second = await author.nextEnvelope(workspaceId);

      final results = await session.postOps(workspaceId, [first, second]);
      expect(results.map((r) => r.duplicate), [false, false]);
      expect(results[0].seq, lessThan(results[1].seq));

      final stored = server.storedOps;
      expect(stored.map((op) => op.envelope), [first, second]);
      for (final op in stored) {
        // Index columns come from the envelope, never from the request.
        final header = OpHeader.parse(op.envelope);
        expect(op.workspaceId, header.workspaceId);
        expect(op.header!.opId, header.opId);
        expect(op.header!.opClass, header.opClass);
        expect(op.header!.keyEpoch, header.keyEpoch);
        expect(op.header!.authorMemberId, header.authorMemberId);
        expect(op.header!.authorSeq, header.authorSeq);
        expect(op.compactedBy, isNull);
      }
    });

    test('replaying the exact batch is all duplicates and appends nothing',
        () async {
      final batch = [
        await author.nextEnvelope(workspaceId),
        await author.nextEnvelope(workspaceId),
      ];
      final first = await session.postOps(workspaceId, batch);
      final replay = await session.postOps(workspaceId, batch);

      expect(replay.map((r) => r.duplicate), [true, true]);
      expect(replay.map((r) => r.seq), first.map((r) => r.seq));
      expect(server.storedOps.length, 2);
    });

    test('partially duplicate batch appends only the new ops', () async {
      final alreadySent = await author.nextEnvelope(workspaceId);
      await session.postOps(workspaceId, [alreadySent]);

      final fresh = await author.nextEnvelope(workspaceId);
      final results = await session.postOps(workspaceId, [alreadySent, fresh]);
      expect(results.map((r) => r.duplicate), [true, false]);
      expect(server.storedOps.length, 2);
    });

    test('a repeat inside one batch is a duplicate of its first appearance',
        () async {
      final envelope = await author.nextEnvelope(workspaceId);
      final results = await session.postOps(workspaceId, [envelope, envelope]);
      expect(results.map((r) => r.duplicate), [false, true]);
      expect(results[0].seq, results[1].seq);
      expect(server.storedOps.length, 1);
    });

    test('author_seq gap rejects the whole batch', () async {
      await author.nextEnvelope(workspaceId); // burn author_seq 1
      final afterTheGap = await author.nextEnvelope(workspaceId);
      expect(
        () => session.postOps(workspaceId, [afterTheGap]),
        throwsStatus(409, 'author_chain_gap'),
      );
      expect(server.storedOps, isEmpty);
    });

    test('two ops claiming the same author_seq land exactly once', () async {
      final first = await author.nextEnvelope(workspaceId, advance: false);
      final second = await author.nextEnvelope(workspaceId, advance: false);
      expect(first, isNot(second));

      await session.postOps(workspaceId, [first]);
      expect(
        () => session.postOps(workspaceId, [second]),
        throwsStatus(409, 'author_chain_gap'),
      );
      expect(server.storedOps.map((op) => op.envelope), [first]);
    });

    test('header workspace mismatch is rejected', () async {
      final foreign = await author.nextEnvelope(implicitWorkspaceId('someone-else'));
      expect(
        () => session.postOps(workspaceId, [foreign]),
        throwsStatus(422, 'workspace_mismatch'),
      );
    });

    test('unserved suite is rejected', () async {
      final envelope = await author.nextEnvelope(workspaceId, suite: 0x7F);
      expect(
        () => session.postOps(workspaceId, [envelope]),
        throwsStatus(422, 'unsupported_suite'),
      );
    });

    for (final opClass in [9, opClassCompaction]) {
      test('unserved op_class $opClass is rejected', () async {
        // Unknown (9) and known-but-unimplemented (4) fail closed identically.
        // op_class 2 is no longer among them: this slice serves control.
        final envelope = await author.nextEnvelope(workspaceId, opClass: opClass);
        expect(
          () => session.postOps(workspaceId, [envelope]),
          throwsStatus(422, 'unsupported_op_class'),
        );
      });
    }

    test('truncated envelope is rejected', () async {
      final envelope = await author.nextEnvelope(workspaceId);
      expect(
        () => session.postOps(workspaceId, [Uint8List.sublistView(envelope, 0, 100)]),
        throwsStatus(422, 'truncated_envelope'),
      );
    });

    test('envelope shorter than the minimum is rejected', () async {
      final envelope = await author.nextEnvelope(workspaceId);
      final tooShort = Uint8List.sublistView(envelope, 0, minimumEnvelopeBytes - 1);
      // Long enough to parse as a header: not the truncated-header case.
      expect(tooShort.length, greaterThan(headerLengthBytes));
      expect(
        () => session.postOps(workspaceId, [tooShort]),
        throwsStatus(422, 'envelope_too_short'),
      );
      expect(server.storedOps, isEmpty);
    });

    test('foreign author is rejected', () async {
      final stranger = await AuthorFixture.create(seed: _seedOf(90));
      final otherUser = server.connectAsUser(_otherUserId);
      await otherUser.registerMember(
        memberId: stranger.memberId,
        signPk: stranger.signPk,
        kexPk: stranger.kexPk,
      );
      final envelope = await stranger.nextEnvelope(workspaceId);
      expect(
        () => session.postOps(workspaceId, [envelope]),
        throwsStatus(403, 'author_member_mismatch'),
      );
    });

    test('unregistered author is rejected', () async {
      final stranger = await AuthorFixture.create(seed: _seedOf(70));
      final envelope = await stranger.nextEnvelope(workspaceId);
      expect(
        () => session.postOps(workspaceId, [envelope]),
        throwsStatus(403, 'author_member_mismatch'),
      );
    });

    test('a member token cannot post as another member of the same user',
        () async {
      // Both devices belong to the same User, so the old "author is a member of
      // this user" check would have waved this through (F10).
      final sibling = await AuthorFixture.create(seed: _seedOf(120));
      await userSession.registerMember(
        memberId: sibling.memberId,
        signPk: sibling.signPk,
        kexPk: sibling.kexPk,
      );
      final envelope = await sibling.nextEnvelope(workspaceId);
      expect(
        () => session.postOps(workspaceId, [envelope]),
        throwsStatus(403, 'author_member_mismatch'),
      );
      expect(server.storedOps, isEmpty);
    });

    test("another user's workspace is rejected", () async {
      final otherWorkspaceId = implicitWorkspaceId(_otherUserId);
      final envelope = await author.nextEnvelope(otherWorkspaceId);
      expect(
        () => session.postOps(otherWorkspaceId, [envelope]),
        throwsStatus(403, 'no_workspace_grant'),
      );
      expect(
        () => session.pullOps(otherWorkspaceId, since: 0, limit: 10),
        throwsStatus(403, 'no_workspace_grant'),
      );
    });

    test('empty batch is accepted and appends nothing', () async {
      expect(await session.postOps(workspaceId, const []), isEmpty);
      expect(server.storedOps, isEmpty);
    });
  });

  group('GET /w/{w}/ops', () {
    test('pages by seq and reports has_more', () async {
      final envelopes = <Uint8List>[];
      for (var index = 0; index < 5; index++) {
        envelopes.add(await author.nextEnvelope(workspaceId));
      }
      await session.postOps(workspaceId, envelopes);

      final firstPage = await session.pullOps(workspaceId, since: 0, limit: 2);
      expect(firstPage.hasMore, isTrue);
      expect(firstPage.ops.map((op) => op.envelope), envelopes.sublist(0, 2));

      final rest = await session.pullOps(
        workspaceId,
        since: firstPage.ops.last.seq,
        limit: 10,
      );
      expect(rest.hasMore, isFalse);
      expect(rest.ops.map((op) => op.envelope), envelopes.sublist(2));
    });

    test('excludes compacted rows', () async {
      final envelopes = [
        await author.nextEnvelope(workspaceId),
        await author.nextEnvelope(workspaceId),
      ];
      await session.postOps(workspaceId, envelopes);
      final stored = server.storedOps;
      server.markCompacted(stored.first.seq, by: stored.last.seq);

      final pulled = await session.pullOps(workspaceId, since: 0, limit: 10);
      expect(pulled.ops.map((op) => op.envelope), [envelopes[1]]);
    });
  });

  group('op_class=2: MemberRegister', () {
    Future<Uint8List> registerFor(
      AuthorFixture device, {
      RootAuthority? signer,
      RegistrationCertificate? certificate,
      bool corruptSignature = false,
      int? authorSeq,
      Uint8List? prevControlHash,
    }) async {
      final cert = certificate ??
          RegistrationCertificate(
            workspaceId: workspaceId,
            memberId: device.memberId,
            signPk: device.signPk,
            kexPk: device.kexPk,
            registeredAtHlc: Hlc.forMember(device.memberId, 1800000000000),
          );
      final certBytes = cert.encode();
      final signature = await (signer ?? root).signCertificateBytes(certBytes);
      if (corruptSignature) signature[signature.length - 1] ^= 0x01;
      return device.nextEnvelope(
        workspaceId,
        opClass: opClassControl,
        payload: ControlPayload(
          controlType: controlTypeMemberRegister,
          prevControlHash: prevControlHash ?? zeroPrevControlHash,
          certBytes: certBytes,
          rootSig: signature,
        ).encode(),
        authorSeq: authorSeq,
      );
    }

    test('a Root-signed member_register materialises the membership', () async {
      final envelope = await registerFor(author);
      final results = await session.postOps(workspaceId, [envelope]);
      expect(results.single.duplicate, isFalse);
      expect(server.storedOps.single.envelope, envelope);
      expect(server.storedOps.single.header!.opClass, opClassControl);
      expect(server.isChained(author.memberId), isTrue);
    });

    test('the control chain link is the predecessors payload hash', () async {
      final first = await registerFor(author);
      await session.postOps(workspaceId, [first]);

      final sibling = await AuthorFixture.create(seed: _seedOf(140));
      final siblingSession = await enrol(userSession, sibling);
      final firstPayload = parseBody(splitEnvelope(first).body);
      final chained = await registerFor(
        sibling,
        prevControlHash: controlPayloadHash(firstPayload),
      );
      final payload = ControlPayload.decode(parseBody(splitEnvelope(chained).body));
      expect(payload.prevControlHash, controlPayloadHash(firstPayload));
      expect(payload.prevControlHash, isNot(zeroPrevControlHash));

      await siblingSession.postOps(workspaceId, [chained]);
      expect(server.storedOps.length, 2);
    });

    test('a control op with a bad Root signature is rejected', () async {
      final envelope = await registerFor(author, corruptSignature: true);
      expect(
        () => session.postOps(workspaceId, [envelope]),
        throwsStatus(422, 'bad_root_signature'),
      );
      expect(server.isChained(author.memberId), isFalse);
    });

    test('a control op signed by a foreign Root is rejected', () async {
      final envelope = await registerFor(
        author,
        signer: await RootAuthority.fromSecretKey(_seedOf(77)),
      );
      expect(
        () => session.postOps(workspaceId, [envelope]),
        throwsStatus(422, 'bad_root_signature'),
      );
    });

    test('an unserved control type is rejected', () async {
      final envelope = await author.nextEnvelope(
        workspaceId,
        opClass: opClassControl,
        payload: ControlPayload(
          controlType: 'grant',
          prevControlHash: zeroPrevControlHash,
        ).encode(),
      );
      expect(
        () => session.postOps(workspaceId, [envelope]),
        throwsStatus(422, 'unsupported_control_type'),
      );
    });

    test('a malformed control payload is rejected', () async {
      final envelope = await author.nextEnvelope(
        workspaceId,
        opClass: opClassControl,
        payloadJson: 'not json at all',
      );
      expect(
        () => session.postOps(workspaceId, [envelope]),
        throwsStatus(422, 'malformed_control_payload'),
      );
    });

    for (final (code, body) in [
      ('invalid_body_length', Uint8List(300)),
      ('payload_overruns_body', _bodyClaiming(256)),
    ]) {
      test('a control body the framing refuses is rejected as $code', () async {
        final envelope = await author.nextEnvelopeWithBody(
          workspaceId,
          body,
          opClass: opClassControl,
        );
        expect(
          () => session.postOps(workspaceId, [envelope]),
          throwsStatus(422, code),
        );
      });
    }

    test('a member_register away from author_seq 1 is rejected', () async {
      // The position rule, and its precedence over the chain-gap 409.
      final envelope = await registerFor(author, authorSeq: 4);
      expect(
        () => session.postOps(workspaceId, [envelope]),
        throwsStatus(422, 'member_register_not_first'),
      );
      expect(server.storedOps, isEmpty);
    });

    test('a certificate naming another member is rejected', () async {
      final envelope = await registerFor(
        author,
        certificate: RegistrationCertificate(
          workspaceId: workspaceId,
          memberId: implicitWorkspaceId('a-different-member'),
          signPk: author.signPk,
          kexPk: author.kexPk,
          registeredAtHlc: Hlc.forMember(author.memberId, 1800000000000),
        ),
      );
      expect(
        () => session.postOps(workspaceId, [envelope]),
        throwsStatus(422, 'cert_member_mismatch'),
      );
    });

    test('a certificate naming another key is rejected', () async {
      final other = await AuthorFixture.create(seed: _seedOf(160));
      final envelope = await registerFor(
        author,
        certificate: RegistrationCertificate(
          workspaceId: workspaceId,
          memberId: author.memberId,
          signPk: other.signPk,
          kexPk: author.kexPk,
          registeredAtHlc: Hlc.forMember(author.memberId, 1800000000000),
        ),
      );
      expect(
        () => session.postOps(workspaceId, [envelope]),
        throwsStatus(422, 'cert_key_mismatch'),
      );
    });

    test('a control op without a stored Root fails closed', () async {
      // No escrow means no Root the server can check against.
      final bare = FakeSyncServer();
      final bareUser = bare.connectAsUser(_userId);
      final device = await AuthorFixture.create(seed: _seedOf(180));
      await bareUser.registerMember(
        memberId: device.memberId,
        signPk: device.signPk,
        kexPk: device.kexPk,
      );
      final nonce = await bareUser.requestMemberChallenge(device.memberId);
      final bareSession = await bareUser.completeMemberChallenge(
        memberId: device.memberId,
        nonce: nonce,
        signature: await device.signChallenge(nonce),
      );
      expect(
        () async => bareSession.postOps(workspaceId, [await registerFor(device)]),
        throwsStatus(422, 'bad_root_signature'),
      );
    });

    test('a content op body is never read', () async {
      // The same bytes that are a malformed control payload are an
      // unremarkable content op, because nothing server-side looks at them.
      final envelope = await author.nextEnvelope(
        workspaceId,
        payloadJson: 'not json at all',
      );
      final results = await session.postOps(workspaceId, [envelope]);
      expect(results.single.duplicate, isFalse);
    });
  });

  group('POST /members', () {
    test('registration derives the key id', () async {
      final device = await AuthorFixture.create(seed: _seedOf(50));
      final record = await userSession.registerMember(
        memberId: device.memberId,
        signPk: device.signPk,
        kexPk: device.kexPk,
      );
      expect(record.keyId, deriveKeyId(device.signPk));
      expect(record.signPk, device.signPk);
      expect(record.kexPk, device.kexPk);
      // A registry row on its own is an unchained shell.
      expect(record.chained, isFalse);
    });

    test('re-registering the same member is idempotent', () async {
      final again = await userSession.registerMember(
        memberId: author.memberId,
        signPk: author.signPk,
        kexPk: author.kexPk,
      );
      expect(again.memberId, author.memberId);
    });

    test('re-registering a member id under a different key conflicts', () async {
      final impostor = await AuthorFixture.create(
        memberId: author.memberId,
        seed: _seedOf(33),
      );
      expect(
        () => userSession.registerMember(
          memberId: impostor.memberId,
          signPk: impostor.signPk,
          kexPk: impostor.kexPk,
        ),
        throwsStatus(409, 'member_id_already_registered'),
      );
    });

    test("the workspace member registry lists the user's devices", () async {
      final members = await userSession.fetchMembers(workspaceId);
      expect(members.map((m) => m.memberId), [author.memberId]);
      expect(members.single.keyId, deriveKeyId(author.signPk));
    });
  });

  group('member proof of possession', () {
    test('a nonce is single use', () async {
      final device = await AuthorFixture.create(seed: _seedOf(210));
      await userSession.registerMember(
        memberId: device.memberId,
        signPk: device.signPk,
        kexPk: device.kexPk,
      );
      final nonce = await userSession.requestMemberChallenge(device.memberId);
      final signature = await device.signChallenge(nonce);
      await userSession.completeMemberChallenge(
        memberId: device.memberId,
        nonce: nonce,
        signature: signature,
      );
      expect(
        () => userSession.completeMemberChallenge(
          memberId: device.memberId,
          nonce: nonce,
          signature: signature,
        ),
        throwsStatus(401, 'bad_member_challenge'),
      );
    });

    test('a wrong key cannot answer the challenge', () async {
      final impostor = await AuthorFixture.create(
        memberId: author.memberId,
        seed: _seedOf(220),
      );
      final nonce = await userSession.requestMemberChallenge(author.memberId);
      expect(
        () async => userSession.completeMemberChallenge(
          memberId: author.memberId,
          nonce: nonce,
          signature: await impostor.signChallenge(nonce),
        ),
        throwsStatus(401, 'bad_member_challenge'),
      );
    });

    test('a signature cannot be replayed into another members slot', () async {
      // The member id is inside the signed bytes, so a signature does not
      // travel between slots.
      final attacker = await AuthorFixture.create(seed: _seedOf(230));
      await userSession.registerMember(
        memberId: attacker.memberId,
        signPk: attacker.signPk,
        kexPk: attacker.kexPk,
      );
      final nonce = await userSession.requestMemberChallenge(attacker.memberId);
      expect(
        () async => userSession.completeMemberChallenge(
          memberId: author.memberId,
          nonce: nonce,
          signature: await attacker.signChallenge(nonce),
        ),
        throwsStatus(401, 'bad_member_challenge'),
      );
    });

    test('an unknown member has no challenge', () async {
      expect(
        () => userSession.requestMemberChallenge(implicitWorkspaceId('nobody')),
        throwsStatus(404, 'unknown_member'),
      );
    });

    test('the challenge is rate limited', () async {
      // Unauthenticated on the real route, so this ceiling is the only thing
      // bounding how many nonces one member id can mint.
      final device = await AuthorFixture.create(seed: _seedOf(215));
      await userSession.registerMember(
        memberId: device.memberId,
        signPk: device.signPk,
        kexPk: device.kexPk,
      );
      for (var index = 0; index < fakeServerMemberChallengeLimit; index++) {
        expect(await userSession.requestMemberChallenge(device.memberId), hasLength(32));
      }
      expect(
        () => userSession.requestMemberChallenge(device.memberId),
        throwsStatus(429, 'member_challenge_rate_limited'),
      );
    });

    test('the challenge limit is per member', () async {
      // One exhausted Device must not lock its siblings out of enrolling.
      final exhausted = await AuthorFixture.create(seed: _seedOf(216));
      final sibling = await AuthorFixture.create(seed: _seedOf(217));
      for (final device in [exhausted, sibling]) {
        await userSession.registerMember(
          memberId: device.memberId,
          signPk: device.signPk,
          kexPk: device.kexPk,
        );
      }
      for (var index = 0; index < fakeServerMemberChallengeLimit; index++) {
        await userSession.requestMemberChallenge(exhausted.memberId);
      }
      expect(
        () => userSession.requestMemberChallenge(exhausted.memberId),
        throwsStatus(429, 'member_challenge_rate_limited'),
      );
      expect(await userSession.requestMemberChallenge(sibling.memberId), hasLength(32));
    });

    test('an unknown member does not get a counter', () async {
      // The 404 precedes the counter, so enumeration cannot exhaust anything.
      final stranger = implicitWorkspaceId('never-registered');
      for (var index = 0; index < fakeServerMemberChallengeLimit + 5; index++) {
        expect(
          () => userSession.requestMemberChallenge(stranger),
          throwsStatus(404, 'unknown_member'),
        );
      }
    });
  });

  group('credential separation', () {
    test('the ceremony hands back a member credential and not a user one', () async {
      // The twin of `test_a_member_token_is_not_a_user_session`. Over there the
      // member token reaches `GET /user` and `POST /members` and is refused with
      // a 401; here the credential has no such surface to offer at all, and this
      // is what pins that it never grows one.
      final device = await AuthorFixture.create(seed: _seedOf(260));
      final transport = await enrol(userSession, device);
      expect(transport, isA<SyncTransport>());
      expect(transport, isNot(isA<UserTransport>()));
    });

    test('the user credential has no ops surface', () async {
      // The twin of `test_a_user_credential_cannot_post_ops`: a User session
      // cannot post or pull, and the reason it cannot is not a runtime check.
      expect(userSession, isA<UserTransport>());
      expect(userSession, isNot(isA<SyncTransport>()));
    });

    test('a member session cannot reach the escrow', () async {
      // The structural half of `test_a_member_credential_can_never_reach_the_
      // escrow_blob`. The laundering paths that test walks are token-shaped and
      // have no analogue here; what does have one is the end state — the object
      // a Device is left holding has no escrow method on it.
      expect(session, isNot(isA<UserTransport>()));
    });
  });

  group('recovery escrow', () {
    late FakeSyncServer bare;
    late FakeSyncServerUserSession bareUser;
    late RootAuthority bareRoot;

    setUp(() async {
      bare = FakeSyncServer();
      bareUser = bare.connectAsUser(_userId);
      bareRoot = await RootAuthority.fromSecretKey(_seedOf(240));
    });

    Future<RecoveryEscrowRecord> record(int version, {RootAuthority? signer}) =>
        (signer ?? bareRoot).escrowRecord(
          workspaceId: workspaceId,
          version: version,
          blob: harnessEscrowBlob(),
        );

    test('the first write establishes the Root key', () async {
      final written = await bareUser.putRecoveryEscrow(workspaceId, await record(1));
      expect(written.version, 1);
      expect(written.rootPk, bareRoot.rootPk);
    });

    test('a create at any other version is a regression', () async {
      expect(
        () async => bareUser.putRecoveryEscrow(workspaceId, await record(7)),
        throwsStatus(409, 'escrow_version_regression'),
      );
    });

    test('a passphrase change bumps the version', () async {
      await bareUser.putRecoveryEscrow(workspaceId, await record(1));
      final rewrapped = await record(2);
      final written = await bareUser.putRecoveryEscrow(workspaceId, rewrapped);
      expect(written.version, 2);
      expect(written.blob, rewrapped.blob);
    });

    test('the older blob is refused after a rewrap', () async {
      final first = await record(1);
      await bareUser.putRecoveryEscrow(workspaceId, first);
      await bareUser.putRecoveryEscrow(workspaceId, await record(2));
      expect(
        () => bareUser.putRecoveryEscrow(workspaceId, first),
        throwsStatus(409, 'escrow_version_regression'),
      );
      expect(
        () async => bareUser.putRecoveryEscrow(workspaceId, await record(2)),
        throwsStatus(409, 'escrow_version_regression'),
      );
    });

    test('a stolen user credential cannot overwrite the escrow', () async {
      await bareUser.putRecoveryEscrow(workspaceId, await record(1));
      final attacker = await RootAuthority.fromSecretKey(_seedOf(250));
      expect(
        () async => bareUser.putRecoveryEscrow(
          workspaceId,
          await record(2, signer: attacker),
        ),
        throwsStatus(403, 'bad_escrow_signature'),
      );
      final stored = await bareUser.fetchRecoveryEscrow(workspaceId);
      expect(stored!.rootPk, bareRoot.rootPk);
    });

    test('a bad Root signature is refused on the first write too', () async {
      final good = await record(1);
      final corrupted = Uint8List.fromList(good.rootSig)..[63] ^= 0x01;
      expect(
        () => bareUser.putRecoveryEscrow(
          workspaceId,
          RecoveryEscrowRecord(
            version: good.version,
            blob: good.blob,
            rootSig: corrupted,
            rootPk: good.rootPk,
          ),
        ),
        throwsStatus(403, 'bad_escrow_signature'),
      );
    });

    test('a blob signed for another workspace cannot be replayed', () async {
      final foreign = await bareRoot.escrowRecord(
        workspaceId: implicitWorkspaceId('somebody-else'),
        version: 1,
        blob: harnessEscrowBlob(),
      );
      expect(
        () => bareUser.putRecoveryEscrow(workspaceId, foreign),
        throwsStatus(403, 'bad_escrow_signature'),
      );
    });

    test('a signature for another version does not transfer', () async {
      final signedForV1 = await record(1);
      expect(
        () => bareUser.putRecoveryEscrow(
          workspaceId,
          RecoveryEscrowRecord(
            version: 2,
            blob: signedForV1.blob,
            rootSig: signedForV1.rootSig,
            rootPk: signedForV1.rootPk,
          ),
        ),
        throwsStatus(403, 'bad_escrow_signature'),
      );
    });

    test("another user's escrow slot is unreachable", () async {
      final neighbour = bare.connectAsUser(_otherUserId);
      expect(
        () async => neighbour.putRecoveryEscrow(workspaceId, await record(1)),
        throwsStatus(403, 'no_workspace_grant'),
      );
      expect(
        () => neighbour.fetchRecoveryEscrow(workspaceId),
        throwsStatus(403, 'no_workspace_grant'),
      );
    });

    test('the fetch returns the record verbatim and is audited', () async {
      final written = await record(1);
      await bareUser.putRecoveryEscrow(workspaceId, written);

      final fetched = await bareUser.fetchRecoveryEscrow(workspaceId);
      expect(fetched!.version, written.version);
      expect(fetched.blob, written.blob);
      expect(fetched.rootSig, written.rootSig);
      expect(fetched.rootPk, written.rootPk);
      expect(bare.escrowFetches.map((entry) => entry.userId), [_userId]);
    });

    test('fetching an empty slot returns nothing', () async {
      expect(await bareUser.fetchRecoveryEscrow(workspaceId), isNull);
    });

    test('the fetch is rate limited', () async {
      await bareUser.putRecoveryEscrow(workspaceId, await record(1));
      for (var index = 0; index < fakeServerRecoveryFetchLimit; index++) {
        expect(await bareUser.fetchRecoveryEscrow(workspaceId), isNotNull);
      }
      expect(
        () => bareUser.fetchRecoveryEscrow(workspaceId),
        throwsStatus(429, 'escrow_fetch_rate_limited'),
      );
      // The refused attempt is not audited: no bytes left the server.
      expect(bare.escrowFetches.length, fakeServerRecoveryFetchLimit);
    });
  });
}

/// A body of the smallest legal size whose length prefix claims [claimed]
/// bytes of payload — more than the body can hold.
Uint8List _bodyClaiming(int claimed) {
  final body = Uint8List(256);
  ByteData.view(body.buffer).setUint32(0, claimed, Endian.big);
  return body;
}
