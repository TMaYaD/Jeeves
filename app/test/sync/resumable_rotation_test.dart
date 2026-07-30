/// Key rotation's wrap-set publish, made resumable across a crash (#617).
///
/// A rotation publishes an epoch's wrap set in two steps that are not atomic:
/// `flushOutbox()` materialises the signed `rotate` on the server, and `publish`
/// uploads the wraps and remembers the key. A crash between them used to strand the
/// epoch permanently — nobody held `K_{w,N+1}`, and a second `prepare` could never
/// reproduce the digest the `rotate` had already committed to. This suite drives
/// that crash through the *production* path — a transport decorator that fails the
/// wraps PUT, and a real [StackPhone.relaunch] process death — and asserts the
/// device finishes the publish on the next launch with no operator action.
///
/// Nothing here calls the resume hook by hand: the failure is injected into the
/// PUT, the phone is relaunched, and the ordinary lifecycle sync is what completes
/// the ceremony. That is the whole point — the recovery has to ride the path a real
/// device takes, not a test-only entry point.
@TestOn('!browser')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/control_payload.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/ids.dart'
    show defaultWorkspaceId, jeevesWorkspaceNamespace, userPreferencesWorkspaceId;
import 'package:jeeves/sync/key_wraps.dart' show MemberKeyWrap;
import 'package:jeeves/sync/sync_transport.dart';
import 'package:uuid/uuid.dart';

import '../test_helpers.dart';
import 'harness/fake_sync_server.dart';
import 'harness/reduced_state.dart';
import 'harness/sim_device.dart' show DeviceLink, FakeClock, SimDevice;
import 'harness/sim_workspace.dart' show simulationStartWallMs;
import 'harness/stack_phone.dart';

const String _userId = 'resumable-rotation-user';
const String _collection = 'harness_docs';

/// Entity ids are canonical UUIDs on the wire, so a readable label is hashed into
/// one deterministically rather than used as one.
String _entityId(String label) => const Uuid().v5(jeevesWorkspaceNamespace, label);

/// Where a rotation's wraps PUT is made to fail. Shared between the [UserTransport]
/// decorator and the [SyncTransport] it hands back, because the PUT lives on the
/// member surface (`client.transport`) while the seam a test wraps is the User one.
class _RotationFaults {
  /// The next `putKeyWraps` for this Workspace throws *before* the server sees it:
  /// the flush landed, the wraps did not. One-shot — it clears as it fires, so the
  /// resume's own re-PUT goes through.
  String? failPublishForWorkspaceId;

  /// The next `putKeyWraps` for this Workspace reaches the server and *then* loses
  /// its response: the "server stored it, the client never learned" crash the
  /// idempotent re-PUT exists for. One-shot.
  String? dropPublishResponseForWorkspaceId;
}

/// Wraps [DeviceLink] so the member transport it returns is itself decorated —
/// the only way to fault `putKeyWraps`, which the client reaches through the
/// transport `completeMemberChallenge` hands back, not through this seam directly.
class _FaultyUserTransport implements UserTransport {
  _FaultyUserTransport(this._inner, this._faults);

  final UserTransport _inner;
  final _RotationFaults _faults;

  @override
  Future<SyncTransport> completeMemberChallenge({
    required String memberId,
    required Uint8List nonce,
    required Uint8List signature,
  }) async =>
      _FaultySyncTransport(
        await _inner.completeMemberChallenge(
          memberId: memberId,
          nonce: nonce,
          signature: signature,
        ),
        _faults,
      );

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
    String workspaceId,
    RecoveryEscrowRecord record,
  ) =>
      _inner.putRecoveryEscrow(workspaceId, record);

  @override
  Future<Uint8List> requestMemberChallenge(String memberId) =>
      _inner.requestMemberChallenge(memberId);
}

/// The member transport, with `putKeyWraps` scriptable and everything else real.
class _FaultySyncTransport implements SyncTransport {
  _FaultySyncTransport(this._inner, this._faults);

  final SyncTransport _inner;
  final _RotationFaults _faults;

