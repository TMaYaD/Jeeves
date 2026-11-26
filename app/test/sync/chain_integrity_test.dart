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
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart'
    show OrderingTerm, QueryExecutor, QueryInterceptor, Value;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/sync_status_provider.dart';
import 'package:jeeves/sync/alarm_resolution.dart';
import 'package:jeeves/sync/chain_verifier.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/domain_projector.dart';
import 'package:jeeves/sync/enrolment_state.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/host/merge_state.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/prune_payload.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_transport.dart';
import 'package:sqlite3/common.dart' show SqliteException;
import 'package:uuid/uuid.dart';

import 'harness/author_fixture.dart';
import 'harness/reduced_state.dart';
import 'harness/resolution_columns.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';

const String _harnessCollection = 'harness_docs';
const Uuid _uuid = Uuid();

/// The `todos` entity ids the projection case uses.
///
/// `harness_docs` has no domain row — projection is collection-generic, and an
/// op for a collection this build does not know reduces without becoming a
/// row — so "the change never reached the domain store" is only visible over a
/// collection that *does* have one.
///
/// An entity id travels as a canonical lowercase UUID, so these are minted
/// rather than spelled.
String _todoId(String name) =>
    _uuid.v5(Namespace.url.value, 'jeeves://chain-integrity-todo/$name');

/// The `user_id` the `todos` rows carry. The domain store has no `users` table
/// and no foreign key on it, so this is a plain column.
const String _todoUserId = 'sim-user';

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

/// Runs a refusal's arrival in the middle of the next write to the accusation
/// table.
///
/// A receive that lands while an answer is being recorded cannot be scheduled
/// from outside the client: the statements it makes are the ones the client
/// itself would make, in the same transaction, and the client's receive path
/// cannot be interleaved with its own transaction from a test. So the arrival
/// is injected at the statement level — at the settlement, which is the first
/// write to the accusation table — and it runs inside that transaction, which
/// is what "arriving during the resolution" means for the client.
class _ArrivalDuringResolution extends QueryInterceptor {
  /// The arrival to run, or null when there is none armed.
  Future<void> Function(QueryExecutor executor)? arrival;

  bool _fired = false;

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final run = arrival;
    if (run != null && !_fired && _writesToAccusations(statement)) {
      _fired = true;
      arrival = null;
      await run(executor);
    }
    return super.runUpdate(executor, statement, args);
  }

  /// Whether this statement writes to the accusation table.
  bool _writesToAccusations(String statement) {
    final text = statement.toLowerCase();
    return text.startsWith('update') && text.contains('integrity_alarms');
  }
}

/// A projector that fails the first time it is asked to project, and works
/// afterwards.
///
/// The failure a real projection can have — a storage fault, a codec that
/// cannot read — and the one an answer has to survive: the change is applied
/// to the reduced state but never reaches the domain store, so the User never
/// sees it.
class _FailingOnceProjector extends DomainProjector {
  _FailingOnceProjector(DomainProjector inner)
      : _inner = inner,
        super(
          registry: inner.registry,
          domain: inner.domain,
          chunkEntityCount: inner.chunkEntityCount,
        );

  final DomainProjector _inner;

  bool _failed = false;

