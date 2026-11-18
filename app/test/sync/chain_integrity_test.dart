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

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart'
    show OrderingTerm, QueryExecutor, QueryInterceptor, Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/sync_status_provider.dart';
import 'package:jeeves/sync/alarm_resolution.dart';
import 'package:jeeves/sync/chain_verifier.dart';
import 'package:jeeves/sync/enrolment_state.dart';
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

/// This device's own envelope at [authorSeq] — the bytes it signed.
Future<Uint8List> _outboxEnvelope(SimDevice device, int authorSeq) async {
  final row = await (device.database.select(device.database.outbox)
        ..where((r) => r.authorSeq.equals(authorSeq)))
      .getSingle();
  return row.envelope;
}

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

  test('a forged alternate quarantined first does not block the genuine successor',
      () async {
    // Two envelopes claim author_seq 5, and the forgery is quarantined *first*,
    // so it holds the lower row id at that position. Arrival order is the one
    // thing the server controls completely, so it must not decide which claimant
    // the release scan re-admits — only the head's envelope hash can.
    final first = await _op(workspace, peer, 'one');
    await peerSession.postOps(workspace.workspaceId, [first]);
    await a.sync();
    expect(await _doc(a, workspace), {'step': 'one'});

    // The genuine continuation of the chain, both halves held back.
    final genuineSecond = await _op(workspace, peer, 'two');
    final genuineThird = await _op(workspace, peer, 'three');

    // A validly signed alternate at the same position as `genuineThird`, chained
    // to a predecessor that will never exist.
    peer.nextAuthorSeq = firstPeerContentAuthorSeq + 2;
    peer.lastEnvelopeHash =
        Uint8List.fromList(List<int>.filled(prevAuthorHashBytes, 0x7f));
    final forgedThird = await _op(workspace, peer, 'forged');

    workspace.server.injectUnchecked(workspace.workspaceId, forgedThird);
    await a.sync();
    workspace.server.injectUnchecked(workspace.workspaceId, genuineThird);
    await a.sync();
    // Both claimants are gap rows at author_seq 5, the forgery with the lower id.
    final claimants = await a.client.quarantined(includeReleased: false);
    expect(claimants.length, 2);
    expect(
      claimants.map((row) => row.authorSeq),
      everyElement(firstPeerContentAuthorSeq + 2),
    );
    expect(sameBytes(claimants.first.envelope, forgedThird), isTrue);

    // The predecessor lands, the head moves to 4, and the scan has a choice.
    workspace.server.injectUnchecked(workspace.workspaceId, genuineSecond);
    await a.sync();

    // Released to fixpoint: the genuine successor applied over its predecessor.
    expect(await _doc(a, workspace), {'step': 'three'});

    // The forgery is identified by its bytes, never by an alarm's row id: the
    // fork alarm upserts by `(workspace, kind, author)` and keeps the first
    // `quarantine_op_row_id` it was raised with, so it counts occurrences rather
    // than enumerating claimants.
    final rows = await a.client.quarantined();
    final forgedRow = rows.singleWhere(
      (row) => sameBytes(row.envelope, forgedThird),
    );
    final genuineRow = rows.singleWhere(
      (row) => sameBytes(row.envelope, genuineThird),
    );
    expect(genuineRow.releasedAt, isNotNull);
    expect(forgedRow.releasedAt, isNull);
    expect(forgedRow.reason, SyncRejectionReason.authorChainGap.code);

    final alarms = await a.alarmsByKind();
    expect(
      alarms[IntegrityAlarmKind.authorChainFork.code]!.resolvedAt,
      isNull,
      reason: 'the claimant that does not chain stands accused',
    );
    expect(
      alarms[IntegrityAlarmKind.authorStreamReordered.code],
      isNotNull,
      reason: 'a successor did become chain-valid when its predecessor arrived',
    );
    expect(
      alarms[IntegrityAlarmKind.authorChainGap.code]!.resolvedAt,
      isNull,
      reason: 'the forged claimant still stands refused as an unreleased gap row',
    );
    expect(
      await a.client.quarantined(includeReleased: false),
      [forgedRow],
      reason: 'only the forgery is still refused',
    );
    final health = await a.client.health();
    expect(health.clean, isFalse);
    expect(health.quarantineCount, 1);
  });

  test('a second claimant that also chains to the head is a fork, not a silent drop',
      () async {
    // The symmetric case of the test above: both claimants at author_seq 5 chain
    // to the same predecessor, so both verify. A gap row exists only after
    // `verifyEnvelope` passed, so both carry the peer's own signature — the peer
    // forked its own chain (a device restored from an older backup re-authoring a
    // position it already spent does exactly this). Only one can be released, and
    // the other must not leave quarantine silently: the release scan never looks
    // at this position again once the head moves past it.
    final first = await _op(workspace, peer, 'one');
    await peerSession.postOps(workspace.workspaceId, [first]);
    await a.sync();

    // Held back, so both claimants at seq 5 quarantine as gap rows first.
    final genuineSecond = await _op(workspace, peer, 'two');
    // `advance: false` leaves the fixture at seq 5 with `hash('two')` as its
    // prev-hash, so both of these chain to the same predecessor at the same
    // position and differ only in their bytes.
    final thirdClaimant = await _op(workspace, peer, 'three', advance: false);
    final rivalThirdClaimant =
        await _op(workspace, peer, 'three as well', advance: false);

    workspace.server.injectUnchecked(workspace.workspaceId, thirdClaimant);
    await a.sync();
    workspace.server.injectUnchecked(workspace.workspaceId, rivalThirdClaimant);
    await a.sync();
    final claimants = await a.client.quarantined(includeReleased: false);
    expect(claimants.length, 2);
    expect(
      claimants.map((row) => row.authorSeq),
      everyElement(firstPeerContentAuthorSeq + 2),
    );

    // The predecessor lands, the head moves to 4, and both claimants verify.
    workspace.server.injectUnchecked(workspace.workspaceId, genuineSecond);
    await a.sync();

    // The lowest row id wins deterministically; its rival stays refused.
    expect(await _doc(a, workspace), {'step': 'three'});
    final rows = await a.client.quarantined();
    final releasedRow =
        rows.singleWhere((row) => sameBytes(row.envelope, thirdClaimant));
    final refusedRow =
        rows.singleWhere((row) => sameBytes(row.envelope, rivalThirdClaimant));
    expect(releasedRow.releasedAt, isNotNull);
    expect(refusedRow.releasedAt, isNull);
    expect(refusedRow.reason, SyncRejectionReason.authorChainGap.code);

    final alarms = await a.alarmsByKind();
    final fork = alarms[IntegrityAlarmKind.authorChainFork.code];
    expect(
      fork,
      isNotNull,
      reason: 'the claimant that was not released stands accused',
    );
    expect(fork!.resolvedAt, isNull, reason: 'the accusation still stands');
    expect(
      fork.quarantineOpRowId,
      refusedRow.id,
      reason: 'the accusation names the claimant it could not release',
    );
    expect(
      alarms[IntegrityAlarmKind.authorStreamReordered.code],
      isNotNull,
      reason: 'a successor did become chain-valid when its predecessor arrived',
    );
    expect(
      alarms[IntegrityAlarmKind.authorChainGap.code]!.resolvedAt,
      isNull,
      reason: 'the rival claimant still stands refused as an unreleased gap row',
    );
    final health = await a.client.health();
    expect(health.clean, isFalse);
    expect(health.quarantineCount, 1);
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

  // --- Resolutions: the user answers an alarm -------------------------------

  group('resolutions', () {
    /// The device's own op, tampered with, refused by the fail-closed rule.
    ///
    /// The signature covers `header || body`, so the receive path refuses it
    /// outright — an accusation raised against a forgery, and the refusal it is
    /// filed under. The bytes are returned so a test can say they are still the
    /// bytes.
    Future<
        ({
          IntegrityAlarmRow alarm,
          QuarantineRow row,
          Uint8List tampered,
          List<Uint8List> authored,
        })> plantTamperedEnvelope() async {
      await a.authorLocal(workspace, 'mine');
      await a.sync();
      final authored = await a.client.authoredEnvelopes();
      final tampered = Uint8List.fromList(authored.last);
      tampered[headerLengthBytes + 8] ^= 0x01;
      workspace.server.injectUnchecked(workspace.workspaceId, tampered);
      await a.sync();
      final alarm =
          (await a.alarmsByKind())[IntegrityAlarmKind.signatureInvalid.code]!;
      final row = (await a.client.quarantined()).single;
      return (alarm: alarm, row: row, tampered: tampered, authored: authored);
    }

    test('rejecting a refused change for good settles the alarm and keeps the bytes',
        () async {
      final planted = await plantTamperedEnvelope();
      expect(planted.alarm.resolution, isNull);
      expect(planted.alarm.resolvedAt, isNull);

      await a.client.resolveAlarm(
        planted.alarm.id,
        AlarmResolution.rejectedPermanently,
      );

      final settled =
          (await a.alarmsByKind())[IntegrityAlarmKind.signatureInvalid.code]!;
      expect(settled.resolution, AlarmResolution.rejectedPermanently.code);
      expect(settled.resolutionDecidedAt, isNotNull);
      expect(settled.resolvedAt, isNotNull);

      // Nothing is deleted, and the bytes are the evidence they always were.
      final rows = await a.client.quarantined();
      expect(rows.length, 1);
      expect(rows.single.id, planted.row.id);
      expect(sameBytes(rows.single.envelope, planted.tampered), isTrue);
      expect(rows.single.releasedAt, isNull);
      // The decision is recorded on the refused change too: that row is the
      // durable history, and the alarm only says what the answer is now.
      expect(rows.single.resolution, AlarmResolution.rejectedPermanently.code);
      expect(rows.single.resolutionDecidedAt, isNotNull);

      final health = await a.client.health();
      expect(health.clean, isTrue);
      expect(health.hasSomethingToReport, isFalse);
      expect(health.actionableAlarmCount, 0);
      expect(health.unresolvedAlarmCount, 0);
      expect(health.reportableQuarantineCount, 0);
    });

    test('a re-serve of the same bytes raises nothing again', () async {
      final planted = await plantTamperedEnvelope();
      await a.client.resolveAlarm(
        planted.alarm.id,
        AlarmResolution.rejectedPermanently,
      );

      await a.client.resetCursorForReplay();
      await a.sync();

      final after =
          (await a.alarmsByKind())[IntegrityAlarmKind.signatureInvalid.code]!;
      expect(after.resolvedAt, isNotNull);
      expect(after.resolution, AlarmResolution.rejectedPermanently.code);
      expect(
        (await a.client.quarantined()).length,
        1,
        reason: 'the same bytes are still one refusal, not two',
      );
    });

    test('a second, different forgery stands the accusation again', () async {
      final planted = await plantTamperedEnvelope();
      await a.client.resolveAlarm(
        planted.alarm.id,
        AlarmResolution.rejectedPermanently,
      );

      // A different forgery of the same op: a new accusation, not the old one.
      final second = Uint8List.fromList(planted.authored.last);
      second[headerLengthBytes + 8] ^= 0x02;
      workspace.server.injectUnchecked(workspace.workspaceId, second);
      await a.sync();

      final after =
          (await a.alarmsByKind())[IntegrityAlarmKind.signatureInvalid.code]!;
      expect(after.resolvedAt, isNull);
      expect(after.resolution, isNull);
      expect(after.resolutionDecidedAt, isNull);

      // The settled refusal stays settled; the new one is a new question.
      final rows = await a.client.quarantined();
      expect(rows.length, 2);
      expect(
        rows
            .where((row) =>
                row.resolution == AlarmResolution.rejectedPermanently.code)
            .length,
        1,
      );
      expect(rows.where((row) => row.resolution == null).length, 1);
    });

    test('rejecting a fork for good settles it and the gap it held open',
        () async {
      // The forged-claimant scenario: two envelopes claim the peer's position
      // 5, the forgery is quarantined first, and the genuine continuation is
      // released when its predecessor lands. The forgery is what is left.
      final first = await _op(workspace, peer, 'one');
      await peerSession.postOps(workspace.workspaceId, [first]);
      await a.sync();

      final genuineSecond = await _op(workspace, peer, 'two');
      final genuineThird = await _op(workspace, peer, 'three');

      peer.nextAuthorSeq = firstPeerContentAuthorSeq + 2;
      peer.lastEnvelopeHash =
          Uint8List.fromList(List<int>.filled(prevAuthorHashBytes, 0x7f));
      final forgedThird = await _op(workspace, peer, 'forged');

      workspace.server.injectUnchecked(workspace.workspaceId, forgedThird);
      await a.sync();
      workspace.server.injectUnchecked(workspace.workspaceId, genuineThird);
      await a.sync();
      workspace.server.injectUnchecked(workspace.workspaceId, genuineSecond);
      await a.sync();

      final forgedRow = (await a.client.quarantined())
          .singleWhere((row) => sameBytes(row.envelope, forgedThird));
      final fork =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainFork.code]!;
      expect(fork.resolvedAt, isNull);
      expect(
        (await a.client.health()).degraded,
        isTrue,
        reason: 'the gap the forgery holds open is actionable',
      );

      await a.client.resolveAlarm(fork.id, AlarmResolution.rejectedPermanently);

      final alarms = await a.alarmsByKind();
      final settledFork = alarms[IntegrityAlarmKind.authorChainFork.code]!;
      expect(settledFork.resolution, AlarmResolution.rejectedPermanently.code);
      expect(settledFork.resolvedAt, isNotNull);
      // The gap alarm stood because the forged row was still waiting; with the
      // row answered there is nothing left to wait for.
      final settledGap = alarms[IntegrityAlarmKind.authorChainGap.code]!;
      expect(settledGap.resolution, AlarmResolution.rejectedPermanently.code);
      expect(settledGap.resolvedAt, isNotNull);

      // The forgery is still there, still refused, and now answered.
      final rows = await a.client.quarantined();
      final settled = rows.singleWhere((row) => sameBytes(row.envelope, forgedThird));
      expect(settled.id, forgedRow.id);
      expect(settled.releasedAt, isNull);
      expect(settled.resolution, AlarmResolution.rejectedPermanently.code);
      expect(
        (await a.client.health()).degraded,
        isFalse,
        reason: 'nothing actionable is left standing',
      );
    });

    test('keeping ours on a divergence settles the other copy', () async {
      await a.authorLocal(workspace, 'mine');
      await a.sync();
      final authored = await a.client.authoredEnvelopes();
      final nextAuthorSeq = authored.length + 1;

      // A different envelope at a position this device has authored but not yet
      // pulled back — the copy that lost, and the one our answer is about.
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
      await a.client.pull();

      final divergence =
          (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesDivergence.code]!;
      final row = (await a.client.quarantined()).single;
      expect(row.reason, SyncRejectionReason.ownWritesDivergence.code);

      await a.client.resolveAlarm(divergence.id, AlarmResolution.keptOurs);

      final settled =
          (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesDivergence.code]!;
      expect(settled.resolution, AlarmResolution.keptOurs.code);
      expect(settled.resolutionDecidedAt, isNotNull);
      expect(settled.resolvedAt, isNotNull);
      expect(
        (await a.client.quarantined()).single.resolution,
        AlarmResolution.keptOurs.code,
      );
      // Ours is what stands, and it stood all along.
      expect(await _doc(a, workspace), {'step': 'local'});
    });

    test('a refusal with no alarm of its own is answered on the row',
        () async {
      final future = workspace.clock.nowMs + 3600000;
      final refused = await peer.nextEnvelope(
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
      await peerSession.postOps(workspace.workspaceId, [refused, honest]);

      await a.sync();

      final row = (await a.client.quarantined()).single;
      expect(row.reason, SyncRejectionReason.hlcInTheFuture.code);
      expect(row.resolution, isNull);
      expect((await a.client.health()).reportableQuarantineCount, 1);

      await a.client.resolveRefusedItem(
        row.id,
        AlarmResolution.rejectedPermanently,
      );

      final settled = (await a.client.quarantined()).single;
      expect(settled.resolution, AlarmResolution.rejectedPermanently.code);
      expect(settled.resolutionDecidedAt, isNotNull);
      expect(sameBytes(settled.envelope, refused), isTrue);
      expect(settled.releasedAt, isNull);
      expect((await a.client.health()).reportableQuarantineCount, 0);
      // A refusal that escalates to an alarm is answered on the alarm, not here.
      await expectLater(
        a.client.resolveRefusedItem(row.id, AlarmResolution.keptOurs),
        throwsA(isA<StateError>()),
      );
    });

    test('a resolution the kind does not offer is refused outright', () async {
      final planted = await plantTamperedEnvelope();

      await expectLater(
        a.client.resolveAlarm(planted.alarm.id, AlarmResolution.keptOurs),
        throwsA(isA<StateError>()),
      );

      // Nothing was written.
      final alarm =
          (await a.alarmsByKind())[IntegrityAlarmKind.signatureInvalid.code]!;
      expect(alarm.resolution, isNull);
      expect(alarm.resolutionDecidedAt, isNull);
      expect(alarm.resolvedAt, isNull);
      expect((await a.client.quarantined()).single.resolution, isNull);
    });

    test("another Workspace's alarm is not this client's to answer", () async {
      final planted = await plantTamperedEnvelope();
      final preferences = await a.preferencesClient;

      await expectLater(
        preferences.resolveAlarm(
          planted.alarm.id,
          AlarmResolution.rejectedPermanently,
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        (await a.alarmsByKind())[IntegrityAlarmKind.signatureInvalid.code]!
            .resolution,
        isNull,
      );
    });

    // --- Taking upstream: the User breaks the fail-closed rule on purpose ---

    /// The withheld-change recipe: the peer's second content op never arrives,
    /// so its third lands beyond the verified head and is held.
    ///
    /// Returns the transport seq of each of the three ops, in order.
    Future<List<int>> withholdTheMiddleChange() async {
      final first = await _op(workspace, peer, 'one');
      final withheld = await _op(workspace, peer, 'two');
      final third = await _op(workspace, peer, 'three');
      final appended = await peerSession.postOps(
        workspace.workspaceId,
        [first, withheld, third],
      );
      workspace.server.omitSeqs.add(appended[1].seq);
      await a.sync();
      return [for (final op in appended) op.seq];
    }

    test('taking upstream applies the held change and settles the alarm',
        () async {
      await withholdTheMiddleChange();

      // The later change is held, not applied, and it is the accusation.
      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(gap.resolvedAt, isNull);
      expect((await a.client.health()).actionableAlarmCount, 1);
      expect(await _doc(a, workspace), {'step': 'one'});
      final heldBefore = await a.client.quarantined();
      expect(heldBefore.single.releasedAt, isNull);
      final logBefore = await a.loggedOps();

      await a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream);

      // The change is in the reduced state now.
      expect(await _doc(a, workspace), {'step': 'three'});
      final settled =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(settled.resolution, AlarmResolution.tookUpstream.code);
      expect(settled.resolutionDecidedAt, isNotNull);
      expect(settled.resolvedAt, isNotNull);
      expect((await a.client.health()).clean, isTrue);

      // The row is still held. The decision did not make the change verified,
      // and the chain release still owns the row.
      final heldAfter = await a.client.quarantined();
      expect(heldAfter.single.id, heldBefore.single.id);
      expect(heldAfter.single.releasedAt, isNull);
      expect(heldAfter.single.resolution, AlarmResolution.tookUpstream.code);

      // The log is unchanged: a change whose position was never verified is
      // not written into the log.
      final logAfter = await a.loggedOps();
      expect(logAfter.length, logBefore.length);
      expect(
        logAfter.map((row) => row.seq).toList(),
        logBefore.map((row) => row.seq).toList(),
      );
    });

    test('a change that arrives after the decision is released, and heals the log',
        () async {
      final seqs = await withholdTheMiddleChange();
      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      await a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream);

      // The missing change turns up, and the chain heals without asking again.
      workspace.server.omitSeqs.remove(seqs[1]);
      await a.client.resetCursorForReplay();
      await a.sync();

      final released = (await a.client.quarantined()).single;
      expect(released.releasedAt, isNotNull);
      // Nothing changed twice: the change that was taken upstream is the state.
      expect(await _doc(a, workspace), {'step': 'three'});
      final after =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(after.resolvedAt, isNotNull);
    });

    test('a rebuild from the log keeps a change that was taken upstream',
        () async {
      await withholdTheMiddleChange();
      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      await a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream);

      // A rebuild wipes the merge state and replays the log — and the log does
      // not hold this change, because it was never logged.
      await a.client.rebuildFromOpLog();

      expect(await _doc(a, workspace), {'step': 'three'});
    });

    test('a change the device sends after the decision stands the alarm again',
        () async {
      await withholdTheMiddleChange();
      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      await a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream);

      // The peer's next change, held back as well: a new accusation, and a new
      // question — the last answer was about the changes held then.
      final fourth = await _op(workspace, peer, 'four');
      workspace.server.injectUnchecked(workspace.workspaceId, fourth);
      await a.sync();

      final after =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(after.resolvedAt, isNull);
      expect(after.resolution, isNull);
      expect((await a.client.health()).actionableAlarmCount, 1);
    });

    test('a held change whose bytes were corrupted stays held, and the alarm stands',
        () async {
      await withholdTheMiddleChange();
      final held = (await a.client.quarantined()).single;
      // The stored bytes are corrupted after they were stored.
      final corrupted = Uint8List.fromList(held.envelope);
      corrupted[headerLengthBytes + 8] ^= 0x01;
      await (a.database.update(a.database.quarantinedOps)
            ..where((row) => row.id.equals(held.id)))
          .write(QuarantinedOpsCompanion(envelope: Value(corrupted)));

      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      await a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream);

      // The change could not be read, so it was not taken: the row stays
      // undecided, and an undecided row keeps the accusation standing.
      final after = (await a.client.quarantined()).single;
      expect(after.id, held.id);
      expect(after.resolution, isNull);
      expect(after.releasedAt, isNull);
      final stillStanding =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(stillStanding.resolvedAt, isNull);
      expect(stillStanding.resolution, isNull);
      expect((await a.client.health()).actionableAlarmCount, 1);
    });

    // --- Keeping ours on a rollback: the upload is in flight ----------------

    /// The rollback recipe: the server forgets a write it had acknowledged.
    ///
    /// Two writes are acknowledged, the server drops the last one, and this
    /// device authors a third — so the flush is refused and the server says it
    /// expects a position this device has already written past.
    Future<IntegrityAlarmRow> rollTheServerBack() async {
      await a.authorLocal(workspace, 'one');
      await a.authorLocal(workspace, 'two');
      await a.sync();
      final ownSeqs = [
        for (final row in await a.loggedOps())
          if (row.authorMemberId == a.identity.memberId) row.seq,
      ]..sort();
      workspace.server.rollbackToSeq(ownSeqs.last - 1);
      await a.authorLocal(workspace, 'three');
      await a.sync();
      return (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesRollback.code]!;
    }

    /// The author positions the server holds under this device's key.
    List<int> serverAuthorSeqs() => [
          for (final op in workspace.server.storedOps)
            if (op.workspaceId == workspace.workspaceId &&
                op.header?.authorMemberId == a.identity.memberId)
              op.header!.authorSeq,
        ];

    /// The outbox rows this device has yet to have acknowledged.
    Future<List<int>> unsentAuthorSeqs() async {
      final rows = await (a.database.select(a.database.outbox)
            ..where((row) => row.sentAt.isNull()))
          .get();
      return [for (final row in rows) row.authorSeq]..sort();
    }

    test('keeping ours on a rollback re-sends this device\'s own writes',
        () async {
      final rollback = await rollTheServerBack();
      expect(rollback.resolvedAt, isNull);
      expect(
        resolutionsOfferedForAlarmRow(rollback),
        [AlarmResolution.keptOurs],
        reason: 'the rollback knows the position to repost from',
      );
      final authoredBefore = await a.client.authoredEnvelopes();

      await a.client.resolveAlarm(rollback.id, AlarmResolution.keptOurs);

      // The decision is recorded; the accusation stands until the upload is
      // acknowledged.
      final decided =
          (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesRollback.code]!;
      expect(decided.resolution, AlarmResolution.keptOurs.code);
      expect(decided.resolutionDecidedAt, isNotNull);
      expect(decided.resolvedAt, isNull);

      // Two writes are queued again, so the device is busy rather than broken.
      final unsent = await unsentAuthorSeqs();
      expect(unsent.length, 2);
      final health = await a.client.health();
      expect(health.actionableAlarmCount, 0);
      expect(health.unresolvedAlarmCount, 1);
      expect(health.pendingOpCount, 2);
      expect(
        syncStatusFor(
          enrolment: EnrolmentState.enrolled,
          hasMemberCredential: true,
          health: [health],
        ),
        SyncStatus.syncing,
      );

      final after = await a.sync();

      // The server holds this device's writes again.
      expect(serverAuthorSeqs(), containsAll(unsent));
      final settled =
          (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesRollback.code]!;
      expect(settled.resolvedAt, isNotNull);
      expect(settled.resolution, AlarmResolution.keptOurs.code);
      expect(after.clean, isTrue);
      expect(
        syncStatusFor(
          enrolment: EnrolmentState.enrolled,
          hasMemberCredential: true,
          health: [after],
        ),
        SyncStatus.synced,
      );

      // The same signed bytes: nothing was rebuilt, re-signed or re-numbered.
      final authoredAfter = await a.client.authoredEnvelopes();
      expect(authoredAfter.length, authoredBefore.length);
      for (var index = 0; index < authoredBefore.length; index++) {
        expect(
          sameBytes(authoredAfter[index], authoredBefore[index]),
          isTrue,
          reason: 'op $index is the bytes this device signed the first time',
        );
      }
    });

    test('a flush that read its queue before the answer does not settle it',
        () async {
      final rollback = await rollTheServerBack();
      final from = rollback.repostFromAuthorSeq!;

      // The server holds this device's write at the agreed position again — a
      // restore, the same bytes this device signed. The queued write can go
      // out, so the flush below is accepted.
      final lost = await _outboxEnvelope(a, from);
      workspace.server.injectUnchecked(workspace.workspaceId, lost);

      // A flush is already running when the User answers: it read its queue
      // before the answer, so it carries the queued write and not the re-send
      // the answer asked for.
      final gate = Completer<void>();
      a.link.postGate = gate;
      final flush = a.client.flushOutbox();
      await a.link.postGateReached.future;

      // The User answers while the flush is holding its batch.
      await a.client.resolveAlarm(rollback.id, AlarmResolution.keptOurs);
      gate.complete();
      await flush;

      // The decision is recorded, but the re-send has not been acknowledged:
      // the flush never carried the bytes from the agreed position.
      final decided =
          (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesRollback.code]!;
      expect(decided.resolution, AlarmResolution.keptOurs.code);
      expect(decided.resolvedAt, isNull);
      expect(
        await unsentAuthorSeqs(),
        contains(from),
        reason: 'the write from the agreed position is still queued',
      );

      // The re-send goes out, and only then does the accusation close.
      await a.client.flushOutbox();
      final settled =
          (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesRollback.code]!;
      expect(settled.resolvedAt, isNotNull);
    });

    test('a server holding a position this device never wrote offers no answer',
        () async {
      // The other half of the rollback verdict: the server holds a position
      // under this device's key that this device never wrote. There is no
      // agreed position to repost from, so there is nothing to offer — and no
      // answer to refuse.
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
      await a.sync();

      final rollback =
          (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesRollback.code]!;
      expect(rollback.repostFromAuthorSeq, isNull);
      expect(resolutionsOfferedForAlarmRow(rollback), isEmpty);
      await expectLater(
        a.client.resolveAlarm(rollback.id, AlarmResolution.keptOurs),
        throwsA(isA<StateError>()),
      );
    });

    test('a rollback again before the upload stands the alarm again', () async {
      final rollback = await rollTheServerBack();
      await a.client.resolveAlarm(rollback.id, AlarmResolution.keptOurs);

      // The server forgets this device's writes again, before the re-send goes
      // out. The refusal is a new accusation, and it takes the decision with
      // it: the last answer was about the writes the server had then.
      workspace.server.rollbackToSeq(0);
      await a.sync();

      final after =
          (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesRollback.code]!;
      expect(after.resolution, isNull);
      expect(after.resolutionDecidedAt, isNull);
      expect(after.resolvedAt, isNull);
      expect((await a.client.health()).actionableAlarmCount, 1);
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