  @override
  Future<List<KeyWrapRecord>> putKeyWraps(
    String workspaceId, {
    required int epoch,
    required List<MemberKeyWrap> wraps,
    required Uint8List escrowWrap,
    Uint8List? keyWrapDigest,
  }) async {
    if (_faults.failPublishForWorkspaceId == workspaceId) {
      _faults.failPublishForWorkspaceId = null;
      throw const SyncTransportException.unreachable(
        'the wraps PUT was lost before the server saw it',
      );
    }
    if (_faults.dropPublishResponseForWorkspaceId == workspaceId) {
      _faults.dropPublishResponseForWorkspaceId = null;
      // The server stores the set; only the response is lost, so a byte-identical
      // re-PUT on resume must be a 200 acknowledgement rather than a conflict.
      await _inner.putKeyWraps(
        workspaceId,
        epoch: epoch,
        wraps: wraps,
        escrowWrap: escrowWrap,
        keyWrapDigest: keyWrapDigest,
      );
      throw const SyncTransportException.unreachable(
        'the wraps PUT landed, but its response was lost',
      );
    }
    return _inner.putKeyWraps(
      workspaceId,
      epoch: epoch,
      wraps: wraps,
      escrowWrap: escrowWrap,
      keyWrapDigest: keyWrapDigest,
    );
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
    bool includeCompacted = false,
  }) =>
      _inner.pullOps(
        workspaceId,
        since: since,
        limit: limit,
        includeCompacted: includeCompacted,
      );

  @override
  Future<List<KeyWrapRecord>> fetchMyKeyWraps(String workspaceId) =>
      _inner.fetchMyKeyWraps(workspaceId);

  @override
  Future<List<EpochKeyRecord>> fetchEpochKeys(String workspaceId) =>
      _inner.fetchEpochKeys(workspaceId);

  @override
  Stream<void> newSeqSignals(String workspaceId) =>
      _inner.newSeqSignals(workspaceId);
}

/// Every content op the server holds for [workspaceId].
List<StoredOp> _contentOps(FakeSyncServer server, String workspaceId) => [
      for (final op in server.storedOps)
        if (op.workspaceId == workspaceId && op.header?.opClass == opClassContent) op,
    ];

/// How many `rotate` control ops the server holds for [workspaceId] — what proves a
/// resumed Workspace was *not* rotated a second time.
int _rotateCount(FakeSyncServer server, String workspaceId) => server.storedOps
    .where((op) =>
        op.workspaceId == workspaceId && op.header?.opClass == opClassControl)
    .where((op) =>
        ControlPayload.decode(parseBody(splitEnvelope(op.envelope).body)).controlType ==
        controlTypeRotate)
    .length;

