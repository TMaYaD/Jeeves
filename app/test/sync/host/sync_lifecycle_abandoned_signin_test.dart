/// A sign-in abandoned by a sign-out, while its signal listeners are starting,
/// must not undo what a newer account stored or bound.
///
/// Listener start-up is the one place the race window is long enough to hit in
/// real use: it waits on a network pull. These tests park that pull, sign out,
/// optionally sign a second account in, and release the pull.
@TestOn('!browser')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/host/hosted_capture.dart' show readClockIdentity;
import 'package:jeeves/sync/envelope.dart' show opClassContent;
import 'package:jeeves/sync/key_wraps.dart' show MemberKeyWrap;
import 'package:jeeves/sync/sync_lifecycle.dart';
import 'package:jeeves/sync/sync_transport.dart';

import '../../test_helpers.dart';
import '../harness/fake_sync_server.dart';
import '../harness/sim_device.dart' show FakeClock;
import '../harness/sim_workspace.dart' show simulationStartWallMs;
import '../harness/stack_phone.dart';

const String _userA = 'abandoned-user-a';
const String _userB = 'abandoned-user-b';
const String _outcomeId = '55555555-5555-4555-8555-555555555555';

/// Shared by the two decorators below. The signal side arms it when a listener
/// subscribes (only a listener does), and the member side then parks the next
/// pull — the listener's start-up sync.
class _ListenerPullGate {
  bool armed = false;
  final Completer<void> release = Completer<void>();
  final Completer<void> _parked = Completer<void>();

  Future<void> get parked => _parked.future;

  Future<void> passPull() async {
    if (!armed) return;
    if (!_parked.isCompleted) _parked.complete();
    await release.future;
  }
}

/// Wraps the member transport the Workspace clients pull through.
class _GatedMemberTransport implements SyncTransport {
  _GatedMemberTransport(this._inner, this._gate);

  final SyncTransport _inner;
  final _ListenerPullGate _gate;

  @override
  Stream<void> newSeqSignals(String workspaceId) =>
      _inner.newSeqSignals(workspaceId);

  @override
  Future<List<OpAppendResult>> postOps(
          String workspaceId, List<Uint8List> envelopes) =>
      _inner.postOps(workspaceId, envelopes);

  @override
  Future<PullPage> pullOps(
    String workspaceId, {
    required int since,
    required int limit,
    bool includeCompacted = false,
  }) async {
    await _gate.passPull();
    return _inner.pullOps(workspaceId,
        since: since, limit: limit, includeCompacted: includeCompacted);
  }

  @override
  Future<List<KeyWrapRecord>> putKeyWraps(
    String workspaceId, {
    required int epoch,
    required List<MemberKeyWrap> wraps,
    required Uint8List escrowWrap,
    Uint8List? keyWrapDigest,
  }) =>
      _inner.putKeyWraps(workspaceId,
          epoch: epoch,
          wraps: wraps,
          escrowWrap: escrowWrap,
          keyWrapDigest: keyWrapDigest);

  @override
  Future<List<KeyWrapRecord>> fetchMyKeyWraps(String workspaceId) =>
      _inner.fetchMyKeyWraps(workspaceId);

  @override
  Future<List<EpochKeyRecord>> fetchEpochKeys(String workspaceId) =>
      _inner.fetchEpochKeys(workspaceId);
}

class _GatedUserTransport implements UserTransport {
  _GatedUserTransport(this._inner, this._gate);

  final UserTransport _inner;
  final _ListenerPullGate _gate;

  @override
  Future<MemberRecord> registerMember({
    required String memberId,
    required Uint8List signPk,
    required Uint8List kexPk,
  }) =>
      _inner.registerMember(memberId: memberId, signPk: signPk, kexPk: kexPk);

  @override
  Future<RecoveryEscrowRecord?> fetchRecoveryEscrow(String workspaceId) =>
      _inner.fetchRecoveryEscrow(workspaceId);

  @override
  Future<RecoveryEscrowRecord> putRecoveryEscrow(
          String workspaceId, RecoveryEscrowRecord record) =>
      _inner.putRecoveryEscrow(workspaceId, record);

  @override
  Future<Uint8List> requestMemberChallenge(String memberId) =>
      _inner.requestMemberChallenge(memberId);