  @override
  Future<Set<String>> project(
    Iterable<AffectedEntity> affected, {
    bool leaveEntitiesAwaitingMerge = false,
  }) async {
    if (!_failed) {
      _failed = true;
      throw StateError('the projection failed');
    }
    return _inner.project(
      affected,
      leaveEntitiesAwaitingMerge: leaveEntitiesAwaitingMerge,
    );
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

/// A `todos` op from [author], so what applies has a *domain row* and not only
/// reduced state — which is what the projection case has to observe.
Future<Uint8List> _todoOp(
  SimWorkspace workspace,
  AuthorFixture author,
  String todoId,
  String title,
) async {
  workspace.clock.advance(10);
  return author.nextEnvelope(
    workspace.workspaceId,
    payloadJson: jsonEncode({
      'collection': todosCollection,
      'id': todoId,
      'fields': {
        'title': {'v': title},
        'created_at': {'v': encodeInstant(workspace.clock.asDateTime)},
        'user_id': {'v': _todoUserId},
      },
      'hlc': [workspace.clock.nowMs, 0, memberIdToHex(author.memberId)],
    }),
  );
}

/// The titles on this device's `todos` rows, in name order.
Future<List<Object?>> _todoTitles(SimDevice device) async =>
    (await domainRows(device.domain, 'todos'))
        .map((row) => row['title'])
        .toList()
      ..sort();

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
  late _ArrivalDuringResolution arrival;

  setUp(() async {
    // Installed disarmed: only the case that needs an arrival mid-resolution
    // arms it, and it arms it for one statement.
    arrival = _ArrivalDuringResolution();
    workspace = await SimWorkspace.create(aSyncStoreInterceptor: arrival);
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

    test('a refusal that arrives while the answer is recorded does not close '
        'the accusation', () async {
      final planted = await plantTamperedEnvelope();
      final alarm = planted.alarm;

      // Another forgery arrives while the answer is being recorded: a new
      // refusal, and the accusation stands again.
      final second = Uint8List.fromList(planted.authored.last);
      second[headerLengthBytes + 8] ^= 0x02;
      arrival.arrival = (executor) async {
        final store = SyncDatabase(executor);
        await store.into(store.quarantinedOps).insert(
              QuarantinedOpsCompanion.insert(
                workspaceId: workspace.workspaceId,
                reason: SyncRejectionReason.badSignature.code,
                detail: 'another forgery, arriving while the answer is recorded',
                envelope: second,
                detectedAt: DateTime.utc(2026, 1, 1),
                authorMemberId: Value(alarm.authorMemberId),
              ),
            );
        // The re-raise a receive would have made: the accusation grows, and
        // the answer the User gave was about the smaller one.
        await (store.update(store.integrityAlarms)
              ..where((row) => row.id.equals(alarm.id)))
            .write(IntegrityAlarmsCompanion(
          occurrenceCount: Value(alarm.occurrenceCount + 1),
          resolvedAt: const Value(null),
          resolution: const Value(null),
          resolutionDecidedAt: const Value(null),
        ));
      };

      await a.client.resolveAlarm(
        alarm.id,
        AlarmResolution.rejectedPermanently,
      );

      // The accusation stands: the refusal that arrived was never shown to
      // the User, so their answer cannot close it.
      final after =
          (await a.alarmsByKind())[IntegrityAlarmKind.signatureInvalid.code]!;
      expect(after.resolvedAt, isNull);
      expect(after.resolution, isNull);
      expect(after.resolutionDecidedAt, isNull);
      expect(after.occurrenceCount, alarm.occurrenceCount + 1);
      final health = await a.client.health();
      expect(
        health.unresolvedAlarmCount,
        1,
        reason: 'the accusation still stands',
      );
      expect(
        health.reportableQuarantineCount,
        1,
        reason: 'the refusal that arrived is still to be answered',
      );

      // The refusal that arrived is the open question; the one the User
      // answered keeps the answer.
      final rows = await a.client.quarantined();
      expect(rows.length, 2);
      expect(
        rows.where((row) => row.resolution == null).length,
        1,
        reason: 'the refusal that arrived is undecided',
      );
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

    /// The fork-at-the-head recipe: the release scan proves a mismatch at
    /// head + 1, and the head does not move.
    ///
    /// The peer's head is at 3. A claimant at 5 arrives before its predecessor
    /// at 4, so it is held as a gap; the predecessor lands, the head moves to
    /// 4, and the scan finds that the claimant does not chain to it — a fork
    /// raised at head + 1, with the head left where it was.
    ///
    /// With [alsoHeld], a further claimant is held above the named one: a gap
    /// of its own, which the fork's answer is not about.
    Future<Uint8List> forkAtTheHead({
      bool alsoHeld = false,
      bool samePosition = false,
    }) async {
      final first = await _op(workspace, peer, 'one');
      await peerSession.postOps(workspace.workspaceId, [first]);
      await a.sync();

      // A claimant two positions above the head, chained to a hash that will
      // never be the head's.
      peer.nextAuthorSeq = firstPeerContentAuthorSeq + 2;
      peer.lastEnvelopeHash =
          Uint8List.fromList(List<int>.filled(prevAuthorHashBytes, 0x7f));
      final claimant = await _op(workspace, peer, 'forged');
      workspace.server.injectUnchecked(workspace.workspaceId, claimant);
      await a.sync();

      if (alsoHeld) {
        peer.nextAuthorSeq = firstPeerContentAuthorSeq + (samePosition ? 2 : 3);
        peer.lastEnvelopeHash =
            Uint8List.fromList(List<int>.filled(prevAuthorHashBytes, 0x7e));
        final further = await _op(workspace, peer, 'also forged');
        workspace.server.injectUnchecked(workspace.workspaceId, further);
        await a.sync();
      }

      // The predecessor lands, chained to the head as it stands.
      peer.nextAuthorSeq = firstPeerContentAuthorSeq + 1;
      peer.lastEnvelopeHash = envelopeHash(first);
      final predecessor = await _op(workspace, peer, 'two');
      workspace.server.injectUnchecked(workspace.workspaceId, predecessor);
      await a.sync();

      return claimant;
    }

    test('a fork at the head names the claimant it could not release',
        () async {
      final claimant = await forkAtTheHead();

      final fork =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainFork.code]!;
      expect(fork.resolvedAt, isNull);
      final row = (await a.client.quarantined())
          .singleWhere((r) => sameBytes(r.envelope, claimant));
      expect(
        fork.quarantineOpRowId,
        row.id,
        reason: 'the accusation names the claimant it could not release',
      );
      expect(
        row.authorSeq,
        firstPeerContentAuthorSeq + 2,
        reason: 'and the claimant is one position above the head',
      );

      await a.client.resolveAlarm(fork.id, AlarmResolution.rejectedPermanently);

      // The claimant is answered, so the gap it held open is answered too.
      final answered = (await a.client.quarantined())
          .singleWhere((r) => sameBytes(r.envelope, claimant));
      expect(answered.resolution, AlarmResolution.rejectedPermanently.code);
      expect(answered.resolutionDecidedAt, isNotNull);

      final alarms = await a.alarmsByKind();
      final settledFork = alarms[IntegrityAlarmKind.authorChainFork.code]!;
      expect(settledFork.resolution, AlarmResolution.rejectedPermanently.code);
      expect(settledFork.resolvedAt, isNotNull);
      final settledGap = alarms[IntegrityAlarmKind.authorChainGap.code]!;
      expect(settledGap.resolution, AlarmResolution.rejectedPermanently.code);
      expect(settledGap.resolvedAt, isNotNull);
      expect((await a.client.health()).clean, isTrue);
    });

    test('rejecting a fork answers both mismatching claimants at the head',
        () async {
      await forkAtTheHead(alsoHeld: true, samePosition: true);
      final fork =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainFork.code]!;
      final claimants = (await a.client.quarantined())
          .where((row) => row.authorSeq == firstPeerContentAuthorSeq + 2)
          .toList();
      expect(claimants, hasLength(2));
      expect(fork.occurrenceCount, greaterThanOrEqualTo(2));

      await a.client.resolveAlarm(fork.id, AlarmResolution.rejectedPermanently);

      final answered = (await a.client.quarantined())
          .where((row) => row.authorSeq == firstPeerContentAuthorSeq + 2)
          .toList();
      // Both original claimants are still there, and both are answered.
      expect(
        answered.map((row) => row.id).toSet(),
        claimants.map((row) => row.id).toSet(),
        reason: 'neither claimant was deleted',
      );
      expect(answered.every((row) =>
          row.resolution == AlarmResolution.rejectedPermanently.code), isTrue,
          reason: 'both claimants were proven incompatible with the head');
      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(gap.resolvedAt, isNotNull);
      expect((await a.client.health()).actionableAlarmCount, 0);
    });

    test('rejecting a fork leaves an unrelated future gap undecided', () async {
      final claimant = await forkAtTheHead(alsoHeld: true);

      final fork =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainFork.code]!;
      await a.client.resolveAlarm(fork.id, AlarmResolution.rejectedPermanently);

      // The claimant the accusation named is answered ...
      final answered = (await a.client.quarantined())
          .singleWhere((r) => sameBytes(r.envelope, claimant));
      expect(answered.resolution, AlarmResolution.rejectedPermanently.code);

      // ... and the gap above it is not: the answer was about the claimant,
      // and the gap it holds open is a question of its own.
      final further = (await a.client.quarantined())
          .singleWhere((r) => r.authorSeq == firstPeerContentAuthorSeq + 3);
      expect(further.resolution, isNull);
      expect(further.releasedAt, isNull);

      final alarms = await a.alarmsByKind();
      expect(alarms[IntegrityAlarmKind.authorChainFork.code]!.resolvedAt,
          isNotNull);
      final gap = alarms[IntegrityAlarmKind.authorChainGap.code]!;
      expect(gap.resolvedAt, isNull);
      expect(gap.resolution, isNull);
      expect((await a.client.health()).actionableAlarmCount, 1);
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
      // A decision the refusal does not offer is refused.
      await expectLater(
        a.client.resolveRefusedItem(row.id, AlarmResolution.keptOurs),
        throwsA(isA<StateError>()),
      );
    });

    test('a refusal that escalates to an alarm is answered on the alarm, not '
        'on the row', () async {
      await plantTamperedEnvelope();
      final row = (await a.client.quarantined()).single;

      // The decision is one the row could otherwise take: only the alarm guard
      // stands in the way.
      await expectLater(
        a.client.resolveRefusedItem(row.id, AlarmResolution.rejectedPermanently),
        throwsA(isA<StateError>()),
      );

      expect((await a.client.quarantined()).single.resolution, isNull);
      expect(
        (await a.alarmsByKind())[IntegrityAlarmKind.signatureInvalid.code]!
            .resolvedAt,
        isNull,
      );
    });

    test('an answer about an accusation raised again since is refused',
        () async {
      final planted = await plantTamperedEnvelope();

      await expectLater(
        a.client.resolveAlarm(
          planted.alarm.id,
          AlarmResolution.rejectedPermanently,
          expectedOccurrenceCount: planted.alarm.occurrenceCount + 1,
        ),
        throwsA(isA<StateError>()),
      );

      final alarm =
          (await a.alarmsByKind())[IntegrityAlarmKind.signatureInvalid.code]!;
      expect(alarm.resolution, isNull);
      expect((await a.client.quarantined()).single.resolution, isNull);
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

      expect(await _doc(a, workspace), {'step': 'three'});
      final settled =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(settled.resolution, AlarmResolution.tookUpstream.code);
      expect(settled.resolutionDecidedAt, isNotNull);
      expect(settled.resolvedAt, isNotNull);
      expect((await a.client.health()).clean, isTrue);

      // The row was released through the ordinary pipeline, bytes untouched.
      final heldAfter = await a.client.quarantined();
      expect(heldAfter.single.id, heldBefore.single.id);
      expect(heldAfter.single.releasedAt, isNotNull);
      expect(heldAfter.single.resolution, AlarmResolution.tookUpstream.code);
      expect(heldAfter.single.envelope, heldBefore.single.envelope);

      // The released change is in the log, applied.
      final logAfter = await a.loggedOps();
      expect(logAfter.length, logBefore.length + 1);
      final third = logAfter.singleWhere(
        (row) => row.authorSeq == firstPeerContentAuthorSeq + 2,
      );
      expect(third.appliedAt, isNotNull);

      // One hole, covering exactly the withheld position.
      final holes =
          await a.client.acceptedChainHoles(authorMemberId: peer.memberId);
      expect(holes.single.firstMissingAuthorSeq, firstPeerContentAuthorSeq + 1);
      expect(holes.single.lastMissingAuthorSeq, firstPeerContentAuthorSeq + 1);
      final header =
          OpHeader.parse(splitEnvelope(heldBefore.single.envelope).header);
      expect(holes.single.lastMissingEnvelopeHash, header.prevAuthorHash);
    });

    test('a tampered later change is refused under its own name', () async {
      await withholdTheMiddleChange();
      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      await a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream);

      // The next change from that device, with one byte of its body flipped:
      // the signature no longer covers what it says it does.
      final fourth = await _op(workspace, peer, 'four');
      final tampered = Uint8List.fromList(fourth);
      tampered[headerLengthBytes + 8] ^= 0x01;
      workspace.server.injectUnchecked(workspace.workspaceId, tampered);
      await a.sync();

      // The refusal is filed under its own name. The bytes are not the
      // author's, and that is the whole of the accusation.
      final alarms = await a.alarmsByKind();
      final signature = alarms[IntegrityAlarmKind.signatureInvalid.code]!;
      expect(signature.resolvedAt, isNull);
      expect(signature.resolution, isNull);
      expect(
        (await a.client.quarantined(includeReleased: false)).single.reason,
        SyncRejectionReason.badSignature.code,
      );

      // The decision the User already made is not reopened by this: the gap it
      // settled is still settled, and the hole it recorded is still recorded.
      final settled = alarms[IntegrityAlarmKind.authorChainGap.code]!;
      expect(settled.resolvedAt, isNotNull);
      expect(settled.resolution, AlarmResolution.tookUpstream.code);
      expect(
        await a.client.acceptedChainHoles(authorMemberId: peer.memberId),
        hasLength(1),
      );

      // And the tampered change did not become the state.
      expect(await _doc(a, workspace), {'step': 'three'});
    });

    test('different bytes at a position past the hole are a rewrite', () async {
      await withholdTheMiddleChange();
      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      await a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream);

      // A second change, at the position the log now holds one at. It is
      // signed by the same author and it is newer than the change it would
      // replace, so nothing but the chain rules stand between it and the log.
      final rival = await peer.nextEnvelope(
        workspace.workspaceId,
        authorSeq: firstPeerContentAuthorSeq + 2,
        advance: false,
        payloadJson: jsonEncode({
          'collection': _harnessCollection,
          'id': _docId(workspace),
          'fields': {
            'step': {'v': 'three as well'},
          },
          'hlc': [workspace.clock.nowMs + 1, 0, memberIdToHex(peer.memberId)],
        }),
      );
      workspace.server.injectUnchecked(workspace.workspaceId, rival);
      await a.sync();

      // The hole is a range the User accepted as missing, not a licence to
      // change what the log already holds past it.
      expect(
        (await a.alarmsByKind())[IntegrityAlarmKind.authorChainRewrite.code],
        isNotNull,
      );
      expect(
        (await a.client.quarantined(includeReleased: false)).single.reason,
        SyncRejectionReason.authorChainRewrite.code,
      );
      expect(await _doc(a, workspace), {'step': 'three'});
    });

