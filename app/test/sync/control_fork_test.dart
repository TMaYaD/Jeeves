/// Control fork resolution, and the rebuild it forces (F14e).
///
/// Two control ops naming the same predecessor are a fork. Nothing about that is
/// hostile — mutual owner revocation is exactly this shape — so the answer is
/// *resolution* rather than refusal: **earliest certificate HLC, then lowest
/// author member id**, which is total and order-independent, so every device
/// reaches the same answer whichever order it saw the branches in.
///
/// The certificate HLC and not the op-level one, because a forking author could
/// otherwise move the tie by re-signing an envelope around the same certificate.
///
/// Resolution can change which *content* ops were authorized, and the reduced
/// substrate is a join-semilattice with no per-seq lineage — there is no such
/// thing as rewinding it to a seq. So the only correct move is a full rebuild
/// from the retained log, recomputing the authorization verdict and **nothing
/// else**. This file pins all five properties that makes true:
///
/// 1. the tie-break is on the certificate clock, then the member id;
/// 2. the losing branch *and everything chaining through it* are quarantined;
/// 3. content converges across arrival orders, which is the whole point;
/// 4. the rebuild is idempotent, so recovery cannot oscillate;
/// 5. a reducer-guard refusal is honoured from its persisted `refused_reason`
///    and never re-evaluated — replaying an `hlc_in_the_future` verdict hours
///    later would flip it and diverge two devices.
///
/// And one that is easy to miss until a domain row outlives the branch that put
/// it there: an entity whose every op became refused reduces to nothing, so the
/// replay never names it, and the projector has to be told about it anyway.
@TestOn('!browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/chain_verifier.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/control_payload.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/reducer.dart';
import 'package:uuid/uuid.dart';

import 'harness/author_fixture.dart';
import 'harness/fake_sync_server.dart';
import 'harness/reduced_state.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';

const String _userId = 'fork-user';
const Uuid _uuid = Uuid();

/// A chained Member: its keys, and the session it posts through.
typedef _Member = ({AuthorFixture fixture, FakeSyncServerMemberSession session});

/// One forking branch: the grantee it admits, and the op that admits them.
class _Branch {
  _Branch({
    required this.author,
    required this.grantee,
    required this.grantId,
    required this.envelope,
    required this.seq,
  });

  final _Member author;
  final _Member grantee;
  final String grantId;
  final Uint8List envelope;
  final int seq;

  Uint8List get payloadHash =>
      controlPayloadHash(parseBody(splitEnvelope(envelope).body));
}

/// A `todos` op from [author], so what applies has a *domain row* and not only
/// reduced state — which is what the deleted-entity case needs to observe.
Future<Uint8List> _todoOp(
  SimWorkspace workspace,
  AuthorFixture author,
  String todoId,
  String title, {
  int? wallMs,
}) async {
  workspace.clock.advance(10);
  return author.nextEnvelope(
    workspace.workspaceId,
    payloadJson: jsonEncode({
      'collection': todosCollection,
      'id': todoId,
      'fields': {
        'title': {'v': title},
        'created_at': {'v': encodeInstant(workspace.clock.asDateTime)},
        'user_id': {'v': _userId},
      },
      'hlc': [wallMs ?? workspace.clock.nowMs, 0, memberIdToHex(author.memberId)],
    }),
  );
}

Future<List<Map<String, Object?>>> _todoRows(SimDevice device) =>
    domainRows(device.domain, 'todos', exclude: {'time_spent_minutes'});

Future<Map<String, Map<String, Object?>>> _todos(SimDevice device) =>
    device.registry.register(todosCollection).readAll();

/// The `refused_reason` this device has on record for a transport seq.
Future<String?> _refusedReasonAt(SimDevice device, int seq) async {
  final database = device.database;
  final row = await (database.select(database.opLog)
        ..where((r) =>
            r.workspaceId.equals(device.client.workspaceId) & r.seq.equals(seq)))
      .getSingleOrNull();
  return row?.refusedReason;
}

void main() {
  late SimWorkspace workspace;

  setUp(() async {
    workspace = await SimWorkspace.create(userId: _userId);
  });

  tearDown(() => workspace.close());

  /// Register one Member and take its credential — chained, and nothing more.
  ///
  /// Ungranted on purpose: a branch's authority comes from Root's signature over
  /// its certificate, so its author needs a key the directory knows and no Grant
  /// at all, and its grantee's Grant is the very op under test.
  Future<_Member> chained(int seedOffset) async {
    final fixture = await AuthorFixture.create(
      seed: Uint8List.fromList(List<int>.generate(32, (i) => i + seedOffset)),
    );
    return (
      fixture: fixture,
      session: await workspace.enrolFixture(fixture, grant: false),
    );
  }

  /// Mint one Root-signed owner Grant naming [prevControlHash], and post it.
  ///
  /// The *server* holds no control chain and so resolves no forks — it accepts
  /// both branches, which is precisely why resolution is the client's job and
  /// why both branches are genuinely in the log to be resolved.
  Future<_Branch> branch({
    required _Member author,
    required _Member grantee,
    required Uint8List prevControlHash,
    required int certWallMs,
  }) async {
    final grantId = _uuid.v4();
    final root = await workspace.recoverRoot();
    final envelope = await grantEnvelope(
      device: author.fixture,
      workspaceId: workspace.workspaceId,
      root: root,
      prevControlHash: prevControlHash,
      memberId: grantee.fixture.memberId,
      grantId: grantId,
      wallMs: certWallMs,
    );
    root.drop();
    final seq =
        (await author.session.postOps(workspace.workspaceId, [envelope])).single.seq;
    return _Branch(
      author: author,
      grantee: grantee,
      grantId: grantId,
      envelope: envelope,
      seq: seq,
    );
  }

  group('the tie-break', () {
    test('is the certificate clock, and the loser is quarantined', () async {
      // Two Grants naming one predecessor. The later certificate loses, whichever
      // order the device is served them in — this arm serves the loser first, so
      // resolution has to *unmake* an applied op rather than refuse an arriving
      // one.
      final losingAuthor = await chained(11);
      final losingGrantee = await chained(21);
      final winningAuthor = await chained(31);
      final winningGrantee = await chained(41);
      // Everybody chained and applied *before* the fork is minted: the head the
      // two branches share has to be the head, and a grantee the device has not
      // yet seen registered would be refused as unknown rather than resolved.
      await workspace.syncAll();

      final head = workspace.controlChainHead();
      final loser = await branch(
        author: losingAuthor,
        grantee: losingGrantee,
        prevControlHash: head,
        certWallMs: simulationStartWallMs + 9000,
      );
      final winner = await branch(
        author: winningAuthor,
        grantee: winningGrantee,
        prevControlHash: head,
        certWallMs: simulationStartWallMs + 1000,
      );

      workspace.server.serveOrder = [loser.seq, winner.seq];
      await workspace.a.sync();

      final view = await workspace.a.client.grantsView();
      expect(
        view.grants.containsKey(winner.grantId),
        isTrue,
        reason: 'the earlier certificate HLC wins',
      );
      expect(
        view.grants.containsKey(loser.grantId),
        isFalse,
        reason: 'the losing branch is quarantined, not merely outranked',
      );
      expect(view.liveRoles(winner.grantee.fixture.memberId), {roleOwner});
      expect(view.liveRoles(loser.grantee.fixture.memberId), isEmpty);
      expect(
        (await workspace.a.client.integrityAlarms()).map((alarm) => alarm.kind),
        contains(IntegrityAlarmKind.controlChainFork.code),
        reason: 'a fork is resolved, and still worth surfacing',
      );
    });

    test('falls through to the lowest author member id on an equal clock',
        () async {
      // Two certificates minted at the same instant is not a pathology — one
      // Workspace, one wall clock, two devices. The member id is what makes the
      // order total, so *some* deterministic answer always exists.
      final firstAuthor = await chained(51);
      final firstGrantee = await chained(61);
      final secondAuthor = await chained(71);
      final secondGrantee = await chained(81);
      await workspace.syncAll();

      final head = workspace.controlChainHead();
      final first = await branch(
        author: firstAuthor,
        grantee: firstGrantee,
        prevControlHash: head,
        certWallMs: simulationStartWallMs + 5000,
      );
      final second = await branch(
        author: secondAuthor,
        grantee: secondGrantee,
        prevControlHash: head,
        certWallMs: simulationStartWallMs + 5000,
      );
      // Whose id sorts lower is a property of the fixtures, so the expectation is
      // derived rather than hard-coded: the assertion is about the *rule*.
      final expected = first.author.fixture.memberId
                  .compareTo(second.author.fixture.memberId) <
              0
          ? first
          : second;
      final displaced = expected == first ? second : first;

      workspace.server.serveOrder = [first.seq, second.seq];
      await workspace.a.sync();
      final aView = await workspace.a.client.grantsView();

      // ...and the other arrival order reaches the same answer.
      workspace.server.serveOrder = [second.seq, first.seq];
      await workspace.b.sync();
      final bView = await workspace.b.client.grantsView();

      for (final view in [aView, bView]) {
        expect(view.grants.containsKey(expected.grantId), isTrue);
        expect(view.grants.containsKey(displaced.grantId), isFalse);
      }
    });
  });

  group('the losing branch', () {
    test('takes its dependents with it, and content converges either way',
        () async {
      // The full shape: a fork whose loser already has a Grant chained *through*
      // it, and content authored under every one of the three Grants. Two devices
      // are served the same six ops in two orders and must agree on all of it.
      //
      // Seqs are assigned in post order, so they are fixed before any of this is
      // served — the authorization verdict is positional against those numbers,
      // and reordering the page does not move them.
      final losingAuthor = await chained(91);
      final losingGrantee = await chained(101);
      final dependentAuthor = await chained(111);
      final dependentGrantee = await chained(121);
      final winningAuthor = await chained(131);
      final winningGrantee = await chained(141);
      await workspace.syncAll();

      final head = workspace.controlChainHead();
      final loser = await branch(
        author: losingAuthor,
        grantee: losingGrantee,
        prevControlHash: head,
        certWallMs: simulationStartWallMs + 8000,
      );
      // Chained to the loser: if the loser goes, this has no predecessor left.
      final dependent = await branch(
        author: dependentAuthor,
        grantee: dependentGrantee,
        prevControlHash: loser.payloadHash,
        certWallMs: simulationStartWallMs + 8500,
      );
      final winner = await branch(
        author: winningAuthor,
        grantee: winningGrantee,
        prevControlHash: head,
        certWallMs: simulationStartWallMs + 2000,
      );

      final loserTodo = preferenceEntityId(workspace.workspaceId, 'from-loser');
      final dependentTodo = preferenceEntityId(workspace.workspaceId, 'from-dependent');
      final winnerTodo = preferenceEntityId(workspace.workspaceId, 'from-winner');
      final loserContent =
          (await losingGrantee.session.postOps(workspace.workspaceId, [
        await _todoOp(
            workspace, losingGrantee.fixture, loserTodo, 'authored on the loser'),
      ])).single.seq;
      final dependentContent =
          (await dependentGrantee.session.postOps(workspace.workspaceId, [
        await _todoOp(workspace, dependentGrantee.fixture, dependentTodo,
            'authored on the dependent'),
      ])).single.seq;
      final winnerContent =
          (await winningGrantee.session.postOps(workspace.workspaceId, [
        await _todoOp(
            workspace, winningGrantee.fixture, winnerTodo, 'authored on the winner'),
      ])).single.seq;

      // Device A: the loser and its dependent land, their content applies, and
      // the winner arrives last — so resolution has to unmake three applied
      // things and re-verdict content that was legitimately applied at the time.
      workspace.server.serveOrder = [
        loser.seq,
        dependent.seq,
        loserContent,
        dependentContent,
        winnerContent,
        winner.seq,
      ];
      await workspace.a.sync();

      // Device B: the winner first, so both other branches are refused on
      // arrival and no rebuild is needed at all. Same log, opposite order.
      workspace.server.serveOrder = [
        winner.seq,
        loser.seq,
        dependent.seq,
        loserContent,
        dependentContent,
        winnerContent,
      ];
      await workspace.b.sync();

      for (final device in [workspace.a, workspace.b]) {
        final view = await device.client.grantsView();
        expect(
          view.grants.keys.toSet(),
          isNot(contains(loser.grantId)),
          reason: '${device.label}: the loser is quarantined',
        );
        expect(
          view.grants.keys.toSet(),
          isNot(contains(dependent.grantId)),
          reason: '${device.label}: and so is everything chaining through it',
        );
        expect(view.grants.containsKey(winner.grantId), isTrue, reason: device.label);
        expect(
          (await _todos(device)).keys.toSet(),
          {winnerTodo},
          reason: '${device.label}: only the winning branch authorized anything',
        );
      }

      // Byte-identical, which is the claim that matters: convergence is not
      // "both ended up sensible", it is one canonical state.
      expect(
        await canonicalReducedState(workspace.a.database),
        await canonicalReducedState(workspace.b.database),
      );
      expect(await _todoRows(workspace.a), await _todoRows(workspace.b));

      // The rebuild is idempotent: running it again from the same winning chain
      // changes nothing, so a device that re-resolves cannot oscillate.
      final before = await canonicalReducedState(workspace.a.database);
      final rowsBefore = await _todoRows(workspace.a);
      await workspace.a.client.projector!
          .project(await workspace.a.client.rebuildFromOpLog());
      expect(await canonicalReducedState(workspace.a.database), before);
      expect(await _todoRows(workspace.a), rowsBefore);
    });

    test('has its domain rows removed, not merely its reduced state', () async {
      // The defect this case exists for: an entity whose every op became refused
      // reduces to *nothing*, so the replay never names it — and a projector told
      // only about what re-applied leaves the row standing as the last visible
      // trace of a quarantined branch. The row has to go, and only the rebuild
      // knows it existed.
      final losingAuthor = await chained(151);
      final losingGrantee = await chained(161);
      final winningAuthor = await chained(171);
      final winningGrantee = await chained(181);
      await workspace.syncAll();

      final head = workspace.controlChainHead();
      final loser = await branch(
        author: losingAuthor,
        grantee: losingGrantee,
        prevControlHash: head,
        certWallMs: simulationStartWallMs + 7000,
      );
      final doomed = preferenceEntityId(workspace.workspaceId, 'doomed-todo');
      final content = (await losingGrantee.session.postOps(workspace.workspaceId, [
        await _todoOp(
            workspace, losingGrantee.fixture, doomed, 'on the losing branch'),
      ])).single.seq;
      // Posted last, so the two syncs below are two genuine pull windows rather
      // than one page a `serveOrder` merely shuffled: the cursor moves past the
      // content before the rival is reachable at all.
      final winner = await branch(
        author: winningAuthor,
        grantee: winningGrantee,
        prevControlHash: head,
        certWallMs: simulationStartWallMs + 3000,
      );
      expect(winner.seq, greaterThan(content));

      // First the loser and its content, so the row genuinely exists.
      workspace.server.omitSeqs.add(winner.seq);
      await workspace.a.sync();
      expect(
        (await _todoRows(workspace.a)).map((row) => row['id']),
        contains(doomed),
        reason: 'the op was authorized when it arrived, so it projected',
      );
      expect(await _refusedReasonAt(workspace.a, content), isNull);

      // Then the winner, which resolves the fork against the branch that
      // authorized it. Nothing else about the log changed.
      workspace.server.omitSeqs.remove(winner.seq);
      await workspace.a.sync();
      expect((await workspace.a.client.grantsView()).grants.containsKey(loser.grantId),
          isFalse);

      expect(await _refusedReasonAt(workspace.a, content),
          SyncRejectionReason.noLiveGrant.code);
      expect((await _todos(workspace.a)).containsKey(doomed), isFalse);
      expect(
        (await _todoRows(workspace.a)).map((row) => row['id']),
        isNot(contains(doomed)),
        reason: 'the rebuild has to surface an un-reduced entity to the projector',
      );
    });
  });

  test('a persisted reducer-guard refusal survives the rebuild verbatim',
      () async {
    // `refused_reason` is a *record*, not a cache of a re-runnable decision. An
    // `hlc_in_the_future` op refused at noon must still be refused at midnight,
    // even though the guard would now pass — otherwise a rebuild is a second
    // chance, and two devices that rebuilt at different times diverge.
    final peer = await AuthorFixture.create(
      seed: Uint8List.fromList(List<int>.generate(32, (i) => i + 191)),
    );
    final session = await workspace.enrolFixture(peer);
    await workspace.a.sync();

    final futureTodo = preferenceEntityId(workspace.workspaceId, 'from-the-future');
    final beyondTheBound = workspace.clock.nowMs + defaultFutureSkewBoundMs * 2;
    final refused = (await session.postOps(workspace.workspaceId, [
      await _todoOp(workspace, peer, futureTodo, 'dated too far ahead',
          wallMs: beyondTheBound),
    ])).single.seq;
    await workspace.a.sync();

    expect(await _refusedReasonAt(workspace.a, refused),
        SyncRejectionReason.hlcInTheFuture.code);
    expect((await _todos(workspace.a)).containsKey(futureTodo), isFalse);

    // Time passes, so the guard that fired would no longer fire.
    workspace.clock.advance(defaultFutureSkewBoundMs * 4);
    await workspace.a.client.projector!
        .project(await workspace.a.client.rebuildFromOpLog());

    expect(
      await _refusedReasonAt(workspace.a, refused),
      SyncRejectionReason.hlcInTheFuture.code,
      reason: 'the record stands; the clock is not re-consulted',
    );
    expect(
      (await _todos(workspace.a)).containsKey(futureTodo),
      isFalse,
      reason: 'a replay must not be a second chance at a guard',
    );
    expect(
      (await _todoRows(workspace.a)).map((row) => row['id']),
      isNot(contains(futureTodo)),
    );
  });

  test('an op the corrected view newly authorizes is applied and un-refused',
      () async {
    // The other direction, and the reason the refusal is *cleared* rather than
    // left behind: a content op refused for `no_live_grant` because its Grant had
    // not arrived yet is authorized once it has, and a row still claiming the old
    // verdict would be a lie about what this device applied.
    final grantAuthor = await chained(201);
    final grantee = await chained(211);
    final rivalAuthor = await chained(221);
    final rivalGrantee = await chained(231);
    await workspace.syncAll();

    final head = workspace.controlChainHead();
    final grant = await branch(
      author: grantAuthor,
      grantee: grantee,
      prevControlHash: head,
      certWallMs: simulationStartWallMs + 4000,
    );
    final rival = await branch(
      author: rivalAuthor,
      grantee: rivalGrantee,
      prevControlHash: head,
      certWallMs: simulationStartWallMs + 6000,
    );

    final todoId = preferenceEntityId(workspace.workspaceId, 'late-authorized');
    final content = (await grantee.session.postOps(workspace.workspaceId, [
      await _todoOp(workspace, grantee.fixture, todoId, 'authorized in arrears'),
    ])).single.seq;

    // The rival lands first and the content arrives with no Grant behind it, so
    // it is refused. Then the winning Grant arrives, forks the rival out, and the
    // rebuild re-asks the question it could not answer the first time.
    workspace.server.serveOrder = [rival.seq, content, grant.seq];
    await workspace.a.sync();

    expect(await _refusedReasonAt(workspace.a, content), isNull);
    expect(await _todos(workspace.a), containsPair(todoId, isNotNull));
    expect(
      (await _todoRows(workspace.a)).map((row) => row['id']),
      contains(todoId),
    );
  });
}
