/// The server contract, asserted against the in-process fake.
///
/// This file is the twin of `backend/tests/sync/test_ops_routes.py`,
/// `test_recovery_escrow_routes.py`, `test_member_auth_routes.py` and, for the
/// signal socket, `test_signal_socket.py`: the same cases under the same names.
/// The harness's convergence tests are only evidence about the real system if
/// the double they run against behaves like the real server, and a missing or
/// failing twin here is how a divergence announces itself.
///
/// Every assertion is on the structured `detail.code`, never on a message —
/// the codes are the contract and the prose is not.
///
/// The signal socket's untwinned cases are the ones the fake cannot express: it
/// has no token model (so no bad-token 4401, no user-token 4401 and no
/// missing-auth-frame 4400) and no wall clock of its own on this path (so the
/// keepalive cadence is asserted backend side). Those four, and the binding
/// no-payload assertion, live in the backend file.
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
/// `credential separation` group below (and, for that second case's members-route
/// half, in `GET /w/{w}/members`) — but as assertions about the type split
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
import 'package:jeeves/sync/signal_socket.dart';
import 'package:jeeves/sync/sync_transport.dart';

import 'harness/author_fixture.dart';
import 'harness/fake_sync_server.dart';
import 'harness/signal_probe.dart';
import 'harness/sim_workspace.dart'
    show grantEnvelope, simulationStartWallMs, workspaceGenesisEnvelope;

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

/// The founding ceremony spends the founding device's first two chain slots — one
/// on the genesis, one on its explicit owner Grant — so its first *content* op
/// sits here. Roles are one materialisation path, so nothing is implied.
const int firstContentAuthorSeq = 3;

/// Only the content rows, in seq order.
///
/// Every founded Workspace's log opens with the two control ops of its founding
/// ceremony, so a test about content appends filters them out rather than
/// counting them.
List<StoredOp> contentOps(FakeSyncServer server) => [
      for (final op in server.storedOps)
        if (op.header?.opClass == opClassContent) op,
    ];

