/// End-to-end: a misbehaving server is a surfaced integrity event.
///
/// This file is the acceptance criteria of #551. Every fault is injected on the
/// **serving** side of `FakeSyncServer` — drop, reorder, rewind, replay — because
/// those are the faults per-author chains exist to catch, and because the client
/// path has to stay production-real for an alarm it raises to be evidence of
/// anything. Nothing here reaches into `SyncClient` to provoke a verdict.
///
/// The point of each case is not that *an* alarm fired but that the *right* one
/// did, and that the other end states did not: drop, reorder and fork have to end
/// somewhere distinguishable, or "surfaced" means nothing more than "logged".
@TestOn('!browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/chain_verifier.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_transport.dart';
import 'package:sqlite3/common.dart' show SqliteException;
import 'package:uuid/uuid.dart';

import 'harness/author_fixture.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';

const String _harnessCollection = 'harness_docs';
const Uuid _uuid = Uuid();

extension _Alarms on SimDevice {
  /// The device's alarms by kind. Every case here involves one author, so kind
  /// alone identifies an accusation.
  Future<Map<String, IntegrityAlarmRow>> alarmsByKind() async => {
        for (final alarm in await client.integrityAlarms()) alarm.kind: alarm,
      };

  /// The default Workspace's log rows. Scoped, because a device holds two
  /// Workspaces now — the GTD one and the User-global preferences one — over the
  /// same store, and every sync table is keyed by workspace id.
  Future<List<OpLogRow>> loggedOps() => (database.select(database.opLog)
        ..where((row) => row.workspaceId.equals(client.workspaceId))
        ..orderBy([(row) => OrderingTerm(expression: row.seq)]))
      .get();

  /// Author one content op into the device's **default** Workspace.
  ///
  /// These cases are about one Workspace's chain, and preferences now live in the
  /// User-global preferences Workspace — so authoring through `preferences` would
  /// put the op in a different log from the one under test.
  Future<void> authorLocal(SimWorkspace workspace, Object? value) async {
    workspace.clock.advance(10);
    await client.capture(
      collection: _harnessCollection,
      entityId: _docId(workspace),
      fields: {'step': value},
    );
  }

  Future<int> cursor() async {
    final row = await (database.select(database.syncCursors)
          ..where((row) => row.workspaceId.equals(client.workspaceId)))
        .getSingleOrNull();
    return row?.lastSeq ?? 0;
  }
}

/// One content op from [author], carrying `{field: value}` on a shared entity.
Future<Uint8List> _op(
  SimWorkspace workspace,
  AuthorFixture author,
  Object? value, {
  String field = 'step',
  String? opId,
  bool advance = true,
}) async {
  workspace.clock.advance(10);
  return author.nextEnvelope(
    workspace.workspaceId,
    opId: opId,
    advance: advance,
    payloadJson: jsonEncode({
      'collection': _harnessCollection,
      'id': _docId(workspace),
      'fields': {
        field: {'v': value},
      },
      'hlc': [workspace.clock.nowMs, 0, memberIdToHex(author.memberId)],
    }),
  );
}

String _docId(SimWorkspace workspace) =>
    preferenceEntityId(workspace.workspaceId, 'chain-integrity-doc');

Future<Map<String, Object?>?> _doc(SimDevice device, SimWorkspace workspace) =>
    device.registry.register(_harnessCollection).readEntity(_docId(workspace));

void main() {
  /// The peer's first *content* op sits at this position in its own chain.
  ///
  /// `enrolFixture` spends author_seq 1 on the `member_register` and 2 on the
  /// explicit owner Grant: roles are one materialisation path, so there are no
  /// implied grants and a Member's authority costs a chain slot like anything else.
  const int firstPeerContentAuthorSeq = 3;

  late SimWorkspace workspace;
  late SimDevice a;
  late AuthorFixture peer;
  late SyncTransport peerSession;

  setUp(() async {
    workspace = await SimWorkspace.create();
    a = workspace.a;
    peer = await AuthorFixture.create(
      seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 91)),
    );
    peerSession = await workspace.enrolFixture(peer);
    // The register has to land before any of the peer's content, or every case
    // below would stop at the key lookup instead of reaching the chain rules.
    await a.sync();
  });

  tearDown(() => workspace.close());

  // --- AC 1: each fault produces a distinct surfaced alarm --------------------

  test('a dropped op leaves a standing gap that further syncs do not heal',
      () async {
    final first = await _op(workspace, peer, 'one');
    final withheld = await _op(workspace, peer, 'two');
    final third = await _op(workspace, peer, 'three');
    final appended = await peerSession.postOps(
      workspace.workspaceId,
      [first, withheld, third],
    );
    workspace.server.omitSeqs.add(appended[1].seq);

    await a.sync();

    final alarms = await a.alarmsByKind();
    expect(alarms.keys, {IntegrityAlarmKind.authorChainGap.code});
    expect(alarms[IntegrityAlarmKind.authorChainGap.code]!.resolvedAt, isNull);
    // The successor is held, not dropped: refused ops are evidence.
    final refused = await a.client.quarantined();
    expect(refused.single.reason, SyncRejectionReason.authorChainGap.code);
    expect(refused.single.authorSeq, firstPeerContentAuthorSeq + 2);
    expect(refused.single.releasedAt, isNull);
    // Only the op before the gap applied.
    expect(await _doc(a, workspace), {'step': 'one'});

    // Withholding is detectable, not preventable: syncing again cannot conjure
    // the missing op, so the accusation stands.
    await a.sync();
    await a.sync();
    final after = await a.alarmsByKind();
    expect(after[IntegrityAlarmKind.authorChainGap.code]!.resolvedAt, isNull);
    expect(after.containsKey(IntegrityAlarmKind.authorStreamReordered.code), isFalse);
    expect(
      (await a.client.health()).clean,
      isFalse,
      reason: 'a standing accusation is never clean',
    );
  });

  test('a reordered pair heals and reclassifies as a reorder', () async {
    final first = await _op(workspace, peer, 'one');
    final second = await _op(workspace, peer, 'two');
    final appended =
        await peerSession.postOps(workspace.workspaceId, [first, second]);
    workspace.server.serveOrder = [appended[1].seq, appended[0].seq];

    await a.sync();

    // Converged on what an honest order would have produced: a hostile reorder
    // must not cost data that actually arrived.
    expect(await _doc(a, workspace), {'step': 'two'});
    final alarms = await a.alarmsByKind();
    expect(
      alarms[IntegrityAlarmKind.authorChainGap.code]!.resolvedAt,
      isNotNull,
      reason: 'nothing is missing any more',
    );
    expect(
      alarms[IntegrityAlarmKind.authorStreamReordered.code]!.resolvedAt,
      isNull,
      reason: 'the server still reordered, and that stands',
    );
    final released = await a.client.quarantined();
    expect(released.single.authorSeq, firstPeerContentAuthorSeq + 1);
    expect(released.single.releasedAt, isNotNull);
    // Nothing still stands refused, so the refusal count is back to zero even
    // though the row is kept for inspection.
    expect(await a.client.quarantined(includeReleased: false), isEmpty);
    expect((await a.client.health()).quarantineCount, 0);
  });

  test('a partial heal leaves the gap standing beside the reorder', () async {
    // Served 5, 3, 2 with 4 withheld: op 3 releases when 2 lands, and 5 cannot.
    // The reorder is real and so is the drop, so both are recorded and only the
    // reorder is a heal.
    final ops = <Uint8List>[
      for (final value in ['one', 'two', 'three', 'four'])
        await _op(workspace, peer, value),
    ];
    final appended = await peerSession.postOps(workspace.workspaceId, ops);
    workspace.server.omitSeqs.add(appended[2].seq);
    workspace.server.serveOrder = [
      appended[3].seq,
      appended[1].seq,
      appended[0].seq,
    ];

    await a.sync();

    final alarms = await a.alarmsByKind();
    expect(
      alarms[IntegrityAlarmKind.authorChainGap.code]!.resolvedAt,
      isNull,
      reason: 'an unreleased gap row still stands',
    );
    expect(alarms[IntegrityAlarmKind.authorStreamReordered.code], isNotNull);
    expect(await _doc(a, workspace), {'step': 'two'});
    final standing = await a.client.quarantined(includeReleased: false);
    expect(standing.single.authorSeq, firstPeerContentAuthorSeq + 3);
  });

  test('an incompatible predecessor is a fork, not a heal', () async {
    // The head is at 2, and two different ops claim position 3: the one the
    // withheld successor was chained to, and the one that actually arrives.
    final second = await _op(workspace, peer, 'two');
    await peerSession.postOps(workspace.workspaceId, [second]);
    await a.sync();
    expect(await _doc(a, workspace), {'step': 'two'});

    final headHash = envelopeHash(second);
    await _op(workspace, peer, 'the predecessor that never arrives');
    final successor = await _op(workspace, peer, 'successor');
    workspace.server.injectUnchecked(workspace.workspaceId, successor);
    await a.sync();
    expect(
      (await a.alarmsByKind()).keys,
      {IntegrityAlarmKind.authorChainGap.code},
    );

    // A validly signed alternate at position 3, chained to the real head — so
    // the successor's `prev_author_hash` names something that is provably not
    // what occupies its predecessor's slot.
    peer.nextAuthorSeq = firstPeerContentAuthorSeq + 1;
    peer.lastEnvelopeHash = headHash;
    final alternate = await _op(workspace, peer, 'alternate');
    workspace.server.injectUnchecked(workspace.workspaceId, alternate);

    await a.sync();

    final alarms = await a.alarmsByKind();
    expect(alarms[IntegrityAlarmKind.authorChainFork.code], isNotNull);
    expect(
      alarms.containsKey(IntegrityAlarmKind.authorStreamReordered.code),
      isFalse,
      reason: 'a fork is not a heal',
    );
    expect(
      alarms[IntegrityAlarmKind.authorChainGap.code]!.resolvedAt,
      isNull,
      reason: 'the successor is still refused',
    );
    // The predecessor that arrived applied; the successor chained to the other
    // one stays out.
    expect(await _doc(a, workspace), {'step': 'alternate'});
    final standing = await a.client.quarantined(includeReleased: false);
    expect(standing.single.authorSeq, firstPeerContentAuthorSeq + 2);
  });

  test('a prev-hash mismatch at head + 1 is its own accusation', () async {
    // Right position, forged linkage, and a signature that verifies: the only
    // thing wrong is the chain field itself.
    peer.lastEnvelopeHash =
        Uint8List.fromList(List<int>.filled(prevAuthorHashBytes, 0x7f));
    final forged = await _op(workspace, peer, 'forged linkage');
    workspace.server.injectUnchecked(workspace.workspaceId, forged);

    await a.sync();

    expect(
      (await a.alarmsByKind()).keys,
      {IntegrityAlarmKind.prevAuthorHashMismatch.code},
    );
    expect(
      (await a.client.quarantined()).single.reason,
      SyncRejectionReason.prevAuthorHashMismatch.code,
    );
    expect(await _doc(a, workspace), isNull);
  });

  // --- AC 2: a divergent duplicate op id is an integrity event ---------------

  test('the same op id with different bytes is a divergent duplicate', () async {
    final opId = _uuid.v4();
    final original = await _op(workspace, peer, 'original', opId: opId);
    await peerSession.postOps(workspace.workspaceId, [original]);
    await a.sync();

    // Same op id, next position, different bytes — the shape that makes dedupe
    // by op id dangerous if it happens before the comparison (review F13).
    final impostor = await _op(workspace, peer, 'substituted', opId: opId);
    workspace.server.injectUnchecked(workspace.workspaceId, impostor);

    await a.sync();

    expect(
      (await a.alarmsByKind()).keys,
      {IntegrityAlarmKind.duplicateOpIdDivergence.code},
    );
    expect(
      (await a.client.quarantined()).single.reason,
      SyncRejectionReason.duplicateOpIdDivergence.code,
    );
    expect(await _doc(a, workspace), {'step': 'original'});
  });

  // --- Stale prefixes and cursor monotonicity --------------------------------

  group('a stale prefix', () {
    test('is an alarm even when the bytes are ones we already hold', () async {
      await peerSession.postOps(
        workspace.workspaceId,
        [await _op(workspace, peer, 'one')],
      );
      await a.sync();
      final cursorBefore = await a.cursor();
      final logBefore = [for (final row in await a.loggedOps()) row.envelope];

      // `since` is a pure client parameter, so ignoring it is something no
      // honest server can do — whatever the bytes turn out to be.
      workspace.server.ignoreSinceParameter = true;
      await a.sync();

      expect(
        (await a.alarmsByKind()).keys,
        {IntegrityAlarmKind.stalePrefixServed.code},
      );
      // Identical bytes, so there is nothing further to accuse and nothing to
      // refuse; the log and the cursor are untouched.
      expect(await a.client.quarantined(), isEmpty);
      expect(await a.cursor(), cursorBefore);
      expect([for (final row in await a.loggedOps()) row.envelope], logBefore);
    });

    test('terminates the pull when a page makes no forward progress', () async {
      // The regression guard for the infinite loop: a server ignoring `since`
      // over a log longer than one page reports `has_more` forever, so the pull
      // has to end on the absence of progress rather than on the flag.
      final small = await SimWorkspace.create(pullPageLimit: 2);
      addTearDown(small.close);
      final author = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 7)),
      );
      final session = await small.enrolFixture(author);
      await small.a.sync();
      await session.postOps(small.workspaceId, [
        for (final value in ['one', 'two', 'three'])
          await _op(small, author, value),
      ]);
      await small.a.sync();
      final cursorBefore = await small.a.cursor();

      small.server.ignoreSinceParameter = true;
      await small.a.sync().timeout(const Duration(seconds: 10));

      expect(await small.a.cursor(), cursorBefore);
      expect(
        (await small.a.alarmsByKind()).keys,
        contains(IntegrityAlarmKind.stalePrefixServed.code),
      );
    });

    test('carries the rewrite accusation when the bytes differ', () async {
      final first = await _op(workspace, peer, 'one');
      final second = await _op(workspace, peer, 'two');
      final appended =
          await peerSession.postOps(workspace.workspaceId, [first, second]);
      await a.sync();
      final cursorBefore = await a.cursor();

      // History the device has already verified stops existing, and the freed
      // transport position is handed out again to different bytes.
      workspace.server.rollbackToSeq(appended.first.seq - 1);
      peer.nextAuthorSeq = firstPeerContentAuthorSeq;
      peer.lastEnvelopeHash = envelopeHash(
        (await a.loggedOps())
            .firstWhere((row) =>
                row.authorMemberId == peer.memberId && row.authorSeq == 1)
            .envelope,
      );
      await peerSession.postOps(
        workspace.workspaceId,
        [await _op(workspace, peer, 'substituted')],
      );
      // A rolled-back server has nothing above the client's cursor to offer, so
      // the reused position only reaches the device when it also stops honouring
      // `since` — which is the same server misbehaving in the same direction.
      workspace.server.ignoreSinceParameter = true;

      await a.sync();

      final alarms = await a.alarmsByKind();
      expect(alarms[IntegrityAlarmKind.stalePrefixServed.code], isNotNull);
      expect(alarms[IntegrityAlarmKind.authorChainRewrite.code], isNotNull);
      expect(
        (await a.client.quarantined()).single.reason,
        SyncRejectionReason.authorChainRewrite.code,
      );
      expect(await a.cursor(), cursorBefore, reason: 'the cursor never regresses');
      expect(await _doc(a, workspace), {'step': 'two'});
    });

    test('bumps its accusation once per served op', () async {
      // One page, one op, so the count is unambiguous: the page limit stops the
      // pull after the crafted position, which `serveOrder` puts first.
      final small = await SimWorkspace.create(pullPageLimit: 1);
      addTearDown(small.close);
      final author = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 23)),
      );
      final session = await small.enrolFixture(author);
      await small.a.sync();
      final first = await _op(small, author, 'one');
      final second = await _op(small, author, 'two');
      final appended =
          await session.postOps(small.workspaceId, [first, second]);
      await small.a.sync();
      final cursorBefore = await small.a.cursor();

      // The two ops swap transport positions, so the bytes served below the
      // cursor are bytes the device holds — at a different seq. Nothing further
      // is accusable about them, and the serving is one accusation about one op.
      small.server.rollbackToSeq(appended.first.seq - 1);
      small.server.injectUnchecked(small.workspaceId, second);
      small.server.injectUnchecked(small.workspaceId, first);
      small.server.ignoreSinceParameter = true;
      small.server.serveOrder = [appended.first.seq];

      await small.a.sync();

      final alarms = await small.a.alarmsByKind();
      expect(alarms.keys, {IntegrityAlarmKind.stalePrefixServed.code});
      expect(alarms[IntegrityAlarmKind.stalePrefixServed.code]!.occurrenceCount, 1);
      expect(await small.a.cursor(), cursorBefore);
    });
  });

  // --- The log is evidence: appends never overwrite ---------------------------

  group('the received log', () {
    test('refuses a second op served under a seq it has already spent',
        () async {
      final first = await _op(workspace, peer, 'one');
      final second = await _op(workspace, peer, 'two');
      final appended = await peerSession.postOps(workspace.workspaceId, [first]);
      final spentSeq = appended.single.seq;

      // Both envelopes are chain-valid, so nothing before the append has any
      // reason to refuse the second — the transport position is the only thing
      // they contend for, and the log must keep the op it already holds there.
      workspace.server.injectUnchecked(
        workspace.workspaceId,
        second,
        atSeq: spentSeq,
      );

      await a.sync();

      expect(
        (await a.alarmsByKind()).keys,
        {IntegrityAlarmKind.authorChainSlotCollision.code},
      );
      final logged = await a.loggedOps();
      expect(
        [for (final row in logged) if (row.seq == spentSeq) row.envelope],
        [first],
        reason: 'the op already at that seq survives byte for byte',
      );
      expect(
        [
          for (final row in logged)
            if (row.authorMemberId == peer.memberId) row.authorSeq,
        ],
        isNot(contains(OpHeader.parse(splitEnvelope(second).header).authorSeq)),
        reason: 'the second claim on the slot is skipped, not logged',
      );
      expect(await _doc(a, workspace), {'step': 'one'});
    });

    test('aborts the pull on a database failure that is not a taken slot',
        () async {
      await peerSession.postOps(
        workspace.workspaceId,
        [await _op(workspace, peer, 'one')],
      );
      final cursorBefore = await a.cursor();
      // A failure the append cannot read as "this slot is taken" is not the
      // receive pipeline's to swallow: the op is still owed to the log, so the
      // pull stops with the cursor short of it and the next sync retries.
      await a.database.customStatement(
        'CREATE TRIGGER op_log_append_fails BEFORE INSERT ON op_log '
        "BEGIN SELECT RAISE(ABORT, 'op_log is unwritable'); END",
      );

      await expectLater(a.sync(), throwsA(isA<SqliteException>()));

      expect(await a.cursor(), cursorBefore,
          reason: 'the cursor never moves past an op that was not logged');
      expect(await a.alarmsByKind(), isEmpty,
          reason: 'a database failure is not an accusation against the server');

      await a.database.customStatement('DROP TRIGGER op_log_append_fails');
      await a.sync();

      expect(await _doc(a, workspace), {'step': 'one'});
      expect(await a.alarmsByKind(), isEmpty);
      expect(await a.cursor(), greaterThan(cursorBefore));
    });
  });

  // --- Own writes ------------------------------------------------------------

  group('own writes', () {
    test('a rollback below our acknowledged head wedges the outbox, visibly',
        () async {
      await a.authorLocal(workspace, 'one');
      await a.authorLocal(workspace, 'two');
      await a.sync();
      final acknowledged = await a.client.authoredEnvelopes();

      // The server forgets our last op. Whether it rolled back or this device
      // came off an older backup is not decidable here, and the response is the
      // same either way.
      final ownSeqs = [
        for (final row in await a.loggedOps())
          if (row.authorMemberId == a.identity.memberId) row.seq,
      ]..sort();
      workspace.server.rollbackToSeq(ownSeqs.last - 1);
      await a.authorLocal(workspace, 'three');

      final health = await a.sync();

      final alarms = await a.alarmsByKind();
      final rollback = alarms[IntegrityAlarmKind.ownWritesRollback.code]!;
      expect(rollback.resolvedAt, isNull);
      expect(rollback.detail, contains('restored from an older'));
      expect(rollback.authorMemberId, a.identity.memberId);
      // Nothing re-numbered, nothing dropped: re-authoring under a lower
      // position would forge this device's own chain.
      expect(await a.client.authoredEnvelopes(), containsAll(acknowledged));
      final unsent = await (a.database.select(a.database.outbox)
            ..where((row) => row.sentAt.isNull()))
          .get();
      expect(unsent.single.authorSeq, acknowledged.length + 1);
      // The wedge is surfaced, never silent — and the pull ran regardless.
      expect(health.pendingOpCount, 1);
      expect(health.clean, isFalse);
      expect(health.lastSyncedAt, isNotNull);
    });

    test('a server ahead of everything we authored still pulls', () async {
      // The other side of the verdict: the server holds a position under our key
      // that we never wrote. Same fail-closed answer, different detail — and the
      // transport log is intact, so a peer's ops in the same cycle still apply.
      final ahead = await a.identity.signer.buildEnvelope(
        OpHeader(
          workspaceId: workspace.workspaceId,
          opClass: opClassContent,
          opId: _uuid.v4(),
          authorMemberId: a.identity.memberId,
          authorKeyId: a.identity.keyId,
          authorSeq: 9,
        ),
        frameBody(Uint8List.fromList(utf8.encode('{"collection":"test"}'))),
      );
      workspace.server.injectUnchecked(workspace.workspaceId, ahead);
      await a.sync();

      await a.authorLocal(workspace, 'mine');
      await peerSession.postOps(
        workspace.workspaceId,
        [await _op(workspace, peer, 'from the peer')],
      );

      final health = await a.sync();

      final rollback =
          (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesRollback.code]!;
      expect(rollback.detail, contains('authoring under'));
      expect(health.pendingOpCount, 1);
      expect(health.clean, isFalse);
      // A wedged outbox must never wedge the pull.
      expect(await _doc(a, workspace), {'step': 'from the peer'});
    });

    test('a substituted copy of our own op is a divergence, and ours stands',
        () async {
      await a.authorLocal(workspace, 'mine');
      await a.sync();
      final authored = await a.client.authoredEnvelopes();
      final nextAuthorSeq = authored.length + 1;

      // A different envelope at a position this device has authored but not yet
      // pulled back. The chain rules alone cannot catch it — only the retained
      // outbox can, which is what it is retained for.
      await a.authorLocal(workspace, 'local');
      final substitute = await a.identity.signer.buildEnvelope(
        OpHeader(
          workspaceId: workspace.workspaceId,
          opClass: opClassContent,
          opId: _uuid.v4(),
          authorMemberId: a.identity.memberId,
          authorKeyId: a.identity.keyId,
          authorSeq: nextAuthorSeq,
          prevAuthorHash: envelopeHash(authored.last),
        ),
        frameBody(Uint8List.fromList(utf8.encode(jsonEncode({
          'collection': _harnessCollection,
          'id': _docId(workspace),
          'fields': {
            'step': {'v': 'not what we wrote'},
          },
          'hlc': [workspace.clock.nowMs, 0, a.identity.memberIdHex],
        })))),
      );
      workspace.server.injectUnchecked(workspace.workspaceId, substitute);

      // Pull without flushing: the substitute has to be judged against the
      // outbox, which is exactly the state a flush would resolve away.
      await a.client.pull();

      expect(
        (await a.alarmsByKind()).keys,
        {IntegrityAlarmKind.ownWritesDivergence.code},
      );
      expect(
        (await a.client.quarantined()).single.reason,
        SyncRejectionReason.ownWritesDivergence.code,
      );
      // The local copy stands: what this device authored is what it reads, and
      // the substitute's payload never applied.
      expect(await _doc(a, workspace), {'step': 'local'});
    });

    test('a tampered copy of our own op fails on the signature first', () async {
      // Pins the receive order: the signature is checked before anything is
      // compared, so tampering never even reaches the own-writes check.
      await a.authorLocal(workspace, 'mine');
      await a.sync();
      final authored = await a.client.authoredEnvelopes();
      final tampered = Uint8List.fromList(authored.last);
      tampered[headerLengthBytes + 8] ^= 0x01;
      workspace.server.injectUnchecked(workspace.workspaceId, tampered);

      await a.sync();

      expect(
        (await a.alarmsByKind()).keys,
        {IntegrityAlarmKind.signatureInvalid.code},
        reason: 'signature failure is an alarm, never a skipped row',
      );
      expect(
        (await a.client.quarantined()).single.reason,
        SyncRejectionReason.badSignature.code,
      );
    });
  });

  // --- AC 3: refusals are inspectable and survive restart -------------------

  test('quarantine rows and alarms survive a restart', () async {
    final device = await SimDevice.create(
      label: 'R',
      userId: workspace.userId,
      server: workspace.server,
      clock: workspace.clock,
      passphrase: workspace.passphrase,
      fileBacked: true,
    );
    addTearDown(device.close);
    await device.sync();

    peer.lastEnvelopeHash =
        Uint8List.fromList(List<int>.filled(prevAuthorHashBytes, 0x5a));
    workspace.server.injectUnchecked(
      workspace.workspaceId,
      await _op(workspace, peer, 'forged linkage'),
    );
    await device.sync();
    expect(await device.client.quarantined(), isNotEmpty);

    final reopened = await device.reopenSyncStore();

    final refused = await reopened.quarantined();
    expect(refused.single.reason, SyncRejectionReason.prevAuthorHashMismatch.code);
    expect(refused.single.envelope, isNotEmpty);
    final alarms = await reopened.integrityAlarms();
    expect(
      alarms.single.kind,
      IntegrityAlarmKind.prevAuthorHashMismatch.code,
    );
    // The stream re-emits over the reopened store, so a relaunched app surfaces
    // what the previous run refused rather than starting clean.
    expect((await reopened.watchIntegrityAlarms().first).single.kind,
        IntegrityAlarmKind.prevAuthorHashMismatch.code);
    expect((await reopened.health()).unresolvedAlarmCount, 1);
  });

  // --- Regression guards ----------------------------------------------------

  test('a reducer-guard refusal is logged, and does not false-gap the next op',
      () async {
    // Without logging the refused envelope, the author's honest next op would
    // read as a chain gap — a fail-closed rule turning into a fault of its own.
    final future = workspace.clock.nowMs + 3600000;
    final refusedEnvelope = await peer.nextEnvelope(
      workspace.workspaceId,
      payloadJson: jsonEncode({
        'collection': _harnessCollection,
        'id': _docId(workspace),
        'fields': {
          'step': {'v': 'from the future'},
        },
        'hlc': [future, 0, memberIdToHex(peer.memberId)],
      }),
    );
    final honest = await _op(workspace, peer, 'honest');
    await peerSession.postOps(workspace.workspaceId, [refusedEnvelope, honest]);

    await a.sync();

    // The honest successor applied: no gap was manufactured.
    expect(await _doc(a, workspace), {'step': 'honest'});
    expect(await a.alarmsByKind(), isEmpty);
    expect(
      (await a.client.quarantined()).single.reason,
      SyncRejectionReason.hlcInTheFuture.code,
    );

    final logged = await a.loggedOps();
    final refusedRow =
        logged.firstWhere((row) => row.authorSeq == firstPeerContentAuthorSeq);
    expect(refusedRow.refusedReason, SyncRejectionReason.hlcInTheFuture.code);
    expect(refusedRow.appliedAt, isNull, reason: 'logged as evidence, never applied');
    final appliedRow =
        logged.firstWhere((row) => row.authorSeq == firstPeerContentAuthorSeq + 1);
    expect(appliedRow.appliedAt, isNotNull);
    expect(appliedRow.refusedReason, isNull);

    // The refused timestamp did not drag the local clock with it: a guard that
    // poisons the clock it just defended is no guard at all.
    expect(a.hlc.send().wallMs, lessThan(future));
  });

  test('honest multi-device convergence is untouched by the verifier', () async {
    await peerSession.postOps(
      workspace.workspaceId,
      [await _op(workspace, peer, 'from the peer')],
    );
    await a.preferences.set('theme', '"dark"');
    await workspace.syncAll();

    for (final device in workspace.devices) {
      expect(await device.client.quarantined(), isEmpty, reason: device.label);
      expect(await device.alarmsByKind(), isEmpty, reason: device.label);
      expect((await device.client.health()).clean, isTrue, reason: device.label);
      for (final row in await device.loggedOps()) {
        expect(row.appliedAt, isNotNull, reason: '${device.label} seq ${row.seq}');
        expect(row.refusedReason, isNull);
      }
    }
    expect(await _doc(workspace.b, workspace), {'step': 'from the peer'});
    expect(await workspace.b.preferences.get('theme'), '"dark"');
  });
}