    test('a projection that fails leaves the accusation open for another answer',
        () async {
      // The same withheld change, over a collection with a domain row: the
      // failure has to be visible where the User would see it.
      final first = await _todoOp(workspace, peer, _todoId('one'), 'one');
      final withheld = await _todoOp(workspace, peer, _todoId('two'), 'two');
      final third = await _todoOp(workspace, peer, _todoId('three'), 'three');
      final appended = await peerSession.postOps(
        workspace.workspaceId,
        [first, withheld, third],
      );
      workspace.server.omitSeqs.add(appended[1].seq);
      await a.sync();

      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(
        await _todoTitles(a),
        ['one'],
        reason: 'the held change is not on screen yet',
      );

      // The projection fails: the change is reduced, but it never reaches the
      // domain store, so the User never sees it.
      final original = a.client.projector!;
      a.client.projector = _FailingOnceProjector(original);
      await expectLater(
        a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream),
        throwsA(isA<StateError>()),
      );

      // The change is not on screen.
      expect(
        await _todoTitles(a),
        ['one'],
        reason: 'the change never reached the domain store',
      );

      // The accusation stands: the answer is still on offer, and the work is
      // still to be done.
      final standing =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(standing.resolvedAt, isNull);
      expect(standing.resolution, isNull);
      expect(standing.resolutionDecidedAt, isNull);
      expect((await a.client.health()).actionableAlarmCount, 1);

      // The User answers again, and this time the projection works.
      a.client.projector = original;
      await a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream);

