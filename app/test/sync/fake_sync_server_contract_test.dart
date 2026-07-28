/// The op-log transport contract, asserted against the in-process fake.
///
/// This file is the twin of `backend/tests/sync/test_ops_routes.py`: same cases
/// under the same names, in the same order. The harness's convergence tests are
/// only evidence about the real system if the double they run against behaves
/// like the real server, and a missing or failing twin here is how a divergence
/// announces itself.
///
/// Three backend cases have no twin. Two are wire-format rather than
/// behaviour: `POST /members` accepts an optional `key_id` claim that the
/// server must re-derive and either accept or reject, and [SyncTransport] has
/// no way to send that claim (a client has no reason to) — the derivation
/// itself is covered below. The third is `test_ops_require_authentication`:
/// the fake has no unauthenticated state to be in, because a session *is* the
/// credential here, so there is nothing to assert a 401 against.
///
/// The author-chain race in `test_ops_author_chain_race_postgres.py` is not a
/// missing twin: it is a statement about a database under concurrency, and the
/// fake is a single-threaded list.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/sync_transport.dart';

import 'harness/author_fixture.dart';
import 'harness/fake_sync_server.dart';

const String _userId = 'contract-user';
const String _otherUserId = 'contract-neighbour';

Matcher throwsStatus(int status) => throwsA(
      predicate<Object>(
        (error) => error is SyncTransportException && error.statusCode == status,
        'a SyncTransportException with status $status',
      ),
    );

void main() {
  late FakeSyncServer server;
  late FakeSyncServerSession session;
  late AuthorFixture author;
  final workspaceId = implicitWorkspaceId(_userId);

  setUp(() async {
    server = FakeSyncServer();
    session = server.connectAs(_userId);
    author = await AuthorFixture.create(
      seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 1)),
    );
    await session.registerMember(memberId: author.memberId, signPk: author.signPk);
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
        throwsStatus(409),
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
        throwsStatus(409),
      );
      expect(server.storedOps.map((op) => op.envelope), [first]);
    });

    test('header workspace mismatch is rejected', () async {
      final foreign = await author.nextEnvelope(implicitWorkspaceId('someone-else'));
      expect(() => session.postOps(workspaceId, [foreign]), throwsStatus(422));
    });

    test('unserved suite is rejected', () async {
      final envelope = await author.nextEnvelope(workspaceId, suite: 0x7F);
      expect(() => session.postOps(workspaceId, [envelope]), throwsStatus(422));
    });

    for (final opClass in [9, opClassCompaction]) {
      test('unserved op_class $opClass is rejected', () async {
        // Unknown (9) and known-but-unimplemented (4) fail closed identically.
        final envelope = await author.nextEnvelope(workspaceId, opClass: opClass);
        expect(() => session.postOps(workspaceId, [envelope]), throwsStatus(422));
      });
    }

    test('truncated envelope is rejected', () async {
      final envelope = await author.nextEnvelope(workspaceId);
      expect(
        () => session.postOps(workspaceId, [Uint8List.sublistView(envelope, 0, 100)]),
        throwsStatus(422),
      );
    });

    test('envelope shorter than the minimum is rejected', () async {
      final envelope = await author.nextEnvelope(workspaceId);
      final tooShort = Uint8List.sublistView(envelope, 0, minimumEnvelopeBytes - 1);
      // Long enough to parse as a header: not the truncated-header case.
      expect(tooShort.length, greaterThan(headerLengthBytes));
      expect(() => session.postOps(workspaceId, [tooShort]), throwsStatus(422));
      expect(server.storedOps, isEmpty);
    });

    test('foreign author is rejected', () async {
      final stranger = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 90)),
      );
      await server
          .connectAs(_otherUserId)
          .registerMember(memberId: stranger.memberId, signPk: stranger.signPk);
      final envelope = await stranger.nextEnvelope(workspaceId);
      expect(() => session.postOps(workspaceId, [envelope]), throwsStatus(403));
    });

    test('unregistered author is rejected', () async {
      final stranger = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 70)),
      );
      final envelope = await stranger.nextEnvelope(workspaceId);
      expect(() => session.postOps(workspaceId, [envelope]), throwsStatus(403));
    });

    test("another user's workspace is rejected", () async {
      final otherWorkspaceId = implicitWorkspaceId(_otherUserId);
      final envelope = await author.nextEnvelope(otherWorkspaceId);
      expect(
        () => session.postOps(otherWorkspaceId, [envelope]),
        throwsStatus(403),
      );
      expect(
        () => session.pullOps(otherWorkspaceId, since: 0, limit: 10),
        throwsStatus(403),
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

  group('POST /members', () {
    test('registration derives the key id', () async {
      final device = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 50)),
      );
      final record = await session.registerMember(
        memberId: device.memberId,
        signPk: device.signPk,
      );
      expect(record.keyId, deriveKeyId(device.signPk));
      expect(record.signPk, device.signPk);
    });

    test('re-registering the same member is idempotent', () async {
      final again = await session.registerMember(
        memberId: author.memberId,
        signPk: author.signPk,
      );
      expect(again.memberId, author.memberId);
    });

    test('re-registering a member id under a different key conflicts', () async {
      final impostor = await AuthorFixture.create(
        memberId: author.memberId,
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 33)),
      );
      expect(
        () => session.registerMember(
          memberId: impostor.memberId,
          signPk: impostor.signPk,
        ),
        throwsStatus(409),
      );
    });

    test("the workspace member registry lists the user's devices", () async {
      final members = await session.fetchMembers(workspaceId);
      expect(members.map((m) => m.memberId), [author.memberId]);
      expect(members.single.keyId, deriveKeyId(author.signPk));
    });
  });
}
