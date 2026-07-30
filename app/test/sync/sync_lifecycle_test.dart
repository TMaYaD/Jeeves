/// The lifecycle over a real `SyncStack` and the fake server.
///
/// The E2E in `sync_signup_flow_test.dart` asserts the journey; this asserts the
/// parts of it a journey cannot reach:
///
/// * **The relaunch.** The member credential is memory-only by design, so a
///   process death leaves an enrolled device with its keys, its whole log and no
///   transport. Re-minting one is a proof-of-possession exchange against the
///   server, which is why this tier exists — a device that only ever enrolled
///   in-process would never exercise it, and AC-4's "resumes on next sync" would
///   hold within one process lifetime only.
/// * **The two states that must do nothing.** Un-enrolled and half-founded are
///   different causes with the same required non-effect, and the second one is
///   the one a boolean would get wrong.
/// * **What does and does not hold the marker open.** A transport failure does;
///   a refusal does not.
@TestOn('!browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/sync/enrolment_state.dart';
import 'package:jeeves/sync/envelope.dart' show opClassContent;
import 'package:jeeves/sync/initial_upload.dart' show InitialUploadReport;
import 'package:jeeves/sync/initial_upload_plan.dart' show uploadRefused;
import 'package:jeeves/sync/sync_lifecycle.dart';
import 'package:jeeves/sync/sync_transport.dart';

import '../test_helpers.dart';
import 'harness/fake_sync_server.dart';
import 'harness/sim_device.dart' show DeviceLink, FakeClock;
import 'harness/sim_workspace.dart' show simulationStartWallMs;
import 'harness/stack_phone.dart';

const String _userId = 'lifecycle-user';

/// A [UserTransport] with two scripted knobs, staged against the production path
/// rather than described in a comment:
///
/// * [failRegisterMemberTimes] fails `POST /members` — the ceremony's
///   keys-stored-but-nothing-founded crash window.
/// * [holdMemberChallenge] parks the proof-of-possession round trip, which is the
///   only way to be *inside* an activation's step 2 when a sign-out lands.
class _ScriptedUserTransport implements UserTransport {
  _ScriptedUserTransport(this._inner);

  final UserTransport _inner;
  int failRegisterMemberTimes = 0;

  /// Armed by a test to park the exchange; completed by it to let it through.
  Completer<void>? holdMemberChallenge;
  final Completer<void> _parked = Completer<void>();

  /// Fires when a caller has actually arrived at the armed gate, so no test has
  /// to guess how many event-loop turns reaching step 2 takes.
  Future<void> get memberChallengeParked => _parked.future;

  @override
  Future<MemberRecord> registerMember({
    required String memberId,
    required Uint8List signPk,
    required Uint8List kexPk,
  }) async {
    if (failRegisterMemberTimes > 0) {
      failRegisterMemberTimes--;
      throw const SyncTransportException(500, 'member registration exploded');
    }
    return _inner.registerMember(memberId: memberId, signPk: signPk, kexPk: kexPk);
  }

  @override
  Future<RecoveryEscrowRecord?> fetchRecoveryEscrow(String workspaceId) =>
      _inner.fetchRecoveryEscrow(workspaceId);

  @override
  Future<RecoveryEscrowRecord> putRecoveryEscrow(
    String workspaceId,
    RecoveryEscrowRecord record,
  ) =>
      _inner.putRecoveryEscrow(workspaceId, record);

  @override
  Future<Uint8List> requestMemberChallenge(String memberId) async {
    final gate = holdMemberChallenge;
    if (gate != null) {
      if (!_parked.isCompleted) _parked.complete();
      await gate.future;
    }
    return _inner.requestMemberChallenge(memberId);
  }

  @override
  Future<SyncTransport> completeMemberChallenge({
    required String memberId,
    required Uint8List nonce,
    required Uint8List signature,
  }) =>
      _inner.completeMemberChallenge(
        memberId: memberId,
        nonce: nonce,
        signature: signature,
      );
}

/// A [SyncTransport] whose *socket* refuses to open while armed. Only the signal
/// side is scripted: posting and pulling stay real, so an activation reaches step
/// 6 normally and fails exactly there.
class _UnsubscribableSignalTransport implements SyncTransport {
  _UnsubscribableSignalTransport(this._inner);

  final SyncTransport _inner;
  bool refuseSubscribe = false;

  @override
  Stream<void> newSeqSignals(String workspaceId) {
    if (refuseSubscribe) {
      throw const SyncTransportException.unreachable('no socket for you');
    }
    return _inner.newSeqSignals(workspaceId);
  }

  @override
  Future<List<OpAppendResult>> postOps(
    String workspaceId,
    List<Uint8List> envelopes,
  ) =>
      _inner.postOps(workspaceId, envelopes);

  @override
  Future<PullPage> pullOps(
    String workspaceId, {
    required int since,
    required int limit,
  }) =>
      _inner.pullOps(workspaceId, since: since, limit: limit);
}

int _contentOpCount(FakeSyncServer server) => server.storedOps
    .where((op) => op.header?.opClass == opClassContent)
    .length;

void main() {
  setUpAll(configureSqliteForTests);

  late FakeSyncServer server;
  late FakeClock clock;

  setUp(() {
    server = FakeSyncServer();
    clock = FakeClock(simulationStartWallMs);
  });

  Future<StackPhone> phone({
    bool fileBacked = false,
    UserTransport Function(DeviceLink)? userTransport,
  }) async {
    final built = await StackPhone.create(
      label: 'A',
      userId: _userId,
      server: server,
      clock: clock,
      fileBacked: fileBacked,
      userTransport: userTransport,
    );
    addTearDown(built.close);
    return built;
  }

  Future<void> seedOneOutcome(StackPhone device, {required String id}) async {
    clock.advance(1000);
    await device.domain.todoDao.insertOutcome(
      id: id,
      title: 'Write the thing',
      userId: _userId,
      now: clock.asDateTime,
    );
  }

  test('an un-enrolled device activates nothing, before or after the decision',
      () async {
    final device = await phone();
    // A write before activation is buffered while the seam is undecided; the
    // `notEnrolled` decision must discard it, not author it.
    await seedOneOutcome(device, id: '11111111-1111-4111-8111-111111111111');

    expect(await device.activate(), SyncActivation.notEnrolled);
    expect(device.capture.isBound, isFalse);

    // A write *after* the decision authors nothing either: the seam is settled
    // silent, not merely unbound-by-timing.
    await seedOneOutcome(device, id: '1a1a1a1a-1a1a-4a1a-8a1a-1a1a1a1a1a1a');
    expect(device.capture.isBound, isFalse);

    expect(_contentOpCount(server), 0);
    expect(
      await InitialUploadMarkerStore(device.syncStore).read(_userId),
      isNull,
    );
    expect(server.signalSubscriberCount(device.stack.defaultClient.workspaceId), 0);
  });

  test('a half-founded device activates nothing either', () async {
    final faults = <_ScriptedUserTransport>[];
    final device = await phone(userTransport: (link) {
      final faulty = _ScriptedUserTransport(link);
      faults.add(faulty);
      return faulty;
    });
    await seedOneOutcome(device, id: '22222222-2222-4222-8222-222222222222');

    // The escrow is written and Root pinned, the keypairs are stored, and then
    // registration explodes: keys present, no Workspace founded.
    faults.single.failRegisterMemberTimes = 1;
    await expectLater(device.enrolAsFirstDevice(), throwsA(isA<Exception>()));
    expect(
      (await device.stack.readEnrolmentStatus()).state,
      EnrolmentState.foundingIncomplete,
    );

    expect(await device.activate(), SyncActivation.foundingIncomplete);
    expect(device.capture.isBound, isFalse);
    expect(_contentOpCount(server), 0);
    expect(
      await InitialUploadMarkerStore(device.syncStore).read(_userId),
      isNull,
    );
  });

  test('a relaunched device re-mints its member credential and resumes',
      () async {
    final device = await phone(fileBacked: true);
    await seedOneOutcome(device, id: '33333333-3333-4333-8333-333333333333');
    await device.enrolAsFirstDevice();

    // The POST lands, the response is lost: every capture succeeded, the flush
    // did not, and the marker stays unset.
    device.link.dropPostResponse = true;
    expect(await device.activate(), SyncActivation.uploadIncomplete);
    expect(
      await InitialUploadMarkerStore(device.syncStore).read(_userId),
      isNull,
    );

    // Process death. A fresh stack over the same files: identity out of the key
    // store, log intact, and **no transport** — `SyncStack.assemble` cannot
    // restore one.
    await device.relaunch();
    expect(device.stack.defaultClient.isEnrolled, isFalse,
        reason: 'a relaunch must not resurrect a memory-only credential');
    expect(
      (await device.stack.readEnrolmentStatus()).state,
      EnrolmentState.enrolled,
      reason: 'the store, not the credential, says whether a device is enrolled',
    );

    // One `activate()` and the device is syncing again: proof of possession over
    // the stored keys, then the resume.
    expect(await device.activate(), SyncActivation.active);
    expect(device.stack.defaultClient.isEnrolled, isTrue);
    // The propagation `SyncStack`'s factory owns, which is the wiring only a real
    // stack exercises: the preferences client got the credential too.
    expect((await device.preferencesClient).isEnrolled, isTrue);

    final marker = await InitialUploadMarkerStore(device.syncStore).read(_userId);
    expect(marker, isNotNull);
    final report = jsonDecode(marker!.lastReportJson!) as Map<String, Object?>;
    expect(report['authored_op_count'], 0);
    expect(report['skipped_entity_count'], report['planned_entity_count']);
    expect(_contentOpCount(server), report['planned_entity_count']);
  });

  test('a refused entity is recorded and does not hold the marker open',
      () async {
    final device = await phone();
    // A row whose id is not a canonical UUID. The plan carries it — the id is the
    // legacy row's own, by rule — and `capture()` refuses it at the author's own
    // call site (#573), so it never reaches the outbox.
    await seedOneOutcome(device, id: 'NOT-A-UUID');
    await seedOneOutcome(device, id: '44444444-4444-4444-8444-444444444444');
    await device.enrolAsFirstDevice();

    expect(await device.activate(), SyncActivation.active);

    final marker = await InitialUploadMarkerStore(device.syncStore).read(_userId);
    expect(marker, isNotNull,
        reason: 'a permanent data anomaly must not block the marker for ever');
    final report = jsonDecode(marker!.lastReportJson!) as Map<String, Object?>;
    expect(report['refused_entity_count'], 1);
    expect(
      (report['anomalies']! as List).single,
      containsPair('kind', uploadRefused),
    );
    // The healthy row still landed, and the queue is drained.
    expect((await device.stack.defaultClient.health()).pendingOpCount, 0);
  });

  test('a sign-out mid-activation abandons the rest of the sequence', () async {
    final transports = <_ScriptedUserTransport>[];
    final device = await phone(fileBacked: true, userTransport: (link) {
      final scripted = _ScriptedUserTransport(link);
      transports.add(scripted);
      return scripted;
    });
    await seedOneOutcome(device, id: '55555555-5555-4555-8555-555555555555');
    await device.enrolAsFirstDevice();

    // Relaunch first, so the activation has a proof-of-possession exchange to be
    // parked in: an in-process credential would make step 2 a no-op.
    await device.relaunch();
    final scripted = transports.single;
    scripted.holdMemberChallenge = Completer<void>();

    // The provider starts an activation un-awaited and disposes on the next
    // sign-out. This is that pair, in that order, with the round trip in between.
    final activation = device.activate();
    await scripted.memberChallengeParked;
    await device.lifecycle!.deactivate();
    scripted.holdMemberChallenge!.complete();

    expect(await activation, SyncActivation.deactivated);
    expect(device.capture.isBound, isFalse,
        reason: 'the process-wide seam must not be bound to a signed-out account');

    // The seam ended silent, not merely unbound: a write after the sign-out
    // authors nothing, and no re-bind resurrects the abandoned account's clients.
    await seedOneOutcome(device, id: '5a5a5a5a-5a5a-4a5a-8a5a-5a5a5a5a5a5a');
    expect(device.capture.isBound, isFalse);

    expect(
      await InitialUploadMarkerStore(device.syncStore).read(_userId),
      isNull,
    );
    expect(_contentOpCount(server), 0);
    for (final workspaceId in device.stack.workspaceIds) {
      expect(server.signalSubscriberCount(workspaceId), 0,
          reason: 'no socket may outlive the session that opened it');
    }
  });

  test('a listener that cannot start is not retained, so the next activation '
      'retries', () async {
    final device = await phone();
    await seedOneOutcome(device, id: '66666666-6666-4666-8666-666666666666');
    await device.enrolAsFirstDevice();
    final signals = _UnsubscribableSignalTransport(device.link)
      ..refuseSubscribe = true;

    await expectLater(
      device.activate(signalTransport: signals),
      throwsA(isA<SyncTransportException>()),
    );
    for (final workspaceId in device.stack.workspaceIds) {
      expect(server.signalSubscriberCount(workspaceId), 0);
    }

    signals.refuseSubscribe = false;
    // The same lifecycle instance, which is the whole point: `_listeners` is its
    // state, and a retained dead entry would make step 6 a no-op for ever.
    expect(await device.activate(), SyncActivation.active);
    for (final workspaceId in device.stack.workspaceIds) {
      expect(server.signalSubscriberCount(workspaceId), 1,
          reason: 'a failed startup must not spend the retry step 6 promises');
    }
  });

  test('a cold-start write authors before the PoP round trip returns, and so '
      'does one made mid-activation', () async {
    final transports = <_ScriptedUserTransport>[];
    final device = await phone(fileBacked: true, userTransport: (link) {
      final scripted = _ScriptedUserTransport(link);
      transports.add(scripted);
      return scripted;
    });
    await device.enrolAsFirstDevice();

    // Process death: a fresh stack, no in-memory credential, the seam undecided.
    await device.relaunch();
    final scripted = transports.single;
    scripted.holdMemberChallenge = Completer<void>();

    // A DAO write on the very first turn of the cold start, before activate().
    // Buffered by the undecided seam.
    await seedOneOutcome(device, id: '77777777-7777-4777-8777-777777777777');

    // Start activation and park it at the proof-of-possession round trip.
    final activation = device.activate();
    await scripted.memberChallengeParked;

    // Bind happened before the network step, and drained the buffered op: it is
    // already authored while the PoP is still parked.
    expect(device.capture.isBound, isTrue);
    final pendingAfterBind =
        (await device.stack.defaultClient.health()).pendingOpCount;
    expect(pendingAfterBind, greaterThan(0),
        reason: 'the buffered write authored at bind, ahead of the PoP');

    // A write made mid-activation — after bind, PoP still parked — authors at
    // once too, rather than being lost or re-buffered.
    await seedOneOutcome(device, id: '78787878-7878-4787-8787-787878787878');
    expect((await device.stack.defaultClient.health()).pendingOpCount,
        greaterThan(pendingAfterBind),
        reason: 'a live write while bound authors immediately');

    // Release the PoP: the device finishes activating and both ops converge.
    scripted.holdMemberChallenge!.complete();
    expect(await activation, SyncActivation.active);
    expect((await device.stack.defaultClient.health()).pendingOpCount, 0,
        reason: 'the queue drained to the server');
    expect(_contentOpCount(server), greaterThanOrEqualTo(2));
  });

  test('an offline enrolled relaunch returns syncFailed, and the write it '
      'queues converges when the device comes back online', () async {
    final device = await phone(fileBacked: true);
    await device.enrolAsFirstDevice();
    expect(await device.activate(), SyncActivation.active);
    final contentBefore = _contentOpCount(server);

    // Relaunch with no network: the PoP cannot complete.
    await device.relaunch();
    device.goOffline();

    // Classified as syncFailed rather than escaping unclassified — and capture
    // is bound, so the offline device queues rather than dropping.
    expect(await device.activate(), SyncActivation.syncFailed);
    expect(device.capture.isBound, isTrue);

    await seedOneOutcome(device, id: '99999999-9999-4999-8999-999999999999');
    expect((await device.stack.defaultClient.health()).pendingOpCount,
        greaterThan(0),
        reason: 'the write queued behind a bound-but-offline seam');

    // Back online, the next activation attaches the transport and drains.
    device.goOnline();
    expect(await device.activate(), SyncActivation.active);
    expect((await device.stack.defaultClient.health()).pendingOpCount, 0);
    expect(_contentOpCount(server), greaterThan(contentBefore),
        reason: 'the offline write reached the server on reconnect');
  });

  test('the marker is per account, not per device', () async {
    final device = await phone();
    final markers = InitialUploadMarkerStore(device.syncStore);
    await markers.markComplete(
      userId: 'someone-else',
      completedAtUtcMs: clock.nowMs,
      report: const InitialUploadReport(
        plannedEntityCount: 0,
        authoredOpCount: 0,
        skippedEntityCount: 0,
        reassertedEntityCount: 0,
        refusedEntityCount: 0,
        anomalies: [],
      ),
    );
    expect(await markers.isComplete('someone-else'), isTrue);
    expect(
      await markers.isComplete(_userId),
      isFalse,
      reason: 'a device re-enrolled under another account walks again',
    );
  });
}