      expect(
        await _todoTitles(a),
        ['one', 'three'],
        reason: 'the retry puts the change on screen',
      );
      final settled =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(settled.resolution, AlarmResolution.tookUpstream.code);
      expect(settled.resolutionDecidedAt, isNotNull);
      expect(settled.resolvedAt, isNotNull);
      expect((await a.client.health()).clean, isTrue);
    });

    test('chain release preserves recovery after take upstream projection fails',
        () async {
      final first = await _todoOp(workspace, peer, _todoId('one'), 'one');
      final withheld = await _todoOp(workspace, peer, _todoId('two'), 'two');
      final third = await _todoOp(workspace, peer, _todoId('three'), 'three');
      final appended = await peerSession.postOps(
        workspace.workspaceId,
        [first, withheld, third],
      );
      workspace.server.omitSeqs.add(appended[1].seq);
      await a.sync();
      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      final original = a.client.projector!;
      a.client.projector = _FailingOnceProjector(original);
      await expectLater(
        a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream),
        throwsA(isA<StateError>()),
      );
      expect(await _todoTitles(a), ['one']);

      // The predecessor now heals the chain, but projecting the released
      // changes fails too. The next pull must retain work to put on screen.
      workspace.server.omitSeqs.remove(appended[1].seq);
      await a.client.resetCursorForReplay();
      a.client.projector = _FailingOnceProjector(original);
      await expectLater(a.sync(), throwsA(isA<StateError>()));
      expect((await a.client.quarantined()).single.releasedAt, isNotNull);
      expect(await _todoTitles(a), ['one']);

      a.client.projector = original;
      await a.sync();
      expect(await _todoTitles(a), ['one', 'three', 'two'],
          reason: 'chain release must not discard unprojected resolution work');
    });

    test('a prune that settles the gap leaves the accusation standing while '
        'the take upstream is unprojected', () async {
      final first = await _todoOp(workspace, peer, _todoId('one'), 'one');
      final withheld = await _todoOp(workspace, peer, _todoId('two'), 'two');
      final third = await _todoOp(workspace, peer, _todoId('three'), 'three');
      final appended = await peerSession.postOps(
        workspace.workspaceId,
        [first, withheld, third],
      );
      workspace.server.omitSeqs.add(appended[1].seq);
      await a.sync();
      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;

      // The User answers with *take upstream*, and the projection fails: the
      // change is reduced, but it never reaches the screen.
      final original = a.client.projector!;
      a.client.projector = _FailingOnceProjector(original);
      await expectLater(
        a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream),
        throwsA(isA<StateError>()),
      );
      expect(await _todoTitles(a), ['one']);

      // A prune from the compactor attests the held change's own bytes, which
      // settles the claimant: the gap row is released by the attestation. The
      // prune is put into the server's log without the server's own admission
      // checks — the pairing compaction op is not what this case is about.
      final held = (await a.client.quarantined()).single;
      expect(held.authorSeq, firstPeerContentAuthorSeq + 2,
          reason: 'the held change is the peer\'s third one');
      await workspace.b.client.capturePrune(PrunePayload(
        compactionOpId: const Uuid().v4(),
        targets: [
          PruneTarget(
            seq: appended[2].seq,
            authorMemberId: peer.memberId,
            authorSeq: firstPeerContentAuthorSeq + 2,
            envelopeHash: envelopeHash(held.envelope),
          ),
        ],
      ));
      final authored = await workspace.b.client.authoredEnvelopes();
      workspace.server.injectUnchecked(workspace.workspaceId, authored.last);

      // The prune arrives, and the batch projection fails again, so the
      // outstanding work is still outstanding when the prune is processed.
      a.client.projector = _FailingOnceProjector(original);
      await expectLater(a.sync(), throwsA(isA<StateError>()));
      // The prune released the held row; the projection of it is still owed.
      final releasedHeld = (await a.client.quarantined())
          .singleWhere((row) => row.id == held.id);
      expect(releasedHeld.releasedAt, isNotNull,
          reason: 'the prune is what released the claimant');
      expect(releasedHeld.resolutionProjectedAt, isNull);

      // The accusation stands: the settlement released the claimant, but the
      // change is still not on the screen, so there is still work to be done
      // and still something to ask about.
      final standing =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(standing.resolvedAt, isNull,
          reason: 'the take upstream has not reached the screen yet');
      expect((await a.client.health()).actionableAlarmCount, 1);

      // The next pull recovers the work the settlement did not finish.
      a.client.projector = original;
      await a.sync();
      expect(await _todoTitles(a), ['one', 'three'],
          reason: 'the recovery projects what the prune settled');
      final settled =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(settled.resolvedAt, isNotNull);
      expect((await a.client.health()).clean, isTrue);
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

      // The log holds the change that was missing: it fills the hole the User
      // accepted, and it is logged like any other change.
      final filled = (await a.loggedOps()).singleWhere(
        (row) => row.authorSeq == firstPeerContentAuthorSeq + 1,
      );
      expect(filled.appliedAt, isNotNull);

      // No alarm of any kind stands. The gap the decision settled is the only
      // accusation there was, and it is settled.
      final alarms = await a.alarmsByKind();
      expect(alarms, isNotEmpty);
      expect(
        alarms.values.every((alarm) => alarm.resolvedAt != null),
        isTrue,
        reason: 'the only accusation left is the settled one',
      );
      expect((await a.client.health()).actionableAlarmCount, 0);
      expect((await a.client.health()).clean, isTrue);
    });

    test('a rebuild from the log keeps a change that was taken upstream',
        () async {
      await withholdTheMiddleChange();
      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      await a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream);

      // A rebuild wipes the merge state and replays the log — and the log
      // holds this change now, because the decision released it into the log.
      await a.client.rebuildFromOpLog();

      expect(await _doc(a, workspace), {'step': 'three'});

      // The decision is still recorded. A rebuild replays the log; it does not
      // forget what the User accepted.
      expect(
        await a.client.acceptedChainHoles(authorMemberId: peer.memberId),
        hasLength(1),
      );

      // And the standing decision still stands over what comes next.
      await peerSession.postOps(
        workspace.workspaceId,
        [await _op(workspace, peer, 'four')],
      );
      await a.sync();

      expect(await _doc(a, workspace), {'step': 'four'});
      final after =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(after.resolvedAt, isNotNull);
      expect(after.resolution, AlarmResolution.tookUpstream.code);
      expect((await a.client.health()).actionableAlarmCount, 0);
    });

    test('a later change from that device applies and raises nothing',
        () async {
      await withholdTheMiddleChange();
      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      await a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream);

      final fourth = await _op(workspace, peer, 'four');
      workspace.server.injectUnchecked(workspace.workspaceId, fourth);
      await a.sync();

      expect(await _doc(a, workspace), {'step': 'four'});
      final after =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(after.resolvedAt, isNotNull);
      expect(after.resolution, AlarmResolution.tookUpstream.code);
      expect((await a.client.health()).actionableAlarmCount, 0);
      expect(await a.client.quarantined(includeReleased: false), isEmpty);
      final logged = await a.loggedOps();
      final row = logged.singleWhere(
        (r) => r.authorSeq == firstPeerContentAuthorSeq + 3,
      );
      expect(row.appliedAt, isNotNull);
    });

    test('a second missing change asks again', () async {
      await withholdTheMiddleChange();
      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      await a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream);

      await _op(workspace, peer, 'four'); // minted, never delivered
      final fifth = await _op(workspace, peer, 'five');
      workspace.server.injectUnchecked(workspace.workspaceId, fifth);
      await a.sync();

      final standing =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(standing.resolvedAt, isNull);
      expect(standing.resolution, isNull);
      expect((await a.client.health()).actionableAlarmCount, 1);

      await a.client.resolveAlarm(standing.id, AlarmResolution.tookUpstream);

      expect(
        await a.client.acceptedChainHoles(authorMemberId: peer.memberId),
        hasLength(2),
      );
      expect(await _doc(a, workspace), {'step': 'five'});
      expect((await a.client.health()).clean, isTrue);
    });

    test('the decision survives a restart', () async {
      // A device with a real file behind its store, so a restart is a reopen of
      // the same store and not a fresh memory.
      final device = await SimDevice.create(
        label: 'R',
        userId: workspace.userId,
        server: workspace.server,
        clock: workspace.clock,
        passphrase: workspace.passphrase,
        fileBacked: true,
      );
      addTearDown(device.close);

      final first = await _op(workspace, peer, 'one');
      final withheld = await _op(workspace, peer, 'two');
      final third = await _op(workspace, peer, 'three');
      final appended = await peerSession.postOps(
        workspace.workspaceId,
        [first, withheld, third],
      );
      workspace.server.omitSeqs.add(appended[1].seq);
      await device.sync();

      final gap =
          (await device.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(gap.resolvedAt, isNull);

      await device.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream);

      // The app is killed and comes back. The decision is in the store, so it
      // is still there.
      final reopened = await device.reopenSyncStore();

      final holes = await reopened.acceptedChainHoles(
        authorMemberId: peer.memberId,
      );
      expect(holes, hasLength(1));
      expect(holes.single.firstMissingAuthorSeq, firstPeerContentAuthorSeq + 1);
      expect(holes.single.lastMissingAuthorSeq, firstPeerContentAuthorSeq + 1);
    });

    test('two holes at once are both accepted', () async {
      final first = await _op(workspace, peer, 'one');
      final second = await _op(workspace, peer, 'two');
      final third = await _op(workspace, peer, 'three');
      final fourth = await _op(workspace, peer, 'four');
      final fifth = await _op(workspace, peer, 'five');
      final appended = await peerSession.postOps(
        workspace.workspaceId,
        [first, second, third, fourth, fifth],
      );
      // The server withholds the second and the fourth change: two ranges of
      // the chain never arrive.
      workspace.server.omitSeqs.add(appended[1].seq);
      workspace.server.omitSeqs.add(appended[3].seq);
      await a.sync();

      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(gap.resolvedAt, isNull);

      await a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream);

      // One decision, two holes: the User accepted both ranges, and each is
      // recorded as its own hole.
      final holes =
          await a.client.acceptedChainHoles(authorMemberId: peer.memberId);
      expect(holes, hasLength(2));
      expect(holes.first.firstMissingAuthorSeq, firstPeerContentAuthorSeq + 1);
      expect(holes.first.lastMissingAuthorSeq, firstPeerContentAuthorSeq + 1);
      expect(holes.last.firstMissingAuthorSeq, firstPeerContentAuthorSeq + 3);
      expect(holes.last.lastMissingAuthorSeq, firstPeerContentAuthorSeq + 3);

      // Every change that did arrive applies, and nothing is left to ask about.
      expect(await _doc(a, workspace), {'step': 'five'});
      expect((await a.client.health()).clean, isTrue);
    });

    test(
        'two different changes held behind the gap are a fork, and nothing is accepted',
        () async {
      final first = await _op(workspace, peer, 'one');
      await peerSession.postOps(workspace.workspaceId, [first]);
      await a.sync();

      await _op(workspace, peer, 'two'); // minted, never posted or injected
      final third = await _op(workspace, peer, 'three', advance: false);
      final rival = await _op(workspace, peer, 'three as well', advance: false);
      workspace.server.injectUnchecked(workspace.workspaceId, third);
      await a.sync();
      workspace.server.injectUnchecked(workspace.workspaceId, rival);
      await a.sync();

      final staged = await a.client.quarantined(includeReleased: false);
      expect(staged.length, 2);
      expect(
        staged.map((row) => row.authorSeq).toSet(),
        {firstPeerContentAuthorSeq + 2},
      );
      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(gap.resolvedAt, isNull);
      final logLength = (await a.loggedOps()).length;

      Future<void> expectNothingAccepted() async {
        expect(
          await a.client.acceptedChainHoles(authorMemberId: peer.memberId),
          isEmpty,
        );
        expect(await _doc(a, workspace), {'step': 'one'});
        final rows = await a.client.quarantined();
        final rivalRow =
            rows.singleWhere((row) => sameBytes(row.envelope, rival));
        final fork =
            (await a.alarmsByKind())[IntegrityAlarmKind.authorChainFork.code]!;
        expect(fork.resolvedAt, isNull);
        expect(fork.quarantineOpRowId, rivalRow.id);
        final standing =
            (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
        expect(standing.resolvedAt, isNull);
        expect(standing.resolution, isNull);
        for (final row in rows) {
          expect(row.releasedAt, isNull);
          expect(row.resolution, isNull);
        }
        expect((await a.loggedOps()).length, logLength);
        expect((await a.client.health()).clean, isFalse);
      }

      await a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream);
      await expectNothingAccepted();
      await a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream);
      await expectNothingAccepted();
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
      // The answer says out loud that it could not be carried out.
      await expectLater(
        a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream),
        throwsA(isA<StateError>()),
      );

      // The change could not be read, so it was not taken: the row stays
      // undecided, and an undecided row keeps the accusation standing.
      expect(await _doc(a, workspace), {'step': 'one'});
      final after = (await a.client.quarantined()).single;
      expect(after.id, held.id);
      expect(after.resolution, isNull);
      expect(after.releasedAt, isNull);
      final stillStanding =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(stillStanding.resolvedAt, isNull);
      expect(stillStanding.resolution, isNull);
      expect((await a.client.health()).actionableAlarmCount, 1);
      expect(
        await a.client.acceptedChainHoles(authorMemberId: peer.memberId),
        isEmpty,
      );
    });

    test('a held change whose header disagrees with its row is not applied',
        () async {
      await withholdTheMiddleChange();
      final held = (await a.client.quarantined()).single;
      // The row claims a position its own header does not hold.
      await (a.database.update(a.database.quarantinedOps)
            ..where((row) => row.id.equals(held.id)))
          .write(QuarantinedOpsCompanion(authorSeq: Value(held.authorSeq! + 1)));

      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      await expectLater(
        a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream),
        throwsA(isA<StateError>()),
      );

      expect(await _doc(a, workspace), {'step': 'one'});
      final after = (await a.client.quarantined()).single;
      expect(after.resolution, isNull);
      final stillStanding =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(stillStanding.resolvedAt, isNull);
      expect((await a.client.health()).actionableAlarmCount, 1);
    });

    test('a held change written for another Workspace is left undecided',
        () async {
      await peerSession.postOps(
        workspace.workspaceId,
        [await _op(workspace, peer, 'one')],
      );
      await a.sync();
      final cursorBefore = await a.cursor();

      // The peer signed this change for a different Workspace, far enough ahead
      // of its chain here to be held as a gap. It is served at a position the
      // cursor has already passed.
      final otherWorkspaceId = _uuid.v4();
      workspace.clock.advance(10);
      final foreign = await peer.nextEnvelope(
        otherWorkspaceId,
        authorSeq: peer.nextAuthorSeq + 2,
        advance: false,
        payloadJson: jsonEncode({
          'collection': _harnessCollection,
          'id': _docId(workspace),
          'fields': {
            'step': {'v': 'foreign'},
          },
          'hlc': [workspace.clock.nowMs, 0, memberIdToHex(peer.memberId)],
        }),
      );
      workspace.server.injectUnchecked(
        workspace.workspaceId,
        foreign,
        atSeq: cursorBefore,
      );
      workspace.server.ignoreSinceParameter = true;
      await a.sync();

      final held = (await a.client.quarantined())
          .where((row) => row.reason == SyncRejectionReason.authorChainGap.code)
          .single;
      final gap =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(gap.resolvedAt, isNull);

      await expectLater(
        a.client.resolveAlarm(gap.id, AlarmResolution.tookUpstream),
        throwsA(isA<StateError>()),
      );

      expect(await _doc(a, workspace), {'step': 'one'});
      final after = (await a.client.quarantined())
          .singleWhere((row) => row.id == held.id);
      expect(after.resolution, isNull);
      final stillStanding =
          (await a.alarmsByKind())[IntegrityAlarmKind.authorChainGap.code]!;
      expect(stillStanding.resolvedAt, isNull);
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

      // The User answers while the flush is holding its batch. The gate is
      // released and the flush joined on every path, so a failed answer leaves
      // no upload waiting behind it — and is still the failure that is seen.
      try {
        await a.client.resolveAlarm(rollback.id, AlarmResolution.keptOurs);
      } finally {
        if (!gate.isCompleted) gate.complete();
        a.link.postGate = null;
        await flush;
      }

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
      // The acknowledgement the old flush brought back belongs to the old
      // queue: the write it carried was re-queued with the rest, and the
      // server may have lost it in the rollback the answer is about.
      expect(
        await unsentAuthorSeqs(),
        [from, from + 1],
        reason: 'a pre-answer acknowledgement does not count toward the re-send',
      );

      // The re-send goes out, and only then does the accusation close.
      await a.client.flushOutbox();
      final settled =
          (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesRollback.code]!;
      expect(settled.resolvedAt, isNotNull);
    });

    test('a re-raise behind the settlement does not close the new accusation',
        () async {
      final rollback = await rollTheServerBack();
      final from = rollback.repostFromAuthorSeq!;

      await a.client.resolveAlarm(rollback.id, AlarmResolution.keptOurs);

      // The re-send goes out, and the settlement that follows it is the moment
      // the accusation is closed. A refusal that arrives in that window is a
      // new accusation — the server forgot this device's writes again, and
      // further back — and the answer the User gave was about the smaller one.
      arrival.arrival = (executor) async {
        final store = SyncDatabase(executor);
        await (store.update(store.integrityAlarms)
              ..where((row) => row.id.equals(rollback.id)))
            .write(IntegrityAlarmsCompanion(
          occurrenceCount: Value(rollback.occurrenceCount + 1),
          resolvedAt: const Value(null),
          resolution: const Value(null),
          resolutionDecidedAt: const Value(null),
          repostFromAuthorSeq: Value(from - 1),
        ));
      };

      await a.client.flushOutbox();

      // The new accusation stands: it is a question, and the answer to the
      // older one cannot close it.
      final after =
          (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesRollback.code]!;
      expect(after.resolvedAt, isNull);
      expect(after.resolution, isNull);
      expect(after.resolutionDecidedAt, isNull);
      expect(after.occurrenceCount, rollback.occurrenceCount + 1);
      expect(after.repostFromAuthorSeq, from - 1);
      expect((await a.client.health()).actionableAlarmCount, 1);
    });

    test('a re-raise before the answer is recorded leaves the new accusation '
        'and the outbox alone', () async {
      final rollback = await rollTheServerBack();
      final from = rollback.repostFromAuthorSeq!;
      final unsentBefore = await unsentAuthorSeqs();

      // The server forgets this device's writes again while the User is
      // answering: a new accusation, about a position further back, and the
      // answer the User gave was about the smaller one. It lands on the first
      // write to the accusation table — the moment the decision is stamped —
      // which is inside the very transaction that records the answer.
      arrival.arrival = (executor) async {
        final store = SyncDatabase(executor);
        await (store.update(store.integrityAlarms)
              ..where((row) => row.id.equals(rollback.id)))
            .write(IntegrityAlarmsCompanion(
          occurrenceCount: Value(rollback.occurrenceCount + 1),
          resolvedAt: const Value(null),
          resolution: const Value(null),
          resolutionDecidedAt: const Value(null),
          repostFromAuthorSeq: Value(from - 1),
        ));
      };

      await expectLater(
        a.client.resolveAlarm(rollback.id, AlarmResolution.keptOurs),
        throwsA(isA<StateError>()),
        reason: 'the answer was about an accusation that no longer stands',
      );

      // The new accusation stands unanswered: it is a question, and the stale
      // answer cannot close it.
      final after =
          (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesRollback.code]!;
      expect(after.resolvedAt, isNull);
      expect(after.resolution, isNull);
      expect(after.resolutionDecidedAt, isNull);
      expect(after.occurrenceCount, rollback.occurrenceCount + 1);
      expect(after.repostFromAuthorSeq, from - 1);

      // And the outbox is untouched: a stale answer queues no range, so the
      // writes the server expects are not re-sent on the old position.
      expect(await unsentAuthorSeqs(), unsentBefore);
      expect((await a.client.health()).actionableAlarmCount, 1);
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

    // --- A server only slightly ahead of this device -------------------------

    /// The server holds one write under this device's key that this device never
    /// sent, at the next position, and this device then authors [localWrites]
    /// writes of its own. The refusal that follows names a position this device
    /// has authored but not yet sent.
    Future<IntegrityAlarmRow?> serverHoldsOneWriteThisDeviceNeverSent({
      int localWrites = 1,
    }) async {
      await a.sync();
      final authored = await a.client.authoredEnvelopes();
      final unsent = await a.identity.signer.buildEnvelope(
        OpHeader(
          workspaceId: workspace.workspaceId,
          opClass: opClassContent,
          opId: _uuid.v4(),
          authorMemberId: a.identity.memberId,
          authorKeyId: a.identity.keyId,
          authorSeq: authored.length + 1,
          prevAuthorHash: envelopeHash(authored.last),
        ),
        frameBody(Uint8List.fromList(utf8.encode(jsonEncode({
          'collection': _harnessCollection,
          'id': _docId(workspace),
          'fields': {
            'step': {'v': 'written elsewhere'},
          },
          'hlc': [workspace.clock.nowMs, 0, a.identity.memberIdHex],
        })))),
      );
      workspace.server.injectUnchecked(workspace.workspaceId, unsent);
      for (var write = 0; write < localWrites; write++) {
        await a.authorLocal(workspace, 'mine $write');
      }
      await a.sync();
      return (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesRollback.code];
    }

    test('a server one write ahead of this device raises the rollback alarm',
        () async {
      final rollback = await serverHoldsOneWriteThisDeviceNeverSent();

      expect(rollback, isNotNull);
      expect(rollback!.resolvedAt, isNull);
      expect(rollback.authorMemberId, a.identity.memberId);
      expect(rollback.repostFromAuthorSeq, isNull);
      final health = await a.client.health();
      expect(health.pendingOpCount, 1);
      expect(health.clean, isFalse);
      expect(health.actionableAlarmCount, greaterThan(0));
      expect(await unsentAuthorSeqs(), hasLength(1));
    });

    test(
        'a server ahead by less than this device\'s unsent writes offers what '
        'the server-ahead case offers', () async {
      final rollback =
          await serverHoldsOneWriteThisDeviceNeverSent(localWrites: 2);
      expect(rollback, isNotNull);
      expect(rollback!.repostFromAuthorSeq, isNull);
      final offered = resolutionsOfferedForAlarmRow(rollback);

      // Now push the same device far ahead, the way the server-ahead case does.
      final far = await a.identity.signer.buildEnvelope(
        OpHeader(
          workspaceId: workspace.workspaceId,
          opClass: opClassContent,
          opId: _uuid.v4(),
          authorMemberId: a.identity.memberId,
          authorKeyId: a.identity.keyId,
          authorSeq: 40,
        ),
        frameBody(Uint8List.fromList(utf8.encode('{"collection":"test"}'))),
      );
      workspace.server.injectUnchecked(workspace.workspaceId, far);
      await a.sync();

      final farRow =
          (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesRollback.code]!;
      expect(farRow.detail, contains('authoring under'));
      expect(farRow.repostFromAuthorSeq, isNull);
      expect(resolutionsOfferedForAlarmRow(farRow), offered);
    });

    test('a lost response is not a rollback', () async {
      await a.authorLocal(workspace, 'one');
      a.link.dropPostResponse = true;
      await expectLater(a.sync(), throwsA(isA<SyncTransportException>()));
      await a.authorLocal(workspace, 'two');
      await a.sync();

      expect(
        (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesRollback.code],
        isNull,
      );
      final health = await a.client.health();
      expect(health.pendingOpCount, 0);
      expect(health.clean, isTrue);
    });

    test('a refusal at exactly the next unsent position raises nothing',
        () async {
      final rollback = await rollTheServerBack();
      final repostFrom = rollback.repostFromAuthorSeq;

      // A flush reads its queue, and is held at the gate.
      final gate = Completer<void>();
      a.link.postGate = gate;
      final flush = a.client.flushOutbox();
      await a.link.postGateReached.future;

      // The User answers while it is held: the older rows go back to unsent, so
      // the held flush (which carries only the newest) is refused at exactly the
      // first unsent position. The server is not given the lost write back.
      try {
        await a.client.resolveAlarm(rollback.id, AlarmResolution.keptOurs);
      } finally {
        if (!gate.isCompleted) gate.complete();
        a.link.postGate = null;
        await flush;
      }

      final after =
          (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesRollback.code]!;
      expect(after.resolution, AlarmResolution.keptOurs.code);
      expect(after.repostFromAuthorSeq, repostFrom);
      expect(after.resolvedAt, isNull);

      await a.sync();
      final settled =
          (await a.alarmsByKind())[IntegrityAlarmKind.ownWritesRollback.code]!;
      expect(settled.resolvedAt, isNotNull);
      expect((await a.client.health()).clean, isTrue);
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

  // --- An accepted hole: the chain floor bridges what the user accepted -------

  group('an accepted hole', () {
    /// The peer's three content changes, with the server holding the second and
    /// the third back.
    ///
    /// The peer's content positions are 3, 4 and 5 — the enrolment spent the
    /// first two on the register and the grant — so only the first arrives, the
    /// logged head is 3, and the change that never came is at 4.
    Future<
            ({
              Uint8List withheld,
              int withheldTransportSeq,
              Uint8List third,
              int thirdTransportSeq,
            })>
        withholdTwoChanges() async {
      final first = await _op(workspace, peer, 'one');
      final withheld = await _op(workspace, peer, 'two');
      final third = await _op(workspace, peer, 'three');
      final appended = await peerSession.postOps(
        workspace.workspaceId,
        [first, withheld, third],
      );
      workspace.server.omitSeqs.add(appended[1].seq);
      workspace.server.omitSeqs.add(appended[2].seq);
      await a.sync();
      return (
        withheld: withheld,
        withheldTransportSeq: appended[1].seq,
        third: third,
        thirdTransportSeq: appended[2].seq,
      );
    }

    /// The hole the user accepted: the range of the chain that never arrived,
    /// and the hash of the change just past it.
    Future<void> acceptHole({
      required int firstMissingAuthorSeq,
      required int lastMissingAuthorSeq,
      required Uint8List lastMissingEnvelopeHash,
    }) async {
      await a.database.into(a.database.acceptedChainHoles).insert(
            AcceptedChainHolesCompanion.insert(
              workspaceId: a.client.workspaceId,
              authorMemberId: peer.memberId,
              firstMissingAuthorSeq: firstMissingAuthorSeq,
              lastMissingAuthorSeq: lastMissingAuthorSeq,
              lastMissingEnvelopeHash: lastMissingEnvelopeHash,
              // Nothing held this hole down yet: the user accepted it before
              // anything was quarantined for it.
              definingQuarantineOpRowId: 0,
              decidedAt: DateTime.utc(2026, 11, 26),
            ),
          );
    }

    test('a v15 sync store opens at 16 and keeps every row', () async {
      final directory = Directory.systemTemp.createTempSync('sync-v15-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/sync.sqlite');

      final seed = SyncDatabase(NativeDatabase(file));
      // A v15 store is the one the take-upstream work shipped: it holds the
      // projection marker and none of the accepted-chain-holes table.
      await dropColumnsAddedAfter(seed, 15);
      await seed.customStatement(
        'INSERT INTO integrity_alarms (workspace_id, kind, detail, '
        'occurrence_count, first_detected_at, last_detected_at) '
        "VALUES ('workspace-1', 'own_writes_rollback', 'the server lost a write', "
        "1, '2026-08-01T00:00:00.000Z', '2026-08-01T00:00:00.000Z')",
      );
      await seed.customStatement(
        'INSERT INTO quarantined_ops (workspace_id, reason, detail, envelope, '
        "detected_at) VALUES ('workspace-1', 'bad_signature', 'forged', X'', "
        "'2026-08-01T00:00:00.000Z')",
      );
      await seed.customStatement('PRAGMA user_version = 15');
      await seed.close();

      final upgraded = SyncDatabase(NativeDatabase(file));
      addTearDown(upgraded.close);
      expect(upgraded.schemaVersion, 16);

      final alarm = await upgraded.select(upgraded.integrityAlarms).getSingle();
      expect(alarm.kind, IntegrityAlarmKind.ownWritesRollback.code);
      expect(alarm.detail, 'the server lost a write');
      expect(alarm.occurrenceCount, 1);

      final quarantine =
          await upgraded.select(upgraded.quarantinedOps).getSingle();
      expect(quarantine.reason, SyncRejectionReason.badSignature.code);
      expect(quarantine.detail, 'forged');

      final holes = await upgraded.select(upgraded.acceptedChainHoles).get();
      expect(
        holes,
        isEmpty,
        reason: 'no hole was accepted before the table existed',
      );
    });

    test('the floor bridges a hole the user accepted', () async {
      final withheld = await withholdTwoChanges();

      // Only the first change arrived, and nothing is accused: the server
      // withheld the rest, so there is nothing to accuse it of yet.
      expect(await _doc(a, workspace), {'step': 'one'});
      expect(await a.alarmsByKind(), isEmpty);
      expect(
        await a.client.effectiveChainHeadSeq(peer.memberId),
        firstPeerContentAuthorSeq,
        reason: 'the logged head is where the chain stops',
      );

      await acceptHole(
        firstMissingAuthorSeq: firstPeerContentAuthorSeq + 1,
        lastMissingAuthorSeq: firstPeerContentAuthorSeq + 1,
        lastMissingEnvelopeHash: envelopeHash(withheld.withheld),
      );

      // The floor now reaches the end of the hole.
      expect(
        await a.client.effectiveChainHeadSeq(peer.memberId),
        firstPeerContentAuthorSeq + 1,
      );
      final holes = await a.client.acceptedChainHoles(
        authorMemberId: peer.memberId,
      );
      expect(holes.single.firstMissingAuthorSeq, firstPeerContentAuthorSeq + 1);
      expect(holes.single.lastMissingAuthorSeq, firstPeerContentAuthorSeq + 1);

      // The change after the hole turns up. It names the hash the hole carries,
      // so it verifies and applies like any other.
      workspace.server.omitSeqs.remove(withheld.thirdTransportSeq);
      await a.sync();

      expect(await _doc(a, workspace), {'step': 'three'});
      final logged = await a.loggedOps();
      final third = logged.firstWhere(
        (row) => row.authorSeq == firstPeerContentAuthorSeq + 2,
      );
      expect(third.appliedAt, isNotNull);
      expect(third.refusedReason, isNull);
      expect(await a.alarmsByKind(), isEmpty);
      expect(await a.client.quarantined(), isEmpty);
    });

    test('a hole with the wrong hash refuses the change after it', () async {
      final withheld = await withholdTwoChanges();

      await acceptHole(
        firstMissingAuthorSeq: firstPeerContentAuthorSeq + 1,
        lastMissingAuthorSeq: firstPeerContentAuthorSeq + 1,
        // A hash no change ever signed for.
        lastMissingEnvelopeHash:
            Uint8List.fromList(List<int>.filled(prevAuthorHashBytes, 0x7f)),
      );

      workspace.server.omitSeqs.remove(withheld.thirdTransportSeq);
      await a.sync();

      // The change after the hole does not name the hash the hole claims, so it
      // is refused under its own name and nothing is applied.
      final refused = await a.client.quarantined();
      expect(
        refused.single.reason,
        SyncRejectionReason.prevAuthorHashMismatch.code,
      );
      expect(
        (await a.alarmsByKind())[IntegrityAlarmKind.prevAuthorHashMismatch.code],
        isNotNull,
      );
      expect(await _doc(a, workspace), {'step': 'one'});
    });

    test('a hole that does not start at the head bridges nothing', () async {
      final withheld = await withholdTwoChanges();

      // The hole starts one position later than the head's next position, so
      // the walk from the head never reaches it.
      await acceptHole(
        firstMissingAuthorSeq: firstPeerContentAuthorSeq + 2,
        lastMissingAuthorSeq: firstPeerContentAuthorSeq + 2,
        lastMissingEnvelopeHash: envelopeHash(withheld.third),
      );

      expect(
        await a.client.effectiveChainHeadSeq(peer.memberId),
        firstPeerContentAuthorSeq,
        reason: 'a hole that does not start at the head is not a bridge',
      );
    });

    test('a missing change that arrives later fills the hole', () async {
      final withheld = await withholdTwoChanges();
      await acceptHole(
        firstMissingAuthorSeq: firstPeerContentAuthorSeq + 1,
        lastMissingAuthorSeq: firstPeerContentAuthorSeq + 1,
        lastMissingEnvelopeHash: envelopeHash(withheld.withheld),
      );
      workspace.server.omitSeqs.remove(withheld.thirdTransportSeq);
      await a.sync();
      expect(await _doc(a, workspace), {'step': 'three'});

      // The change the hole stands for turns up after all.
      workspace.server.omitSeqs.remove(withheld.withheldTransportSeq);
      await a.client.resetCursorForReplay();
      await a.sync();

      final logged = await a.loggedOps();
      final filled = logged.where(
        (row) => row.authorSeq == firstPeerContentAuthorSeq + 1,
      );
      expect(filled, hasLength(1));
      expect(filled.single.envelope, withheld.withheld);
      expect(
        await _doc(a, workspace),
        {'step': 'three'},
        reason: 'the later change still wins; the filled one is older history',
      );
      expect(await a.alarmsByKind(), isEmpty);
    });

    test('a different change at a position inside the hole is refused', () async {
      final withheld = await withholdTwoChanges();
      await acceptHole(
        firstMissingAuthorSeq: firstPeerContentAuthorSeq + 1,
        lastMissingAuthorSeq: firstPeerContentAuthorSeq + 1,
        lastMissingEnvelopeHash: envelopeHash(withheld.withheld),
      );
      workspace.server.omitSeqs.remove(withheld.thirdTransportSeq);
      await a.sync();

      // A different envelope minted at the position the missing change held.
      final forgedAlternate = await peer.nextEnvelope(
        workspace.workspaceId,
        authorSeq: firstPeerContentAuthorSeq + 1,
        advance: false,
        payloadJson: jsonEncode({
          'collection': _harnessCollection,
          'id': _docId(workspace),
          'fields': {
            'step': {'v': 'forged'},
          },
          'hlc': [workspace.clock.nowMs + 1, 0, memberIdToHex(peer.memberId)],
        }),
      );
      workspace.server.injectUnchecked(workspace.workspaceId, forgedAlternate);
      await a.sync();

      expect(
        (await a.alarmsByKind())[IntegrityAlarmKind.authorChainRewrite.code],
        isNotNull,
      );
      expect(
        (await a.loggedOps())
            .where((row) => row.authorSeq == firstPeerContentAuthorSeq + 1),
        isEmpty,
      );
      expect(await _doc(a, workspace), {'step': 'three'});
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