void main() {
  setUpAll(configureSqliteForTests);

  final gtd = defaultWorkspaceId(_userId);
  final prefs = userPreferencesWorkspaceId(_userId);

  late FakeSyncServer server;
  late FakeClock clock;
  late _RotationFaults faults;

  setUp(() {
    server = FakeSyncServer();
    clock = FakeClock(simulationStartWallMs);
    faults = _RotationFaults();
  });

  Future<StackPhone> owner() async {
    final phone = await StackPhone.create(
      label: 'A',
      userId: _userId,
      server: server,
      clock: clock,
      fileBacked: true,
      userTransport: (link) => _FaultyUserTransport(link, faults),
    );
    addTearDown(phone.close);
    return phone;
  }

  String memberIdOf(StackPhone phone) => phone.stack.defaultClient.identity.memberId;

  test('a publish lost between flush and PUT resumes on the next launch', () async {
    final a = await owner();
    final outcome = await a.enrolAsFirstDevice();

    // Turn encryption on, but lose the gtd wraps PUT the instant the rotate has
    // already been flushed. The rotate is now on the server; K_{w,1} is nowhere.
    faults.failPublishForWorkspaceId = gtd;
    await expectLater(
      a.stack.enrolment.turnOnEncryption(passphrase: outcome.passphrase),
      throwsA(isA<SyncTransportException>()),
    );

    expect(await a.workspaceKeys.keyFor(gtd, 1), isNull,
        reason: 'the failed PUT never remembered the key: nobody holds K_{w,1}');
    expect((await a.pendingWrapSets.read(gtd)).map((set) => set.epoch), [1],
        reason: 'the prepared set was made durable before the flush');
    expect(server.keyedEpochs(gtd), contains(1),
        reason: 'the rotate itself materialised — the crash was after the flush');
    expect(server.keyWrapRecipients(gtd, 1), isEmpty,
        reason: 'but no wrap was ever published');

    // Process death, then launch. Nothing by hand: the lifecycle mints a fresh
    // member credential and syncs, and the pull tail completes the publish.
    await a.relaunch();
    await a.activate();

    expect(await a.stack.defaultClient.epochFloor(), 1);
    expect(await a.workspaceKeys.keyFor(gtd, 1), isNotNull,
        reason: 'the resume re-PUT the set and remembered K_{w,1} (AC-2)');
    expect(await a.pendingWrapSets.read(gtd), isEmpty,
        reason: 'the record is removed once the publish is confirmed (AC-7)');
    expect(server.keyWrapRecipients(gtd, 1), contains(memberIdOf(a)),
        reason: 'the wrap set is now on the server for this device');

    // AC-3: it authors aead_v1 at the very epoch it stranded and recovered.
    await a.stack.defaultClient.capture(
      collection: _collection,
      entityId: _entityId('after-resume'),
      fields: {'title': 'only readable under K_w_1'},
    );
    await a.stack.defaultClient.sync();
    final content = _contentOps(server, gtd).single;
    expect(content.header!.suite, suiteAeadV1);
    expect(content.header!.keyEpoch, 1);
  });

  test('a partial two-Workspace rotation resumes only the Workspace it left undone',
      () async {
    final a = await owner();
    final outcome = await a.enrolAsFirstDevice();

    // gtd rotates first and all the way through; the crash lands on the *second*
    // Workspace's publish.
    faults.failPublishForWorkspaceId = prefs;
    await expectLater(
      a.stack.enrolment.turnOnEncryption(passphrase: outcome.passphrase),
      throwsA(isA<SyncTransportException>()),
    );

    // The first Workspace is done: key held, record gone, wraps published.
    expect(await a.workspaceKeys.keyFor(gtd, 1), isNotNull);
    expect(await a.pendingWrapSets.read(gtd), isEmpty);
    expect(server.keyWrapRecipients(gtd, 1), contains(memberIdOf(a)));
    final gtdRotatesBefore = _rotateCount(server, gtd);
    expect(gtdRotatesBefore, 1);

    // The second is the incomplete one: a durable record, the key unheld, the
    // rotate materialised but no wrap published.
    expect(await a.workspaceKeys.keyFor(prefs, 1), isNull);
    expect((await a.pendingWrapSets.read(prefs)).map((set) => set.epoch), [1]);
    expect(server.keyedEpochs(prefs), contains(1));
    expect(server.keyWrapRecipients(prefs, 1), isEmpty);

    await a.relaunch();
    await a.activate();

    // prefs finished...
    expect(await a.workspaceKeys.keyFor(prefs, 1), isNotNull,
        reason: 'the resume finished the incomplete Workspace (AC-5)');
    expect(await a.pendingWrapSets.read(prefs), isEmpty);
    expect(server.keyWrapRecipients(prefs, 1), contains(memberIdOf(a)));

    // ...and gtd was not rotated again: it had no pending record to resume.
    expect(_rotateCount(server, gtd), gtdRotatesBefore,
        reason: 'the succeeded Workspace is left exactly as it was (AC-5)');
    expect(await a.workspaceKeys.keyFor(gtd, 1), isNotNull);
  });

  test('a publish whose response was lost re-PUTs idempotently on resume', () async {
    final a = await owner();
    final outcome = await a.enrolAsFirstDevice();

    faults.dropPublishResponseForWorkspaceId = gtd;
    await expectLater(
      a.stack.enrolment.turnOnEncryption(passphrase: outcome.passphrase),
      throwsA(isA<SyncTransportException>()),
    );

    // The server already holds the set; the client just never learned it did.
    expect(server.keyWrapRecipients(gtd, 1), contains(memberIdOf(a)),
        reason: 'the PUT landed — only the response was lost');
    expect(await a.workspaceKeys.keyFor(gtd, 1), isNull,
        reason: 'so the key was never remembered');
    expect((await a.pendingWrapSets.read(gtd)).map((set) => set.epoch), [1]);

    await a.relaunch();
    await a.activate();

    // The resume re-PUT the byte-identical set — a 200 acknowledgement, not a
    // conflict — and finished (AC-4).
    expect(await a.workspaceKeys.keyFor(gtd, 1), isNotNull);
    expect(await a.pendingWrapSets.read(gtd), isEmpty);
    expect(server.keyWrapRecipients(gtd, 1), contains(memberIdOf(a)));
  });

  test('a record whose epoch is already held is discarded, not re-PUT for ever',
      () async {
    final a = await owner();
    final outcome = await a.enrolAsFirstDevice();

    faults.failPublishForWorkspaceId = gtd;
    await expectLater(
      a.stack.enrolment.turnOnEncryption(passphrase: outcome.passphrase),
      throwsA(isA<SyncTransportException>()),
    );
    final pending = (await a.pendingWrapSets.read(gtd)).single;
    expect(pending.epoch, 1);

    // The key arrives by another route before the resume runs — an escrow adoption
    // remembers keys exactly like this — so the epoch is held while the record
    // still stands. That is the crash-between-remember-and-drop state no transport
    // fault can land on, reconstructed here.
    await a.workspaceKeys.remember(gtd, 1, pending.workspaceKey);
    final recipientsBefore = server.keyWrapRecipients(gtd, 1);

    // An ordinary pull — the production trigger — must discard the now-redundant
    // record rather than re-PUT it for ever (AC-7).
    await a.stack.defaultClient.pull();

    expect(await a.pendingWrapSets.read(gtd), isEmpty,
        reason: 'held key + standing record is discarded');
    expect(server.keyWrapRecipients(gtd, 1), recipientsBefore,
        reason: 'and nothing was re-PUT: the discard skips the upload entirely');
  });

  test('a peer decrypts content the owner authored after resuming the publish',
      () async {
    final a = await owner();
    final outcome = await a.enrolAsFirstDevice();

    // A genuine second device of the same account, enrolled on the passphrase
    // alone. It holds a live owner Grant, so the owner will wrap epoch 1 to it.
    final b = await SimDevice.create(
      label: 'B',
      userId: _userId,
      server: server,
      clock: clock,
      passphrase: outcome.passphrase,
    );
    addTearDown(b.close);

    // The owner learns B's registration and Grant before it rotates, or it could
    // not wrap to B.
    await a.stack.defaultClient.pull();

    faults.failPublishForWorkspaceId = gtd;
    await expectLater(
      a.stack.enrolment.turnOnEncryption(passphrase: outcome.passphrase),
      throwsA(isA<SyncTransportException>()),
    );

    await a.relaunch();
    await a.activate();

    // The owner, having resumed, authors content under the recovered key.
    await a.stack.defaultClient.capture(
      collection: _collection,
      entityId: _entityId('interim'),
      fields: {'title': 'authored once the epoch was rescued'},
    );
    await a.stack.defaultClient.sync();

    // The peer pulls, and the wrap the resume published is what lets it read.
    await b.sync();
    expect(await b.workspaceKeys.read(gtd), contains(1),
        reason: 'the resumed publish wrapped epoch 1 to this peer too (AC-3)');
    expect(server.keyWrapRecipients(gtd, 1), contains(b.identity.memberId));
    expect(await canonicalReducedState(b.database), contains(_entityId('interim')),
        reason: 'the peer decrypted content the owner authored after the resume');
    final health = await b.client.health();
    expect(health.alarmKinds, isEmpty,
        reason: 'a wrap that arrived, however late, accuses nobody');
    expect(await b.client.orphanedGrants(), isEmpty);
  });
}
