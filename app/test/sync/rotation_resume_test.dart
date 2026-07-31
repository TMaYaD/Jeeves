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

import 'dart:async';
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
import 'package:jeeves/sync/chain_verifier.dart' show IntegrityAlarmKind;
import 'package:jeeves/sync/pending_rotation_store.dart';
import 'package:jeeves/sync/rotation_resume_refusal.dart'
    show maxUnclassifiedResumeRefusalAttempts;
import 'package:jeeves/sync/signal_listener.dart';
import 'package:jeeves/sync/sync_database.dart' show IntegrityAlarmRow;
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
  /// is the AC-4 shape: the set is written server-side but the device never
  /// remembered the key and the record stands. On recovery the ordinary pull
  /// re-learns that committed wrap (`refreshEpochKeys`, no passphrase), so the
  /// resume finds the key already held and discards the stale record — the
  /// byte-identical-200 server idempotency (`#590`) is the belt-and-braces backstop
  /// for the resume-before-pull ordering, not the route this scenario takes.
  final Map<String, int> commitThenThrow = {};

  /// workspaceId -> the exact refusal `putKeyWraps` throws instead of forwarding.
  ///
  /// One knob for every scripted server verdict: the AC-6 `keywrap_digest_mismatch`,
  /// an unknown code, a 500. Distinct from [failBeforeCommit], which is a generic
  /// 500 and says nothing about *which* rule the server applied — and "which rule"
  /// is the whole subject of #627.
  final Map<String, _ScriptedRefusal> refuseWith = {};

  /// The same, for `postOps` — the resume's *other* server call, whose refusals are
  /// not attributable to any one pending record.
  final Map<String, _ScriptedRefusal> refusePostOpsWith = {};

  int putKeyWrapsCallCount = 0;
  int postOpsCallCount = 0;
}

/// A refusal to throw, and how many more times to throw it.
class _ScriptedRefusal {
  _ScriptedRefusal(this.refusal, {this.remaining = -1});

  final SyncTransportException refusal;

  /// Negative for "every time" — what a deterministic server verdict looks like.
  int remaining;

  /// The refusal, or null once the script is spent.
  SyncTransportException? take() {
    if (remaining == 0) return null;
    if (remaining > 0) remaining--;
    return refusal;
  }
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
    final scripted = _faults.refuseWith[workspaceId]?.take();
    if (scripted != null) throw scripted;
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
    String workspaceId,
    List<Uint8List> envelopes,
  ) async {
    _faults.postOpsCallCount++;
    final scripted = _faults.refusePostOpsWith[workspaceId]?.take();
    if (scripted != null) throw scripted;
    return _inner.postOps(workspaceId, envelopes);
  }

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

/// A signal socket that opens and then stays quiet: no initial poke, no keepalive,
/// no close.
///
/// Not a fault — a perfectly ordinary socket with nothing to say. It exists so a
/// test can drive an exact number of `SignalListener.start()` pulls: over the real
/// socket the subscribe ack *is* a poke, which queues a second sync behind the
/// first, and a test counting resume passes would double every number.
class _QuietSignalTransport implements SyncTransport {
  _QuietSignalTransport(this._inner);

  final SyncTransport _inner;

