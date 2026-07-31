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
///
/// The closing group covers #624: the per-User ceremony lock that serialises
/// concurrent rotation entry points. The same decorator seam parks a ceremony
/// mid-`putKeyWraps` — lock held, no progress — so a test can prove a resume
/// declines rather than blocking behind it.
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
  /// is the AC-4 shape: the set is written server-side but the device never
  /// remembered the key and the record stands. On recovery the ordinary pull
  /// re-learns that committed wrap (`refreshEpochKeys`, no passphrase), so the
  /// resume finds the key already held and discards the stale record — the
  /// byte-identical-200 server idempotency (`#590`) is the belt-and-braces backstop
  /// for the resume-before-pull ordering, not the route this scenario takes.
  final Map<String, int> commitThenThrow = {};

  /// When set, the next `putKeyWraps` completes [putKeyWrapsReachedPark] and then
  /// awaits this gate before doing anything else, so a test can hold a ceremony
  /// parked mid-publish — lock held, no progress — while it drives an overlapping
  /// resume and proves the resume does not block behind it (#624 AC-5).
  Completer<void>? parkNextPutKeyWraps;

  /// Completed the instant a parked `putKeyWraps` reaches its gate, so a test waits
  /// on a signal rather than guessing how many event-loop turns the ceremony takes
  /// to get there.
  Completer<void>? putKeyWrapsReachedPark;

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
    final park = _faults.parkNextPutKeyWraps;
    if (park != null) {
      _faults.parkNextPutKeyWraps = null;
      _faults.putKeyWrapsReachedPark?.complete();
      await park.future;
    }
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

  // --- #624: serialising concurrent ceremonies -------------------------------

  test('two overlapping rotateWorkspaceKeys for one User serialise: the second '
      'observes the first\'s raised floor and does not raise '
      'ConflictingPendingRotation (AC-1)', () async {
    final (a, _) = await phone(label: 'A');
    final passphrase = (await a.enrolAsFirstDevice()).passphrase;

    // Both futures start before either is awaited, so without the per-User ceremony
    // lock they interleave: both read epoch floor 0, both `prepare` a *distinct* set
    // for toEpoch 1 (they share one `_random`, so the draws differ), and the later
    // `put` raises ConflictingPendingRotation. The lock makes them run one-after-the-
    // other instead — 0->1, then 1->2.
    final results = await Future.wait([
      a.stack.enrolment.rotateWorkspaceKeys(passphrase: passphrase),
      a.stack.enrolment.rotateWorkspaceKeys(passphrase: passphrase),
    ]);

    expect(results[0][defaultWs()], 1);
    expect(results[0][prefsWs()], 1);
    expect(results[1][defaultWs()], 2,
        reason: 'the second ceremony rotated off the first\'s raised floor');
    expect(results[1][prefsWs()], 2);

    expect(await a.stack.defaultClient.epochFloor(), 2);
    expect(await a.workspaceKeys.keyFor(defaultWs(), 2), isNotNull);
    expect(await a.workspaceKeys.keyFor(prefsWs(), 2), isNotNull);
    expect(await a.pendingRotations.read(defaultWs()), isEmpty);
    expect(await a.pendingRotations.read(prefsWs()), isEmpty);
  });

  test('a resumePendingRotations overlapping a rotateWorkspaceKeys serialises '
      'rather than racing the prepared-set put: the ceremony queues behind the '
      'in-flight resume, and the stranded epoch is published once (AC-2)', () async {
    final (a, faults) = await phone(label: 'A');
    final passphrase = (await a.enrolAsFirstDevice()).passphrase;

    // Strand the default Workspace at epoch 1, then clear the fault so both an
    // external resume and a fresh ceremony can publish.
    faults.failBeforeCommit[defaultWs()] = 1;
    await expectLater(
      a.stack.enrolment.turnOnEncryption(passphrase: passphrase),
      throwsA(isA<SyncTransportException>()),
    );
    expect(await a.pendingRotations.read(defaultWs()), contains(1));
    faults.failBeforeCommit.clear();
    final putsBeforeOverlap = faults.putKeyWrapsCallCount;

    // The external resume is started first, so it takes the lock; the ceremony's
    // blocking acquire then *queues behind it* rather than racing its store writes.
    // The resume re-publishes stranded epoch 1; the ceremony, running next, finds
    // nothing to resume and rotates both Workspaces off the raised floor.
    final resumeFuture = a.stack.enrolment.resumePendingRotations();
    final ceremonyFuture =
        a.stack.enrolment.rotateWorkspaceKeys(passphrase: passphrase);
    await Future.wait([resumeFuture, ceremonyFuture]);
    final epochs = await ceremonyFuture;

    expect(epochs[defaultWs()], 2);
    expect(epochs[prefsWs()], 1);
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNotNull,
        reason: 'the resume published the stranded epoch 1');
    expect(await a.workspaceKeys.keyFor(defaultWs(), 2), isNotNull);
    expect(await a.workspaceKeys.keyFor(prefsWs(), 1), isNotNull);
    expect(await a.pendingRotations.read(defaultWs()), isEmpty);
    expect(await a.pendingRotations.read(prefsWs()), isEmpty);

    // Three PUTs across the overlap — the resume's re-publish of epoch 1, plus the
    // ceremony's default 1->2 and prefs 0->1 — never a fourth. A resume racing the
    // ceremony would have re-published epoch 1 a second time alongside it.
    expect(faults.putKeyWrapsCallCount - putsBeforeOverlap, 3,
        reason: 'the resume and the ceremony serialised: epoch 1 was published '
            'exactly once, not raced');
  });

  test('rotateWorkspaceKeys finishes a strand through its own internal '
      'resumePendingRotations without deadlocking on the ceremony lock it already '
      'holds, and without silently skipping the resume (AC-3)', () async {
    final (a, faults) = await phone(label: 'A');
    final passphrase = (await a.enrolAsFirstDevice()).passphrase;

    // Strand the default Workspace at epoch 1 (turnOnEncryption rotates it first).
    faults.failBeforeCommit[defaultWs()] = 1;
    await expectLater(
      a.stack.enrolment.turnOnEncryption(passphrase: passphrase),
      throwsA(isA<SyncTransportException>()),
    );
    expect(await a.pendingRotations.read(defaultWs()), contains(1));
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNull);
    faults.failBeforeCommit.clear();

    // The next ceremony calls resumePendingRotations *while holding the lock*. A
    // blocking self-acquire would deadlock and hang this await; a decline-if-
    // contended self-acquire would return without resuming and leave epoch 1
    // orphaned. The wrapper+core split takes the unlocked core, so the internal
    // resume actually runs and finishes epoch 1 before the fresh rotation.
    final epochs = await a.stack.enrolment.rotateWorkspaceKeys(passphrase: passphrase);

    expect(await a.pendingRotations.read(defaultWs()), isEmpty,
        reason: 'the internal resume ran and finished stranded epoch 1');
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNotNull);
    expect(epochs[defaultWs()], 2,
        reason: 'then the fresh rotation took the default Workspace 1->2');
    expect(epochs[prefsWs()], 1);
  });

  test('a resume declines while a ceremony holds the lock, so a pull-tail or launch '
      'resume never blocks the pull loop or activation behind an in-flight ceremony '
      '(AC-5)', () async {
    final (a, faults) = await phone(label: 'A');
    final passphrase = (await a.enrolAsFirstDevice()).passphrase;

    // Park the ceremony's first publish: it holds the lock but makes no progress
    // until released. turnOnEncryption rotates the default Workspace first, so the
    // park catches it mid-publish with its pending record already written.
    final gate = Completer<void>();
    final reachedPark = Completer<void>();
    faults.parkNextPutKeyWraps = gate;
    faults.putKeyWrapsReachedPark = reachedPark;

    var ceremonyDone = false;
    final ceremony = a.stack.enrolment
        .turnOnEncryption(passphrase: passphrase)
        .whenComplete(() => ceremonyDone = true);
    await reachedPark.future; // the ceremony now holds the lock, parked mid-publish

    // The overlapping resume must return without waiting for the ceremony. If it
    // blocked on the lock this await would hang until the (still-closed) gate opened,
    // and the test would time out. Completing here — with the ceremony still parked —
    // is the proof it declined rather than serialising behind the ceremony.
    await a.stack.enrolment.resumePendingRotations();
    expect(ceremonyDone, isFalse,
        reason: 'the resume returned while the ceremony still held the lock');

    gate.complete();
    final epochs = await ceremony;

    expect(ceremonyDone, isTrue);
    expect(epochs[defaultWs()], 1);
    expect(epochs[prefsWs()], 1);
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNotNull);
    expect(await a.workspaceKeys.keyFor(prefsWs(), 1), isNotNull);
    expect(await a.pendingRotations.read(defaultWs()), isEmpty);
    expect(await a.pendingRotations.read(prefsWs()), isEmpty);
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
    expect(goodSets[3]!.epoch, 3);
    expect(mixedWasCorrupt, isFalse,
        reason: 'a per-entry skip does not condemn the whole record');

    // A wholly undecodable record is flagged so `readRaw` self-discards it — otherwise
    // it would wedge `resumePendingRotations` and every later ceremony for good.
    final (garbageSets, garbageWasCorrupt) =
        decodePendingRotationsRecord('not json at all');
    expect(garbageSets, isEmpty);
    expect(garbageWasCorrupt, isTrue,
        reason: 'an unparseable record must be cleared, not re-read for ever');

    // A record that parses but whose entries *all* fail to decode round-tripped
    // nothing, so it is as safe to discard as an unparseable blob — flagged corrupt
    // for self-discard, not left as dead bytes on disk for ever.
    final allBad = jsonEncode({
      '5': {'epoch': 5, 'workspace_key': 'not valid base64 %%%'},
      '7': {'epoch': 7, 'digest': 'also nonsense'},
    });
    final (allBadSets, allBadWasCorrupt) = decodePendingRotationsRecord(allBad);
    expect(allBadSets, isEmpty);
    expect(allBadWasCorrupt, isTrue,
        reason: 'every entry failing is as good as a top-level failure');

    // An empty record is the steady state once the last epoch is removed — not
    // corruption, so it is left alone rather than churned through a self-discard.
    final (emptySets, emptyWasCorrupt) = decodePendingRotationsRecord('{}');
    expect(emptySets, isEmpty);
    expect(emptyWasCorrupt, isFalse,
        reason: 'an empty record is the ordinary no-pending-rotations state');
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
    expect(after[9]!.epoch, 9);
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
    expect((await store.read(ws))[1]!.digest, first.digest);

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
    expect(held[1]!.workspaceKey, first.workspaceKey);
    expect(held[1]!.digest, first.digest);
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
