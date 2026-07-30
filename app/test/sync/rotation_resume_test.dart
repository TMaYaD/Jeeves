/// A key rotation whose `publish` is interrupted between the flush and the PUT,
/// and the resume that heals it — staged through the production path, never by
/// calling the resume hook directly (AC-6).
///
/// The gap #617 closes: `WorkspaceKeyCeremony.publish` uploads the wrap set and
/// only then remembers the key. A failure of the PUT after the `rotate` has already
/// been flushed leaves the epoch stranded — the server has raised every device's
/// floor, and nobody holds `K_{w,toEpoch}`. It is unreconstructable, because a
/// second `prepare` draws fresh entropy and cannot reproduce the committed digest.
/// The prepared set is persisted before the rotate is authored, and a passphrase-
/// free resume re-publishes it from the next ceremony, the pull tail, or launch.
///
/// The fault is injected through [StackPhone]'s `UserTransport` decorator seam: the
/// member `SyncTransport` returned from `completeMemberChallenge` is wrapped so its
/// `putKeyWraps` fails (or commits-then-fails) on demand, exactly as a real server
/// or a dropped connection would. `relaunch()` is a real process death, and the
/// pending-rotation store outlives it the way the platform keychain would.
@TestOn('!browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/envelope.dart'
    show authorKeyIdBytes, opClassContent, suiteAeadV1, workspaceKeyBytes;
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/key_ceremony.dart';
import 'package:jeeves/sync/key_wraps.dart'
    show
        MemberKeyWrap,
        epochKeyEscrowWrapBytes,
        keyWrapBytes,
        keyWrapDigestBytes;
import 'package:jeeves/sync/pending_rotation_store.dart';
import 'package:jeeves/sync/signal_listener.dart';
import 'package:jeeves/sync/sync_lifecycle.dart' show SyncActivation;
import 'package:jeeves/sync/sync_transport.dart';
import 'package:uuid/uuid.dart';

import '../test_helpers.dart';
import 'harness/fake_sync_server.dart';
import 'harness/reduced_state.dart';
import 'harness/sim_device.dart' show FakeClock;
import 'harness/sim_workspace.dart' show simulationStartWallMs;
import 'harness/stack_phone.dart';

const String _userId = 'rotation-resume-user';
const String _collection = 'harness_docs';

String _entityId(String label) => const Uuid().v5(jeevesWorkspaceNamespace, label);

/// The scripted knobs a test arms, shared across every member transport this phone
/// mints — including the one a `relaunch()` re-mints — so a fault set before the
/// crash still governs the transport the resume publishes through.
class _RotationFaults {
  /// workspaceId -> how many more `putKeyWraps` to fail *before* the server commits.
  final Map<String, int> failBeforeCommit = {};

  /// workspaceId -> how many more `putKeyWraps` to forward (so the set commits
  /// server-side) and *then* throw on, so `publish` never reaches `remember`. This
  /// is the AC-4 shape: the set is written, the device does not hold the key, and
  /// the resume must re-PUT byte-identical and get a 200.
  final Map<String, int> commitThenThrow = {};

  int putKeyWrapsCallCount = 0;
}

/// Fails `putKeyWraps` per [_RotationFaults]; everything else is the real thing.
class _ScriptedKeyWrapsTransport implements SyncTransport {
  _ScriptedKeyWrapsTransport(this._inner, this._faults);

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
    _faults.putKeyWrapsCallCount++;
    final commitThenThrow = _faults.commitThenThrow[workspaceId] ?? 0;
    if (commitThenThrow > 0) {
      _faults.commitThenThrow[workspaceId] = commitThenThrow - 1;
      await _inner.putKeyWraps(
        workspaceId,
        epoch: epoch,
        wraps: wraps,
        escrowWrap: escrowWrap,
        keyWrapDigest: keyWrapDigest,
      );
      throw const SyncTransportException(500, 'wraps committed, acknowledgement lost');
    }
    final failBeforeCommit = _faults.failBeforeCommit[workspaceId] ?? 0;
    if (failBeforeCommit > 0) {
      _faults.failBeforeCommit[workspaceId] = failBeforeCommit - 1;
      throw const SyncTransportException(500, 'putKeyWraps exploded before commit');
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
          String workspaceId, List<Uint8List> envelopes) =>
      _inner.postOps(workspaceId, envelopes);

  @override
  Future<PullPage> pullOps(
    String workspaceId, {
    required int since,
    required int limit,
    bool includeCompacted = false,
  }) =>
      _inner.pullOps(workspaceId,
          since: since, limit: limit, includeCompacted: includeCompacted);

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

/// A [UserTransport] whose minted member transport carries the scripted fault.
class _FaultyUserTransport implements UserTransport {
  _FaultyUserTransport(this._inner, this.faults);

  final UserTransport _inner;
  final _RotationFaults faults;

  @override
  Future<SyncTransport> completeMemberChallenge({
    required String memberId,
    required Uint8List nonce,
    required Uint8List signature,
  }) async =>
      _ScriptedKeyWrapsTransport(
        await _inner.completeMemberChallenge(
            memberId: memberId, nonce: nonce, signature: signature),
        faults,
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
          String workspaceId, RecoveryEscrowRecord record) =>
      _inner.putRecoveryEscrow(workspaceId, record);

  @override
  Future<Uint8List> requestMemberChallenge(String memberId) =>
      _inner.requestMemberChallenge(memberId);
}

/// Every content op the server holds for [workspaceId].
List<StoredOp> _contentOps(FakeSyncServer server, String workspaceId) => [
      for (final op in server.storedOps)
        if (op.workspaceId == workspaceId &&
            op.header?.opClass == opClassContent)
          op,
    ];

void main() {
  setUpAll(configureSqliteForTests);

  late FakeSyncServer server;
  late FakeClock clock;

  setUp(() {
    server = FakeSyncServer();
    clock = FakeClock(simulationStartWallMs);
  });

  Future<(StackPhone, _RotationFaults)> phone({
    required String label,
    bool fileBacked = false,
  }) async {
    final faults = _RotationFaults();
    final built = await StackPhone.create(
      label: label,
      userId: _userId,
      server: server,
      clock: clock,
      fileBacked: fileBacked,
      userTransport: (link) => _FaultyUserTransport(link, faults),
    );
    addTearDown(built.close);
    return (built, faults);
  }

  String defaultWs() => defaultWorkspaceId(_userId);
  String prefsWs() => userPreferencesWorkspaceId(_userId);

  test('a rotation stranded between flush and publish resumes on launch, and a '
      'peer decrypts content authored after the resume', () async {
    final (a, faults) = await phone(label: 'A', fileBacked: true);
    final outcome = await a.enrolAsFirstDevice();
    final passphrase = outcome.passphrase;

    // Fail the default Workspace's publish once: the rotate flushes, then the PUT
    // explodes. `turnOnEncryption` rotates the default Workspace first, so this
    // strands it and never reaches the preferences one.
    faults.failBeforeCommit[defaultWs()] = 1;
    await expectLater(
      a.stack.enrolment.turnOnEncryption(passphrase: passphrase),
      throwsA(isA<SyncTransportException>()),
    );

    // The stranded state: the record is durable, the key is not held, and the
    // floor has not moved locally (the rotate was flushed but never pulled back).
    expect(await a.pendingRotations.read(defaultWs()), contains(1));
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNull);
    expect(await a.stack.defaultClient.epochFloor(), 0);

    // Process death, then launch. The launch resume re-publishes the persisted set
    // with no passphrase and remembers the key.
    await a.relaunch();
    expect(await a.activate(), SyncActivation.active);

    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNotNull,
        reason: 'the resume remembered K_{w,1}');
    expect(await a.pendingRotations.read(defaultWs()), isEmpty,
        reason: 'a completed record is removed (AC-7)');
    expect(await a.stack.defaultClient.epochFloor(), 1);

    // Now at the keyed epoch, the device authors aead_v1.
    const marker = 'resumed-then-authored-617';
    await a.stack.defaultClient.capture(
      collection: _collection,
      entityId: _entityId('after-resume'),
      fields: {'title': marker},
    );
    await a.stack.defaultClient.sync();
    final authored = _contentOps(server, defaultWs()).single;
    expect(authored.header!.suite, suiteAeadV1);
    expect(authored.header!.keyEpoch, 1);

    // A second device recovers K_{w,1} from the escrow with the passphrase alone,
    // and decrypts the content authored in the interim window.
    final (b, _) = await phone(label: 'B');
    await b.enrolWithPassphrase(passphrase);
    await b.stack.defaultClient.sync();
    expect(await b.workspaceKeys.keyFor(defaultWs(), 1), isNotNull);
    final reduced = await canonicalReducedState(b.syncStore);
    expect(reduced, contains(_entityId('after-resume')));
    expect(reduced, contains(marker),
        reason: 'the peer decrypted the interim content, marker and all');
  });

  test('a stranded rotation resumes on the next pull, through the onSyncComplete '
      'seam and without a relaunch', () async {
    final (a, faults) = await phone(label: 'A');
    final outcome = await a.enrolAsFirstDevice();

    faults.failBeforeCommit[defaultWs()] = 1;
    await expectLater(
      a.stack.enrolment.turnOnEncryption(passphrase: outcome.passphrase),
      throwsA(isA<SyncTransportException>()),
    );
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNull);

    // A pull through the production listener, with the seam wired exactly as
    // `SyncLifecycle._startListeners` wires it. `start()` runs one sync and then
    // invokes `onSyncComplete`, so awaiting it heals the epoch with no relaunch.
    final listener = SignalListener(
      client: a.stack.defaultClient,
      transport: a.link,
      delay: a.link.timers.delay,
      onSyncComplete: () =>
          a.stack.enrolment.resumePendingRotations(workspaceId: defaultWs()),
    );
    addTearDown(listener.dispose);
    await listener.start();

    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNotNull,
        reason: 'the pull tail re-published the stranded set');
    expect(await a.pendingRotations.read(defaultWs()), isEmpty);
  });

  test('a resume racing a set already written is a byte-identical 200, not an '
      'error (AC-4)', () async {
    final (a, faults) = await phone(label: 'A', fileBacked: true);
    final outcome = await a.enrolAsFirstDevice();

    // Commit the set server-side, then lose the acknowledgement: the wraps are
    // written, the device never remembered the key, and the record stands.
    faults.commitThenThrow[defaultWs()] = 1;
    await expectLater(
      a.stack.enrolment.turnOnEncryption(passphrase: outcome.passphrase),
      throwsA(isA<SyncTransportException>()),
    );
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNull);
    expect(await a.pendingRotations.read(defaultWs()), contains(1));

    // The resume re-PUTs the same bytes. A different set would be refused
    // `keywrap_already_written`; a byte-identical one returns 200 and completes.
    await a.relaunch();
    expect(await a.activate(), SyncActivation.active);
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNotNull);
    expect(await a.pendingRotations.read(defaultWs()), isEmpty);
  });

  test('a rotation interrupted partway through the two Workspaces leaves only the '
      'incomplete one, and the next ceremony finishes just it (AC-5)', () async {
    final (a, faults) = await phone(label: 'A');
    final outcome = await a.enrolAsFirstDevice();
    final passphrase = outcome.passphrase;

    // Fail only the *second* Workspace's publish: the default Workspace rotates
    // fully, the preferences one is stranded.
    faults.failBeforeCommit[prefsWs()] = 1;
    await expectLater(
      a.stack.enrolment.turnOnEncryption(passphrase: passphrase),
      throwsA(isA<SyncTransportException>()),
    );

    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNotNull,
        reason: 'the first Workspace completed');
    expect(await a.pendingRotations.read(defaultWs()), isEmpty,
        reason: 'its record was removed on success');
    expect(await a.workspaceKeys.keyFor(prefsWs(), 1), isNull);
    expect(await a.pendingRotations.read(prefsWs()), contains(1),
        reason: 'the incomplete Workspace kept its record');

    // The next ceremony resumes first. It finishes the preferences Workspace and
    // does not re-rotate the default one (which would land it at epoch 2).
    final epochs = await a.stack.enrolment.rotateWorkspaceKeys(passphrase: passphrase);
    expect(await a.pendingRotations.read(prefsWs()), isEmpty);
    expect(await a.workspaceKeys.keyFor(prefsWs(), 1), isNotNull,
        reason: 'the stranded prefs epoch 1 was published by the resume');
    // The fresh rotation then took both Workspaces to epoch 2.
    expect(epochs[defaultWs()], 2);
    expect(epochs[prefsWs()], 2);
  });

  test('a stale record whose epoch is already held is discarded, not retried '
      '(AC-7)', () async {
    final (a, _) = await phone(label: 'A');
    final passphrase = (await a.enrolAsFirstDevice()).passphrase;

    // A clean rotation: the device holds K_{w,1} and the record is already gone.
    await a.stack.enrolment.turnOnEncryption(passphrase: passphrase);
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNotNull);

    // Re-inject a record for an epoch already held — the crash-between-publish-and-
    // remove state. Its contents are never published: the discard path short-
    // circuits on the held key, so a length-valid placeholder set is enough.
    await a.pendingRotations.put(defaultWs(), _placeholderSet(1));
    expect(await a.pendingRotations.read(defaultWs()), contains(1));

    await a.stack.enrolment.resumePendingRotations(workspaceId: defaultWs());
    expect(await a.pendingRotations.read(defaultWs()), isEmpty,
        reason: 'a record for an already-held epoch is dropped, never re-published');
  });

  test('the EpochKeySet codec round-trips byte-for-byte through JSON', () async {
    final set = EpochKeySet(
      epoch: 7,
      workspaceKey: _filled(workspaceKeyBytes, 0x11),
      memberWraps: [
        MemberKeyWrap(
          memberId: const Uuid().v4(),
          kexKeyId: _filled(authorKeyIdBytes, 0x22),
          wrap: _filled(keyWrapBytes, 0x33),
        ),
        MemberKeyWrap(
          memberId: const Uuid().v4(),
          kexKeyId: _filled(authorKeyIdBytes, 0x44),
          wrap: _filled(keyWrapBytes, 0x55),
        ),
      ],
      escrowWrap: _filled(epochKeyEscrowWrapBytes, 0x66),
      digest: _filled(keyWrapDigestBytes, 0x77),
    );

    // Through the same `jsonEncode`/`jsonDecode` the SecureStorage store uses.
    final round = decodePendingEpochKeySet(
      jsonDecode(jsonEncode(encodePendingEpochKeySet(set))) as Map<String, Object?>,
    );

    expect(round.epoch, set.epoch);
    expect(round.workspaceKey, set.workspaceKey);
    expect(round.escrowWrap, set.escrowWrap);
    expect(round.digest, set.digest);
    expect(round.memberWraps, hasLength(2));
    for (var i = 0; i < set.memberWraps.length; i++) {
      expect(round.memberWraps[i].memberId, set.memberWraps[i].memberId);
      expect(round.memberWraps[i].kexKeyId, set.memberWraps[i].kexKeyId);
      expect(round.memberWraps[i].wrap, set.memberWraps[i].wrap);
    }
  });
}

Uint8List _filled(int length, int byte) =>
    Uint8List.fromList(List<int>.filled(length, byte));

/// A length-valid [EpochKeySet] for a path that never publishes it.
EpochKeySet _placeholderSet(int epoch) => EpochKeySet(
      epoch: epoch,
      workspaceKey: _filled(workspaceKeyBytes, 0),
      memberWraps: const [],
      escrowWrap: _filled(epochKeyEscrowWrapBytes, 0),
      digest: _filled(keyWrapDigestBytes, 0),
    );