  @override
  Future<SyncTransport> completeMemberChallenge({
    required String memberId,
    required Uint8List nonce,
    required Uint8List signature,
  }) async =>
      _GatedMemberTransport(
        await _inner.completeMemberChallenge(
            memberId: memberId, nonce: nonce, signature: signature),
        _gate,
      );
}

/// The socket side: only a listener subscribes, so a subscribe means the
/// activation has reached listener start-up and the next pull is the one to park.
class _ArmingSignalTransport extends _GatedMemberTransport {
  _ArmingSignalTransport(super.inner, super.gate);

  @override
  Stream<void> newSeqSignals(String workspaceId) {
    _gate.armed = true;
    return super.newSeqSignals(workspaceId);
  }
}

int _contentOpCount(FakeSyncServer server) => server.storedOps
    .where((op) => op.header?.opClass == opClassContent)
    .length;

void main() {
  setUpAll(configureSqliteForTests);

  late FakeSyncServer server;
  late FakeClock clock;
  late _ListenerPullGate gate;

  setUp(() {
    server = FakeSyncServer();
    clock = FakeClock(simulationStartWallMs);
    gate = _ListenerPullGate();
  });

  Future<StackPhone> hostedPhone() async {
    final built = await StackPhone.create(
      label: 'A',
      userId: _userA,
      server: server,
      clock: clock,
      hosted: true,
      userTransport: (link) => _GatedUserTransport(link, gate),
    );
    addTearDown(built.close);
    return built;
  }

  Future<String?> storedMemberId(StackPhone phone) async =>
      (await readClockIdentity(phone.domain)).enrolledMemberIdHex;

  Future<String> writeOutcomeClockMember(StackPhone phone) async {
    clock.advance(1000);
    await phone.domain.todoDao.insertOutcome(
      id: _outcomeId,
      title: 'Write the thing',
      userId: _userA,
      now: clock.asDateTime,
    );
    final row = await phone.syncStore.customSelect(
      "SELECT member_id_hex FROM field_clocks "
      "WHERE entity_id = ? AND field = 'title'",
      variables: [Variable<String>(_outcomeId)],
    ).getSingle();
    return row.read<String>('member_id_hex');
  }

  test('an abandoned activation with no newer account leaves no member id behind',
      () async {
    final phone = await hostedPhone();
    await phone.enrolAsFirstDevice();

    final activation =
        phone.activate(signalTransport: _ArmingSignalTransport(phone.link, gate));
    await gate.parked;
    await phone.lifecycle!.deactivate();
    gate.release.complete();

    expect(await activation, SyncActivation.deactivated);
    expect(await storedMemberId(phone), isNull);
    expect(await writeOutcomeClockMember(phone), phone.host!.deviceNodeId);
    expect(phone.capture.isBound, isFalse);
    for (final workspaceId in phone.stack.workspaceIds) {
      expect(server.signalSubscriberCount(workspaceId), 0);
    }
  });

  test("a newer account's member id and capture survive an abandoned activation",
      () async {
    final phone = await hostedPhone();
    await phone.enrolAsFirstDevice();
    final second = await phone.addAccount(userId: _userB, server: server);
    await second.stack.enrolment.enrolFirstDevice();
    final memberB = second.stack.identity.memberIdHex;

    // A starts up and parks in listener start-up; A signs out; B signs in.
    final activationA =
        phone.activate(signalTransport: _ArmingSignalTransport(phone.link, gate));
    await gate.parked;
    await phone.lifecycle!.deactivate();
    expect(await second.lifecycle.activate(), SyncActivation.active);
    addTearDown(second.lifecycle.deactivate);

    // A's abandoned attempt resumes.
    gate.release.complete();
    expect(await activationA, SyncActivation.deactivated);

    expect(await storedMemberId(phone), memberB,
        reason: "the abandoned attempt cleared the newer account's member id");
    expect(phone.capture.isBound, isTrue,
        reason: "the abandoned attempt unbound the newer account's capture");
    final authoredBefore = _contentOpCount(server);
    expect(await writeOutcomeClockMember(phone), memberB);
    await second.stack.defaultClient.flushOutbox();
    expect(_contentOpCount(server), greaterThan(authoredBefore),
        reason: "the newer account's write was not authored");
    for (final workspaceId in second.stack.workspaceIds) {
      expect(server.signalSubscriberCount(workspaceId), 1);
    }
    for (final workspaceId in phone.stack.workspaceIds) {
      expect(server.signalSubscriberCount(workspaceId), 0,
          reason: "the abandoned attempt's listeners were left running");
    }
  });
}