void main() {
  late FakeSyncServer server;
  late FakeSyncServerUserSession userSession;
  late FakeSyncServerMemberSession session;
  late AuthorFixture author;
  late RootAuthority root;
  final workspaceId = defaultWorkspaceId(_userId);

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

  /// The founding ceremony: genesis, then a root-signed owner self-grant.
  ///
  /// Two ops in one batch and in that order, exactly as `EnrolmentService` posts
  /// them. Genesis embeds the founder's registration, so there is no separate
  /// `member_register` for the founding device — and without the Grant a content
  /// POST would be refused before reaching anything else under test.
  Future<void> found(
    FakeSyncServerMemberSession memberSession,
    AuthorFixture device, {
    String? workspace,
  }) async {
    final target = workspace ?? workspaceId;
    final genesis = await workspaceGenesisEnvelope(
      device: device,
      workspaceId: target,
      root: root,
      wallMs: simulationStartWallMs,
    );
    final grant = await grantEnvelope(
      device: device,
      workspaceId: target,
      root: root,
      prevControlHash: controlPayloadHash(parseBody(splitEnvelope(genesis).body)),
      memberId: device.memberId,
      wallMs: simulationStartWallMs,
    );
    await memberSession.postOps(target, [genesis, grant]);
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
    await found(session, author);
  });

  group('POST /w/{w}/ops', () {
    test('assigns increasing seq and indexes the header', () async {
      final first = await author.nextEnvelope(workspaceId);
      final second = await author.nextEnvelope(workspaceId);

      final results = await session.postOps(workspaceId, [first, second]);
      expect(results.map((r) => r.duplicate), [false, false]);
      expect(results[0].seq, lessThan(results[1].seq));

      final stored = contentOps(server);
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
      expect(contentOps(server).length, 2);
    });

    test('partially duplicate batch appends only the new ops', () async {
      final alreadySent = await author.nextEnvelope(workspaceId);
      await session.postOps(workspaceId, [alreadySent]);

      final fresh = await author.nextEnvelope(workspaceId);
      final results = await session.postOps(workspaceId, [alreadySent, fresh]);
      expect(results.map((r) => r.duplicate), [true, false]);
      expect(contentOps(server).length, 2);
    });

    test('a repeat inside one batch is a duplicate of its first appearance',
        () async {
      final envelope = await author.nextEnvelope(workspaceId);
      final results = await session.postOps(workspaceId, [envelope, envelope]);
      expect(results.map((r) => r.duplicate), [false, true]);
      expect(results[0].seq, results[1].seq);
      expect(contentOps(server).length, 1);
    });

    test('author_seq gap rejects the whole batch with the structured conflict',
        () async {
      await author.nextEnvelope(workspaceId); // burn one chain slot
      final afterTheGap = await author.nextEnvelope(workspaceId);
      await expectLater(
        () => session.postOps(workspaceId, [afterTheGap]),
        throwsA(
          isA<AuthorChainConflictException>()
              .having((error) => error.statusCode, 'statusCode', 409)
              .having((error) => error.code, 'code', authorChainConflictCode)
              .having((error) => error.opIndex, 'opIndex', 0)
              .having((error) => error.submittedAuthorSeq, 'submittedAuthorSeq', firstContentAuthorSeq + 1)
              .having((error) => error.expectedAuthorSeq, 'expectedAuthorSeq', firstContentAuthorSeq),
        ),
      );
      expect(contentOps(server), isEmpty);
    });

    test('two ops claiming the same author_seq land exactly once', () async {
      final first = await author.nextEnvelope(workspaceId, advance: false);
      final second = await author.nextEnvelope(workspaceId, advance: false);
      expect(first, isNot(second));

      await session.postOps(workspaceId, [first]);
      expect(
        () => session.postOps(workspaceId, [second]),
        throwsStatus(409, authorChainConflictCode),
      );
      expect(contentOps(server).map((op) => op.envelope), [first]);
    });

    test('header workspace mismatch is rejected', () async {
      final foreign = await author.nextEnvelope(defaultWorkspaceId('someone-else'));
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
      expect(contentOps(server), isEmpty);
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
      expect(contentOps(server), isEmpty);
    });

    test("another user's workspace is rejected", () async {
      final otherWorkspaceId = defaultWorkspaceId(_otherUserId);
      final envelope = await author.nextEnvelope(otherWorkspaceId);
      expect(
        () => session.postOps(otherWorkspaceId, [envelope]),
        throwsStatus(403, 'workspace_not_derivable'),
      );
      expect(
        () => session.pullOps(otherWorkspaceId, since: 0, limit: 10),
        throwsStatus(403, 'workspace_not_derivable'),
      );
    });

    test('empty batch is accepted and appends nothing', () async {
      expect(await session.postOps(workspaceId, const []), isEmpty);
      expect(contentOps(server), isEmpty);
    });
  });

  group('GET /w/{w}/ops', () {
    test('pages by seq and reports has_more', () async {
      final envelopes = <Uint8List>[];
      for (var index = 0; index < 5; index++) {
        envelopes.add(await author.nextEnvelope(workspaceId));
      }
      await session.postOps(workspaceId, envelopes);

      // Past the founding ceremony's control ops: paging is what is under test,
      // and the genesis and self-grant are not part of the page arithmetic.
      final foundedThrough = contentOps(server).first.seq - 1;
      final firstPage =
          await session.pullOps(workspaceId, since: foundedThrough, limit: 2);
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
      final stored = contentOps(server);
      server.markCompacted(stored.first.seq, by: stored.last.seq);

      final pulled = await session.pullOps(
        workspaceId,
        since: stored.first.seq - 1,
        limit: 10,
      );
      expect(pulled.ops.map((op) => op.envelope), [envelopes[1]]);
    });
  });

  group('WS /w/{w}/signal', () {
    test('subscribe acks with an immediate poke', () async {
      final pokes = PokeRecorder(session.newSeqSignals(workspaceId));
      await pumpEvents();

      expect(pokes.pokeCount, 1);
      expect(pokes.errors, isEmpty);
      await pokes.cancel();
    });

    test('subscribe to another workspace is refused with 4403', () async {
      final pokes = PokeRecorder(session.newSeqSignals(defaultWorkspaceId(_otherUserId)));
      await pumpEvents();

      expect(pokes.pokeCount, 0);
      expect(
        pokes.errors.single,
        isA<SyncTransportException>()
            .having((e) => e.statusCode, 'statusCode', signalCloseForbidden)
            // The structured code, not the prose: a close frame carries no body,
            // so the client branches on the code — and the fake keeps it beside
            // the close code rather than regressing to a bare string.
            .having((e) => e.code, 'code', 'workspace_not_derivable'),
      );
      await pokes.cancel();
    });

    test('an append pokes the subscriber', () async {
      final pokes = PokeRecorder(session.newSeqSignals(workspaceId));
      await pumpEvents();

      await session.postOps(workspaceId, [await author.nextEnvelope(workspaceId)]);
      await pumpEvents();

      expect(pokes.pokeCount, 2);
      await pokes.cancel();
    });

    test('a duplicate-only replay does not poke', () async {
      final envelope = await author.nextEnvelope(workspaceId);
      await session.postOps(workspaceId, [envelope]);

      final pokes = PokeRecorder(session.newSeqSignals(workspaceId));
      await pumpEvents();

      final replay = await session.postOps(workspaceId, [envelope]);
      await pumpEvents();

      expect(replay.single.duplicate, isTrue);
      // Nothing was appended, so there is no news — a replay is not activity.
      expect(pokes.pokeCount, 1);
      await pokes.cancel();
    });

    test('an append never pokes another workspace', () async {
      // The neighbour has to *enrol*, not merely authenticate: the socket takes
      // a member credential, so a user session cannot subscribe at all.
      final neighbourUser = server.connectAsUser(_otherUserId);
      final neighbourDevice = await AuthorFixture.create(seed: _seedOf(270));
      final neighbour = await enrol(neighbourUser, neighbourDevice);
      final neighbourWorkspaceId = defaultWorkspaceId(_otherUserId);
      final pokes = PokeRecorder(neighbour.newSeqSignals(neighbourWorkspaceId));
      await pumpEvents();

      await session.postOps(workspaceId, [await author.nextEnvelope(workspaceId)]);
      await pumpEvents();

      expect(pokes.pokeCount, 1, reason: 'only its own subscribe ack');
      await pokes.cancel();
    });

    test('the wire carries only empty pokes', () async {
      final pokes = PokeRecorder(session.newSeqSignals(workspaceId));
      await pumpEvents();
      await session.postOps(workspaceId, [await author.nextEnvelope(workspaceId)]);
      await pumpEvents();

      // A fidelity smoke check on the fake. The binding assertion — that a real
      // socket sends nothing but empty pokes and the keepalive literal — is
      // `backend/tests/sync/test_signal_socket.py`, which watches real frames.
      expect(server.emittedSignalFrames[workspaceId], ['', '']);
      await pokes.cancel();
    });
  });

  group('op_class=2: MemberRegister', () {
    /// The chain link the next control op must name, computed the way a pulling
    /// client computes it: SHA-256 over the last control op's payload bytes.
    Uint8List controlHead() {
      for (final op in server.storedOps.reversed) {
        if (op.workspaceId != workspaceId) continue;
        if (op.header?.opClass != opClassControl) continue;
        return controlPayloadHash(parseBody(splitEnvelope(op.envelope).body));
      }
      return zeroPrevControlHash;
    }

    /// A second Device with keys and a credential, holding **no Grant**.
    ///
    /// Every *bad* `member_register` case runs through a sibling rather than
    /// through the founder, whose registration the genesis already embedded — the
    /// founder has no separate register to get wrong.
    Future<(AuthorFixture, FakeSyncServerMemberSession)> joinSibling(int seed) async {
      final sibling = await AuthorFixture.create(seed: _seedOf(seed));
      return (sibling, await enrol(userSession, sibling));
    }

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
          // The observed head by default: an all-zero link is genesis-only
          // (ADR-0031), so a register that carried one would be refused as a
          // truncated-history claim before anything else was examined.
          prevControlHash: prevControlHash ?? controlHead(),
          certBytes: certBytes,
          signature: signature,
        ).encode(),
        authorSeq: authorSeq,
      );
    }

    test('a Root-signed member_register materialises the membership', () async {
      final (sibling, siblingSession) = await joinSibling(141);
      final envelope = await registerFor(sibling);
      final results = await siblingSession.postOps(workspaceId, [envelope]);
      expect(results.single.duplicate, isFalse);
      expect(server.storedOps.last.envelope, envelope);
      expect(server.storedOps.last.header!.opClass, opClassControl);
      expect(server.isChained(sibling.memberId), isTrue);
    });

    test('a member_register with a zero chain link is rejected', () async {
      // An all-zero prev_control_hash is **genesis-only** (ADR-0031). Refused
      // even by a receiver whose control state is empty, which is what makes a
      // truncated history always detectable.
      final (sibling, siblingSession) = await joinSibling(142);
      final envelope =
          await registerFor(sibling, prevControlHash: zeroPrevControlHash);
      expect(
        () => siblingSession.postOps(workspaceId, [envelope]),
        throwsStatus(422, 'control_chain_break'),
      );
      expect(server.isChained(sibling.memberId), isFalse);
    });

    test('the control chain link is the predecessors payload hash', () async {
      final before = server.storedOps.length;
      final (first, firstSession) = await joinSibling(140);
      final firstRegister = await registerFor(first);
      await firstSession.postOps(workspaceId, [firstRegister]);

      final (second, secondSession) = await joinSibling(150);
      final firstPayload = parseBody(splitEnvelope(firstRegister).body);
      final chained = await registerFor(
        second,
        prevControlHash: controlPayloadHash(firstPayload),
      );
      final payload = ControlPayload.decode(parseBody(splitEnvelope(chained).body));
      expect(payload.prevControlHash, controlPayloadHash(firstPayload));
      expect(payload.prevControlHash, isNot(zeroPrevControlHash));

      await secondSession.postOps(workspaceId, [chained]);
      expect(server.storedOps.length, before + 2);
    });

    test('a control op with a bad Root signature is rejected', () async {
      final (sibling, siblingSession) = await joinSibling(143);
      final envelope = await registerFor(sibling, corruptSignature: true);
      expect(
        () => siblingSession.postOps(workspaceId, [envelope]),
        throwsStatus(422, 'bad_root_signature'),
      );
      expect(server.isChained(sibling.memberId), isFalse);
    });

    test('a control op signed by a foreign Root is rejected', () async {
      final (sibling, siblingSession) = await joinSibling(144);
      final envelope = await registerFor(
        sibling,
        signer: await RootAuthority.fromSecretKey(_seedOf(77)),
      );
      expect(
        () => siblingSession.postOps(workspaceId, [envelope]),
        throwsStatus(422, 'bad_root_signature'),
      );
    });

    test('an unserved control type is rejected', () async {
      // #554's landing slot: every control type this build does not serve is
      // closed. `grant` is served now, so `rotate` carries the case.
      final envelope = await author.nextEnvelope(
        workspaceId,
        opClass: opClassControl,
        payload: ControlPayload(
          controlType: 'rotate',
          prevControlHash: controlHead(),
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
      final (sibling, siblingSession) = await joinSibling(145);
      final before = server.storedOps.length;
      final envelope = await registerFor(sibling, authorSeq: 4);
      expect(
        () => siblingSession.postOps(workspaceId, [envelope]),
        throwsStatus(422, 'member_register_not_first'),
      );
      expect(server.storedOps.length, before);
    });

    test('a certificate naming another member is rejected', () async {
      final (sibling, siblingSession) = await joinSibling(146);
      final envelope = await registerFor(
        sibling,
        certificate: RegistrationCertificate(
          workspaceId: workspaceId,
          memberId: defaultWorkspaceId('a-different-member'),
          signPk: sibling.signPk,
          kexPk: sibling.kexPk,
          registeredAtHlc: Hlc.forMember(sibling.memberId, 1800000000000),
        ),
      );
      expect(
        () => siblingSession.postOps(workspaceId, [envelope]),
        throwsStatus(422, 'cert_member_mismatch'),
      );
    });

    test('a certificate naming another key is rejected', () async {
      final (sibling, siblingSession) = await joinSibling(147);
      final other = await AuthorFixture.create(seed: _seedOf(160));
      final envelope = await registerFor(
        sibling,
        certificate: RegistrationCertificate(
          workspaceId: workspaceId,
          memberId: sibling.memberId,
          signPk: other.signPk,
          kexPk: sibling.kexPk,
          registeredAtHlc: Hlc.forMember(sibling.memberId, 1800000000000),
        ),
      );
      expect(
        () => siblingSession.postOps(workspaceId, [envelope]),
        throwsStatus(422, 'cert_key_mismatch'),
      );
    });

    test('a control op without a stored Root fails closed', () async {
      // No escrow means no Root the server can check against. Exercised through
      // *genesis*, because that is the first control op a Workspace ever sees and
      // therefore the first place the missing slot bites — which is also why the
      // ceremony's escrow PUT is strictly sequenced before its genesis post.
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
        () async => bareSession.postOps(workspaceId, [
          await workspaceGenesisEnvelope(
            device: device,
            workspaceId: workspaceId,
            root: root,
            wallMs: simulationStartWallMs,
          ),
        ]),
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

  });

  group('GET /w/{w}/members', () {
    test("the workspace member registry lists the user's devices", () async {
      // Read through the *member* session, because that is the credential the
      // route requires: it authenticates with `get_current_member` and derives
      // the owner from the token's Member. Nothing in the client calls this —
      // the directory is hydrated from the log, never over HTTP — so the double
      // models the endpoint and this twin is what pins its credential.
      final members = await session.fetchMembers(workspaceId);
      expect(members.map((m) => m.memberId), [author.memberId]);
      expect(members.single.keyId, deriveKeyId(author.signPk));
    });

    test("another user's registry is unreachable", () async {
      expect(
        () => session.fetchMembers(defaultWorkspaceId(_otherUserId)),
        throwsStatus(403, 'workspace_not_derivable'),
      );
    });

    test('the user credential cannot read the registry', () async {
      // The twin of the members-route half of
      // `test_a_user_credential_cannot_post_ops`. Over there a user token gets a
      // 401; here the User session simply has no such method, and asserting the
      // member session is not a [UserTransport] is what stops a later
      // "simplification" from handing one object both reads.
      expect(session, isNot(isA<UserTransport>()));
      expect(userSession, isNot(isA<SyncTransport>()));
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
        () => userSession.requestMemberChallenge(defaultWorkspaceId('nobody')),
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
      final stranger = defaultWorkspaceId('never-registered');
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
        workspaceId: defaultWorkspaceId('somebody-else'),
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
        throwsStatus(403, 'workspace_not_derivable'),
      );
      expect(
        () => neighbour.fetchRecoveryEscrow(workspaceId),
        throwsStatus(403, 'workspace_not_derivable'),
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