  @override
  Stream<void> newSeqSignals(String workspaceId) =>
      StreamController<void>().stream;

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
    PendingRotationStore Function(PendingRotationStore)? pendingRotationStore,
  }) async {
    final faults = _RotationFaults();
    final built = await StackPhone.create(
      label: label,
      userId: _userId,
      server: server,
      clock: clock,
      fileBacked: fileBacked,
      userTransport: (link) => _FaultyUserTransport(link, faults),
      pendingRotationStore: pendingRotationStore,
    );
    addTearDown(built.close);
    return (built, faults);
  }

  String defaultWs() => defaultWorkspaceId(_userId);
  String prefsWs() => userPreferencesWorkspaceId(_userId);

  /// Strand a rotation of the default Workspace: the rotate flushes, the PUT
  /// explodes, and the prepared record for epoch 1 stands with no key held.
  ///
  /// The state every #627 scenario starts from, reached through the production
  /// ceremony rather than by writing a record by hand.
  Future<void> strandDefaultWorkspaceRotation(
    StackPhone a,
    _RotationFaults faults,
    String passphrase,
  ) async {
    faults.failBeforeCommit[defaultWs()] = 1;
    await expectLater(
      a.stack.enrolment.turnOnEncryption(passphrase: passphrase),
      throwsA(isA<SyncTransportException>()),
    );
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNull);
    expect(await a.pendingRotations.read(defaultWs()), contains(1));
  }

  /// Drive exactly [count] pulls through the seam `SyncLifecycle._startListeners`
  /// wires — `SignalListener.onSyncComplete` — rather than calling the resume hook
  /// directly.
  ///
  /// `start()` runs one sync and then invokes the hook, and the listener guards it,
  /// so this is exactly the production shape: a resume failure is never a pull
  /// failure.
  ///
  /// The signal socket is the quiet one ([_QuietSignalTransport]) so the count is
  /// exact. Over the ordinary socket a subscribe's initial poke queues a *second*
  /// sync behind the first, which is correct behaviour and useless for a test whose
  /// subject is how many times the resume ran.
  Future<void> pullsThroughListener(StackPhone a, {required int count}) async {
    for (var i = 0; i < count; i++) {
      final listener = SignalListener(
        client: a.stack.defaultClient,
        transport: _QuietSignalTransport(a.link),
        delay: a.link.timers.delay,
        onSyncComplete: () =>
            a.stack.enrolment.resumePendingRotations(workspaceId: defaultWs()),
      );
      await listener.start();
      await listener.dispose();
    }
  }

  /// The one `epoch_key_set_unpublishable` row, or null.
  Future<IntegrityAlarmRow?> alarmOfKind(StackPhone a, IntegrityAlarmKind kind) async {
    final matching = [
      for (final alarm in await a.stack.defaultClient.integrityAlarms())
        if (alarm.kind == kind.code) alarm,
    ];
    return matching.isEmpty ? null : matching.single;
  }

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

  test('a committed-but-unacked set is re-learned by the relaunch pull, and the '
      'resume discards the stale record without a second PUT (AC-4, discard '
      'ordering)', () async {
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

    // On relaunch the ordinary pull runs first (step 4), before the resume (step 5),
    // and re-learns the committed wrap via `refreshEpochKeys` — so the resume finds
    // the key already held and discards the stale record. No second PUT.
    await a.relaunch();
    expect(await a.activate(), SyncActivation.active);
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNotNull);
    expect(await a.pendingRotations.read(defaultWs()), isEmpty);
    expect(faults.putKeyWrapsCallCount, 1,
        reason: 'the set was PUT exactly once — the ceremony commit that lost its '
            'ack. The relaunch pull re-learns that committed wrap before the resume '
            'runs, so the resume discards rather than issuing a redundant second PUT');
  });

  test('a ceremony-triggered resume that runs before any pull re-PUTs the '
      'committed set byte-identical and gets a 200 (AC-4, re-PUT ordering)',
      () async {
    final (a, faults) = await phone(label: 'A', fileBacked: true);
    final outcome = await a.enrolAsFirstDevice();

    // Same stranded state — wraps committed server-side, key not held, record
    // standing — but reached inside a live process. `_rotateOne`'s only pull is the
    // one *before* the rotate, so nothing has re-learned epoch 1's wrap yet.
    faults.commitThenThrow[defaultWs()] = 1;
    await expectLater(
      a.stack.enrolment.turnOnEncryption(passphrase: outcome.passphrase),
      throwsA(isA<SyncTransportException>()),
    );
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNull);
    expect(await a.pendingRotations.read(defaultWs()), contains(1));
    expect(faults.putKeyWrapsCallCount, 1);

    // Resume directly, with no intervening pull — the ceremony-path ordering that
    // `rotateWorkspaceKeys` takes (it calls `resumePendingRotations` at the top,
    // before `_rotateOne` pulls). With no `refreshEpochKeys` ahead of it, the resume
    // cannot discard: it must re-PUT the committed set. The server accepts the
    // byte-identical bytes as a 200 (`#590` idempotency) and the key is remembered.
    await a.stack.enrolment.resumePendingRotations(workspaceId: defaultWs());

    expect(faults.putKeyWrapsCallCount, 2,
        reason: 'the resume issued the second, byte-identical PUT — the idempotent '
            're-PUT path, exercised because no pull re-learned the key first');
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNotNull,
        reason: 'the byte-identical re-PUT returned 200 and the key was remembered');
    expect(await a.pendingRotations.read(defaultWs()), isEmpty,
        reason: 'the completed record was removed');
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

  // --- #627: a refusal no retry can change -----------------------------------

  test('a resume PUT refused with keywrap_digest_mismatch alarms, terminalises '
      'the record and stops churning', () async {
    final (a, faults) = await phone(label: 'A');
    final outcome = await a.enrolAsFirstDevice();
    await strandDefaultWorkspaceRotation(a, faults, outcome.passphrase);

    // The cross-device state: A rotated to epoch 1 and committed *its* digest, so
    // this device's prepared set can never hash to what the log committed to. A
    // digest the log did not commit to can never become the digest it did — and no
    // amount of retrying changes that.
    faults.refuseWith[defaultWs()] = _ScriptedRefusal(
      const SyncTransportException(422, 'epoch 1',
          code: keyWrapDigestMismatchCode),
    );

    final putsBefore = faults.putKeyWrapsCallCount;
    await pullsThroughListener(a, count: 4);

    expect(faults.putKeyWrapsCallCount, putsBefore + 1,
        reason: 'four pulls, exactly one resume PUT: the churn is bounded, which is '
            'the whole defect. Before terminalisation this was one PUT per pull, '
            'for ever');
    expect(await a.pendingRotations.readResumable(defaultWs()), isEmpty,
        reason: 'the record is no longer resumed');
    final held = await a.pendingRotations.read(defaultWs());
    expect(held, contains(1),
        reason: 'the bytes are retained, not deleted (AC-3) — `read` stays honest, '
            'so a retained record is distinguishable from a removed one');
    expect(held[1]!.terminal, isNotNull);
    expect(held[1]!.terminal!.refusalCode, keyWrapDigestMismatchCode,
        reason: 'the code is stamped verbatim, not folded into another meaning');

    final health = await a.stack.defaultClient.health();
    expect(health.alarmKinds,
        contains(IntegrityAlarmKind.epochKeySetUnpublishable.code));
    expect(health.unresolvedAlarmCount, 1);

    final alarm =
        await alarmOfKind(a, IntegrityAlarmKind.epochKeySetUnpublishable);
    expect(alarm, isNotNull);
    expect(alarm!.detail, contains('epoch 1'));
    expect(alarm.detail, contains(keyWrapDigestMismatchCode),
        reason: 'actionable on its own for #584: the literal code, not prose about '
            'it');
    expect(alarm.detail, contains('retained'),
        reason: 'the detail says the prepared bytes were kept, so a reader does not '
            'have to guess whether recovery is foreclosed');
    expect(alarm.authorMemberId, isNull,
        reason: 'this accusation names no culprit — the server was right to refuse');
    expect(alarm.occurrenceCount, 1,
        reason: 'raised once across four pulls, so a #575 dismissal would not be '
            'un-resolved on the next pull');
  });

  test('a local store failure during a resume leaves the record and does not '
      'break the pull (AC-5)', () async {
    late _FailingWriteStore store;
    final (a, faults) = await phone(
      label: 'A',
      pendingRotationStore: (inner) => store = _FailingWriteStore(inner),
    );
    final outcome = await a.enrolAsFirstDevice();
    await strandDefaultWorkspaceRotation(a, faults, outcome.passphrase);

    // Now the keychain refuses writes — the state a Keystore hiccup leaves, which
    // `resetOnError: false` deliberately surfaces as a loud read/write failure
    // rather than a silently emptied store.
    store.failWrites = true;
    // And the server would accept the re-PUT, so the *only* thing that can fail this
    // pass is the local `remove` after a successful publish.
    await pullsThroughListener(a, count: 1);

    expect(await a.pendingRotations.readResumable(defaultWs()), contains(1),
        reason: 'the record is still there and still resumable — a store failure is '
            'never a reason to give up on it');
    expect(await a.stack.defaultClient.health(), isNotNull);
    expect((await a.stack.defaultClient.health()).lastSyncedAt, isNotNull,
        reason: 'the pull itself completed; the resume is not a pull failure');
    expect(await alarmOfKind(a, IntegrityAlarmKind.epochKeySetUnpublishable),
        isNull,
        reason: 'a local failure is not an accusation');
  });

  test('a terminal mark that cannot be written still raises the alarm, and the '
      'record stays active', () async {
    late _FailingWriteStore store;
    final (a, faults) = await phone(
      label: 'A',
      pendingRotationStore: (inner) => store = _FailingWriteStore(inner),
    );
    final outcome = await a.enrolAsFirstDevice();
    await strandDefaultWorkspaceRotation(a, faults, outcome.passphrase);

    faults.refuseWith[defaultWs()] = _ScriptedRefusal(
      const SyncTransportException(422, 'epoch 1',
          code: keyWrapDigestMismatchCode),
    );
    store.failWrites = true;

    await pullsThroughListener(a, count: 2);

    // Alarm-before-mark is what makes this the safe failure: the condition is
    // visible even though the mark did not land, whereas mark-before-alarm would
    // have left a silent terminal record.
    final alarm =
        await alarmOfKind(a, IntegrityAlarmKind.epochKeySetUnpublishable);
    expect(alarm, isNotNull);
    expect(await a.pendingRotations.readResumable(defaultWs()), contains(1),
        reason: 'the mark never landed, so the record is still active and the next '
            'pass retries both the mark and the alarm');
    expect(alarm!.occurrenceCount, 2,
        reason: 'the accepted degradation, pinned rather than left for #575 to '
            'discover: a persistently-failing mark re-raises every pull, which '
            'un-resolves an alarm the user had dismissed. Correct precedence — a '
            'record still churning is a condition that still stands — but real');
  });

  test('an alarm write that throws is absorbed and does not break the pull',
      () async {
    final (a, faults) = await phone(label: 'A');
    final outcome = await a.enrolAsFirstDevice();
    await strandDefaultWorkspaceRotation(a, faults, outcome.passphrase);

    faults.refuseWith[defaultWs()] = _ScriptedRefusal(
      const SyncTransportException(422, 'epoch 1',
          code: keyWrapDigestMismatchCode),
    );
    // A genuinely broken local store: the alarm table is not there to write to.
    // Renamed rather than dropped so it can be put back and asserted on.
    await a.syncStore
        .customStatement('ALTER TABLE integrity_alarms RENAME TO alarms_hidden');

    await pullsThroughListener(a, count: 1);

    await a.syncStore
        .customStatement('ALTER TABLE alarms_hidden RENAME TO integrity_alarms');
    expect(await alarmOfKind(a, IntegrityAlarmKind.epochKeySetUnpublishable),
        isNull);
    expect(await a.pendingRotations.readResumable(defaultWs()), contains(1),
        reason: 'alarm first, mark second: a failed alarm write leaves the record '
            'active rather than silently terminal');
    expect((await a.stack.defaultClient.health()).lastSyncedAt, isNotNull,
        reason: 'the pull completed — an alarm-write throw is caught by the same '
            'arm a store throw is');
  });

  test('a later epoch still publishes behind a terminal record (AC-4)', () async {
    final (a, faults) = await phone(label: 'A');
    final outcome = await a.enrolAsFirstDevice();
    await strandDefaultWorkspaceRotation(a, faults, outcome.passphrase);

    // Terminalise epoch 1 through the production route.
    faults.refuseWith[defaultWs()] = _ScriptedRefusal(
      const SyncTransportException(422, 'epoch 1',
          code: keyWrapDigestMismatchCode),
      remaining: 1,
    );
    await pullsThroughListener(a, count: 1);
    expect((await a.pendingRotations.read(defaultWs()))[1]!.terminal, isNotNull);

    // A second record at a *higher* epoch, whose rotate never materialised. If the
    // loop stopped at the terminal lowest epoch this would sit untouched for ever.
    await a.pendingRotations.put(defaultWs(), _placeholderSet(2));
    faults.refuseWith[defaultWs()] = _ScriptedRefusal(
      const SyncTransportException(409, 'epoch 2',
          code: rotateNotMaterialisedCode),
    );
    final putsBefore = faults.putKeyWrapsCallCount;

    await pullsThroughListener(a, count: 1);

    expect(faults.putKeyWrapsCallCount, putsBefore + 1,
        reason: 'epoch 2 was reached and attempted — the terminal record for epoch 1 '
            'does not wedge the epochs behind it');
    final held = await a.pendingRotations.read(defaultWs());
    expect(held, isNot(contains(2)),
        reason: 'a rotate that never materialised is discarded after a flush that '
            'succeeded');
    expect(held, contains(1), reason: 'and the terminal record is still retained');
  });

  test('a deterministically-refused flush raises own_write_refused_permanently, '
      'blames no record, and still attempts the publish', () async {
    final (a, faults) = await phone(label: 'A');
    final outcome = await a.enrolAsFirstDevice();
    await strandDefaultWorkspaceRotation(a, faults, outcome.passphrase);

    // The losing device of a rotation race: its queued rotate names a `from_epoch`
    // the Workspace has already moved past, and that epoch is signed into the op. So
    // `POST /ops` refuses it for ever and everything queued behind it is stuck —
    // #647's to drain, this issue's to name.
    faults.refusePostOpsWith[defaultWs()] = _ScriptedRefusal(
      const SyncTransportException(409, 'ops[0]', code: rotateEpochConflictCode),
    );
    // Something *in* the outbox for that refusal to land on: `capture` queues without
    // posting, so this is the unpostable-queue state without reaching into the store.
    await a.stack.defaultClient.capture(
      collection: _collection,
      entityId: _entityId('behind-the-wedged-rotate'),
      fields: const {'title': 'queued behind an op the server will never take'},
    );
    // The publish would be refused as `rotate_not_materialised`, which is a *delete*
    // — and deleting after a failed flush would destroy a wrap set whose rotate is
    // still in the outbox. The downgrade to `retry` is what stops that.
    faults.refuseWith[defaultWs()] = _ScriptedRefusal(
      const SyncTransportException(409, 'epoch 1',
          code: rotateNotMaterialisedCode),
    );
    final putsBefore = faults.putKeyWrapsCallCount;

    await pullsThroughListener(a, count: 1);

    final flushAlarm =
        await alarmOfKind(a, IntegrityAlarmKind.ownWriteRefusedPermanently);
    expect(flushAlarm, isNotNull,
        reason: 'the condition is named rather than silent');
    expect(flushAlarm!.detail, contains(rotateEpochConflictCode),
        reason: 'the code verbatim, so the alarm is actionable on its own');
    expect(flushAlarm.authorMemberId, isNotNull,
        reason: 'this *is* an own-writes accusation, and carries its author the way '
            'own_writes_rollback does');
    expect(await alarmOfKind(a, IntegrityAlarmKind.epochKeySetUnpublishable),
        isNull,
        reason: 'the attribution guard: a flush is one call per Workspace, so its '
            'refusal blames no single epoch. Before the hoist this refusal was '
            'caught by whichever epoch the loop was on');
    expect(faults.putKeyWrapsCallCount, putsBefore + 1,
        reason: 'per-epoch independence survives the hoist: a failed flush does not '
            'skip the publishes');
    expect(await a.pendingRotations.readResumable(defaultWs()), contains(1),
        reason: 'and rotate_not_materialised was downgraded from discard to retry, '
            'because the rotate it would have orphaned is still in the outbox');
    expect((await a.pendingRotations.read(defaultWs()))[1]!.terminal, isNull,
        reason: 'a flush refusal never terminalises a record');
  });

  test('an unclassified refusal is retried a bounded number of times, alarmed, '
      'and persists nothing — and a relaunch gets a fresh budget', () async {
    final (a, faults) = await phone(label: 'A', fileBacked: true);
    final outcome = await a.enrolAsFirstDevice();
    await strandDefaultWorkspaceRotation(a, faults, outcome.passphrase);

    // A code no build knows: the shape of a server that has grown a new refusal.
    // There is no `default: retry`, so this cannot join the churn-for-ever path —
    // but it must not become durably final either, or a novel code emitted during a
    // rolling deploy would terminalise sound records fleet-wide.
    faults.refuseWith[defaultWs()] = _ScriptedRefusal(
      const SyncTransportException(418, 'brand new rule',
          code: 'not_a_code_this_build_knows'),
    );
    final putsBefore = faults.putKeyWrapsCallCount;

    await pullsThroughListener(a, count: 8);

    expect(faults.putKeyWrapsCallCount,
        putsBefore + maxUnclassifiedResumeRefusalAttempts,
        reason: 'eight pulls, five PUTs: bounded, then it stops re-attempting for '
            'this process');
    final alarm =
        await alarmOfKind(a, IntegrityAlarmKind.epochKeySetUnpublishable);
    expect(alarm, isNotNull);
    expect(alarm!.detail, contains('not_a_code_this_build_knows'),
        reason: 'the unknown code, verbatim — the only diagnostic there is');
    final held = await a.pendingRotations.read(defaultWs());
    expect(held[1]!.terminal, isNull,
        reason: 'nothing durable: no unknown code may ever produce a terminal '
            'record, so a transient-but-unclassified one self-heals');
    expect(await a.pendingRotations.readResumable(defaultWs()), contains(1));

    // A relaunch is a new process, so the budget is new. That is what makes the
    // rolling-deploy case recoverable without a recovery tool.
    final putsBeforeRelaunch = faults.putKeyWrapsCallCount;
    await a.relaunch();
    expect(await a.activate(), SyncActivation.active);
    expect(faults.putKeyWrapsCallCount, greaterThan(putsBeforeRelaunch),
        reason: 'the in-memory budget died with the process, so the record is '
            're-attempted');
  });

  test('a 500 on a resume PUT stays transient: retried, never alarmed', () async {
    final (a, faults) = await phone(label: 'A');
    final outcome = await a.enrolAsFirstDevice();
    await strandDefaultWorkspaceRotation(a, faults, outcome.passphrase);

    faults.refuseWith[defaultWs()] =
        _ScriptedRefusal(const SyncTransportException(500, 'server exploded'));
    final putsBefore = faults.putKeyWrapsCallCount;

    await pullsThroughListener(a, count: 3);

    expect(faults.putKeyWrapsCallCount, putsBefore + 3,
        reason: 'the guard against over-terminalising: a server failing is not a '
            'verdict on the set, so every pull re-attempts and no budget is spent');
    expect(await a.pendingRotations.readResumable(defaultWs()), contains(1));
    expect(await alarmOfKind(a, IntegrityAlarmKind.epochKeySetUnpublishable),
        isNull);
  });

  test('a pass whose every record is already held performs no flush', () async {
    final (a, faults) = await phone(label: 'A');
    final passphrase = (await a.enrolAsFirstDevice()).passphrase;
    await a.stack.enrolment.turnOnEncryption(passphrase: passphrase);
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNotNull);

    // The crash-between-publish-and-remove state: a record for an epoch already
    // held. Discarding it happens *before* the flush, so hoisting the flush out of
    // the per-epoch loop did not make a stale-only pass start posting.
    await a.pendingRotations.put(defaultWs(), _placeholderSet(1));
    final postsBefore = faults.postOpsCallCount;

    await a.stack.enrolment.resumePendingRotations(workspaceId: defaultWs());

    expect(await a.pendingRotations.read(defaultWs()), isEmpty);
    expect(faults.postOpsCallCount, postsBefore,
        reason: 'nothing resumable was left after the discard, so there was nothing '
            'to flush for');
  });

  test('the record codec discards a corrupt entry per record, and flags a wholly '
      'undecodable record for self-discard', () {
    // The corruption tolerance is the pure [decodePendingRotationsRecord] — the exact
    // logic `SecureStoragePendingRotationStore.readRaw` runs on the keychain bytes,
    // tested directly on those bytes rather than through a mocked platform channel.

    // One decodable epoch and one that cannot decode (a truncated value), side by
    // side in the same record.
    final mixed = jsonEncode({
      '3': encodePendingEpochKeySet(_placeholderSet(3)),
      '5': {'epoch': 5, 'workspace_key': 'not valid base64 %%%'},
    });
    final (goodSets, mixedWasCorrupt) = decodePendingRotationsRecord(mixed);
    expect(goodSets.keys.toList(), [3],
        reason: 'the good epoch survives; the corrupt one is skipped, not thrown');
    expect(goodSets[3]!.set.epoch, 3);
    expect(goodSets[3]!.terminal, isNull,
        reason: 'an entry with no `terminal` field decodes as active — every record '
            'written before terminal marks existed reads exactly as it did, with no '
            'migration and no data loss');
    expect(mixedWasCorrupt, isFalse,
        reason: 'a per-entry skip does not condemn the whole record');

    // A wholly undecodable record is flagged so `readRaw` self-discards it — otherwise
    // it would wedge `resumePendingRotations` and every later ceremony for good.
    final (garbageSets, garbageWasCorrupt) =
        decodePendingRotationsRecord('not json at all');
    expect(garbageSets, isEmpty);
    expect(garbageWasCorrupt, isTrue,
        reason: 'an unparseable record must be cleared, not re-read for ever');
  });

  test('a read self-heal cannot clobber a concurrent put — read and put share the '
      'mutation chain', () async {
    // Exercised at the app-owned store seam: `_GatedSelfHealingStore` implements the
    // abstract `PendingRotationStore` (the class that owns `read`/`put`/`_serialised`)
    // with an in-memory backing and a gate on its `clearRaw`. No system component is
    // mocked — the serialization under test is storage-independent app logic.
    final store = _GatedSelfHealingStore();
    const ws = 'rotation-resume-race-ws';

    // A wholly corrupt record: a direct `read` — the shape `resumePendingRotations`
    // issues — self-heals it by deleting the record (`clearRaw`), exactly as
    // `SecureStoragePendingRotationStore.readRaw` does on undecodable bytes.
    store.markCorrupt(ws);

    // Hold that self-heal delete at an explicit gate; wait for the signal that it has
    // reached the gate, then queue a `put` while it is parked. `store.put` registers
    // on the mutation chain synchronously before it returns, so it is queued behind
    // the parked read. If `read` were off the chain the put's write would land inside
    // the delete's window and the resumed delete would wipe it; because `read` shares
    // the chain, the put waits for the whole read (self-heal included).
    final gate = Completer<void>();
    store.clearGate = gate;
    final readFuture = store.read(ws);
    await store.clearAtGate.future; // the self-heal delete is now parked, before its remove
    final putFuture = store.put(ws, _placeholderSet(9));
    // Drain the microtask queue while the self-heal is still parked. Off the chain the
    // put runs to completion here (its write lands); on the chain it is queued behind
    // the parked read and makes no progress. `pumpEventQueue` settles either outcome
    // deterministically — robust to how many async hops the put takes, unlike a fixed
    // count of zero-duration yields.
    await pumpEventQueue();
    gate.complete(); // only now release the self-heal's remove

    await Future.wait([readFuture, putFuture]);

    final after = await store.read(ws);
    expect(after.keys, contains(9),
        reason: 'the put survived: a chained read cannot let its self-heal delete '
            'land after the put and clobber the set it just persisted');
    expect(after[9]!.set.epoch, 9);
  });

  test('put refuses a different set for an epoch already pending, but a '
      'byte-identical re-put still succeeds', () async {
    final store = InMemoryPendingRotationStore();
    const ws = 'rotation-resume-conflict-ws';

    // The first ceremony's prepared set for epoch 1.
    final first = EpochKeySet(
      epoch: 1,
      workspaceKey: _filled(workspaceKeyBytes, 0x11),
      memberWraps: const [],
      escrowWrap: _filled(epochKeyEscrowWrapBytes, 0x22),
      digest: _filled(keyWrapDigestBytes, 0x33),
    );
    await store.put(ws, first);

    // The idempotent path — a resume re-persisting byte-identical bytes — is allowed.
    await store.put(ws, EpochKeySet(
      epoch: 1,
      workspaceKey: _filled(workspaceKeyBytes, 0x11),
      memberWraps: const [],
      escrowWrap: _filled(epochKeyEscrowWrapBytes, 0x22),
      digest: _filled(keyWrapDigestBytes, 0x33),
    ));
    expect((await store.read(ws))[1]!.set.digest, first.digest);

    // A *different* set for the same epoch is the orphaning hazard: a second
    // concurrent ceremony that prepared distinct entropy for the same `toEpoch`. It
    // must be refused, not silently overwrite the first.
    final second = EpochKeySet(
      epoch: 1,
      workspaceKey: _filled(workspaceKeyBytes, 0xAA),
      memberWraps: const [],
      escrowWrap: _filled(epochKeyEscrowWrapBytes, 0xBB),
      digest: _filled(keyWrapDigestBytes, 0xCC),
    );
    await expectLater(
      store.put(ws, second),
      throwsA(isA<ConflictingPendingRotation>()),
    );

    // The first set survived untouched — the epoch it commits to stays recoverable.
    final held = await store.read(ws);
    expect(held[1]!.set.workspaceKey, first.workspaceKey);
    expect(held[1]!.set.digest, first.digest);
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

  test('a terminal mark retains the bytes, is idempotent, and hides the record '
      'from readResumable while read still shows it', () async {
    final store = InMemoryPendingRotationStore();
    const ws = 'rotation-resume-terminal-ws';
    await store.put(ws, _placeholderSet(1));

    await store.markTerminal(ws, 1,
        refusalCode: keyWrapDigestMismatchCode,
        markedAtUtc: DateTime.utc(2026, 7, 31, 9));

    final held = await store.read(ws);
    expect(held, contains(1),
        reason: 'retained, never deleted (ADR-0040): clearing a stuck state by '
            'destroying its bytes is the same error at a smaller scale');
    expect(held[1]!.set.digest, _placeholderSet(1).digest,
        reason: 'and the bytes are the same bytes');
    expect(held[1]!.terminal!.refusalCode, keyWrapDigestMismatchCode);
    expect(await store.readResumable(ws), isEmpty,
        reason: 'the resume loop reads this one, so the record is not re-PUT');

    // A retained record must stay distinguishable from a removed one — that is the
    // whole reason `read` is not filtered.
    await store.markTerminal(ws, 2,
        refusalCode: 'nothing_here', markedAtUtc: DateTime.utc(2026, 7, 31, 10));
    expect(await store.read(ws), isNot(contains(2)),
        reason: 'marking an absent epoch is a no-op, not a resurrection');

    // Idempotent, keeping the *first* stamp: that is when the condition was proved,
    // and a later pass re-proving it says nothing new.
    await store.markTerminal(ws, 1,
        refusalCode: 'keywrap_already_written',
        markedAtUtc: DateTime.utc(2026, 8, 1, 9));
    final restamped = await store.read(ws);
    expect(restamped[1]!.terminal!.refusalCode, keyWrapDigestMismatchCode);
    expect(restamped[1]!.terminal!.markedAtUtc, DateTime.utc(2026, 7, 31, 9));
  });

  test('a byte-identical re-put does not clear a terminal mark, and a different '
      'set at a terminal epoch still fails closed', () async {
    final store = InMemoryPendingRotationStore();
    const ws = 'rotation-resume-terminal-put-ws';
    final set = EpochKeySet(
      epoch: 1,
      workspaceKey: _filled(workspaceKeyBytes, 0x11),
      memberWraps: const [],
      escrowWrap: _filled(epochKeyEscrowWrapBytes, 0x22),
      digest: _filled(keyWrapDigestBytes, 0x33),
    );
    await store.put(ws, set);
    await store.markTerminal(ws, 1,
        refusalCode: keyWrapDigestMismatchCode,
        markedAtUtc: DateTime.utc(2026, 7, 31, 9));

    // The idempotent path — a caller re-persisting what it read — must not silently
    // reactivate the record, or the churn the mark exists to stop restarts.
    await store.put(
      ws,
      EpochKeySet(
        epoch: 1,
        workspaceKey: _filled(workspaceKeyBytes, 0x11),
        memberWraps: const [],
        escrowWrap: _filled(epochKeyEscrowWrapBytes, 0x22),
        digest: _filled(keyWrapDigestBytes, 0x33),
      ),
    );
    expect((await store.read(ws))[1]!.terminal, isNotNull);
    expect(await store.readResumable(ws), isEmpty);

    // And the fail-closed guard still sees terminal rows through `readRaw`, so a
    // *different* set for that epoch is still refused rather than overwriting it.
    await expectLater(
      store.put(
        ws,
        EpochKeySet(
          epoch: 1,
          workspaceKey: _filled(workspaceKeyBytes, 0xAA),
          memberWraps: const [],
          escrowWrap: _filled(epochKeyEscrowWrapBytes, 0xBB),
          digest: _filled(keyWrapDigestBytes, 0xCC),
        ),
      ),
      throwsA(isA<ConflictingPendingRotation>()),
    );
    expect((await store.read(ws))[1]!.set.workspaceKey, set.workspaceKey);
  });

  test('the record codec round-trips a terminal mark, and a malformed one leaves '
      'that entry inert', () {
    final record = PendingRotation(
      set: _placeholderSet(7),
      terminal: PendingRotationTerminalMark(
        refusalCode: keyWrapDigestMismatchCode,
        markedAtUtc: DateTime.utc(2026, 7, 31, 9, 15, 30),
      ),
    );

    final (round, wasCorrupt) = decodePendingRotationsRecord(
      jsonEncode({'7': encodePendingRotation(record)}),
    );
    expect(wasCorrupt, isFalse);
    expect(round[7]!.set.digest, record.set.digest);
    expect(round[7]!.terminal!.refusalCode, keyWrapDigestMismatchCode);
    expect(round[7]!.terminal!.markedAtUtc, record.terminal!.markedAtUtc);

    // A malformed `terminal` takes the existing per-entry skip: inert on disk and
    // not resumed, which is the fail-safe direction.
    final (skipped, _) = decodePendingRotationsRecord(jsonEncode({
      '7': {...encodePendingEpochKeySet(_placeholderSet(7)), 'terminal': 'nonsense'},
      '8': encodePendingEpochKeySet(_placeholderSet(8)),
    }));
    expect(skipped.keys.toList(), [8],
        reason: 'the bad entry is skipped without wedging the good one');
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

/// An app-owned [PendingRotationStore] for exercising the base class's
/// `read`/`put`/`_serialised` mutation chain under a controllable interleaving —
/// with no system component in the picture.
///
/// In-memory backing, like [InMemoryPendingRotationStore], plus two knobs the
/// production stores do not need:
/// - [markCorrupt] makes [readRaw] self-heal (call `clearRaw`) for a Workspace, the
///   way [SecureStoragePendingRotationStore.readRaw] does on undecodable bytes;
/// - [clearGate] parks the next `clearRaw` mid-flight, so a test can hold a self-heal
///   open while a concurrent `put` is queued, and [clearAtGate] signals the instant
///   that park is reached — no event-loop-yield guessing.
class _GatedSelfHealingStore extends PendingRotationStore {
  final Map<String, PendingRotationsByEpoch> _sets = {};
  final Set<String> _corruptWorkspaces = {};

  Completer<void>? clearGate;
  final Completer<void> clearAtGate = Completer<void>();

  void markCorrupt(String workspaceId) => _corruptWorkspaces.add(workspaceId);

  @override
  Future<PendingRotationsByEpoch> readRaw(String workspaceId) async {
    if (_corruptWorkspaces.contains(workspaceId)) {
      // Mirror the production self-heal: a wholly-corrupt record discards itself via
      // `clearRaw`, then reads as empty.
      await clearRaw(workspaceId);
      return {};
    }
    return {...?_sets[workspaceId]};
  }

  @override
  Future<void> write(String workspaceId, PendingRotationsByEpoch setsByEpoch) async {
    _sets[workspaceId] = {...setsByEpoch};
  }

  @override
  Future<void> clearRaw(String workspaceId) async {
    _corruptWorkspaces.remove(workspaceId);
    final gate = clearGate;
    if (gate != null) {
      clearGate = null;
      if (!clearAtGate.isCompleted) clearAtGate.complete();
      await gate.future;
    }
    _sets.remove(workspaceId);
  }
}

/// A [PendingRotationStore] whose *writes* fail on demand — the AC-5 fault, wrapped
/// around the real in-memory store and injected through [StackPhone.create]'s
/// decorator seam so the production path is the one that meets it.
///
/// What a Keystore hiccup leaves behind: the epoch keys are pinned with
/// `resetOnError: false` precisely so a failure is loud rather than a store that
/// silently loses the set it must publish, and this is that failure. Reads keep
/// working, so a test can still see that the record survived.
class _FailingWriteStore extends PendingRotationStore {
  _FailingWriteStore(this._inner);

  final PendingRotationStore _inner;

  bool failWrites = false;

  @override
  Future<PendingRotationsByEpoch> readRaw(String workspaceId) =>
      _inner.readRaw(workspaceId);

  @override
  Future<void> write(String workspaceId, PendingRotationsByEpoch setsByEpoch) {
    if (failWrites) {
      throw StateError('the keychain refused the write');
    }
    return _inner.write(workspaceId, setsByEpoch);
  }

  @override
  Future<void> clearRaw(String workspaceId) {
    if (failWrites) {
      throw StateError('the keychain refused the delete');
    }
    return _inner.clearRaw(workspaceId);
  }
}
