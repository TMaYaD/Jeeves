/// Concurrent key-rotation ceremonies for one User serialize through completion
/// (#624), and the passphrase-free resume triggers stay non-blocking.
///
/// These are the graceful half of #622's fail-closed guard: two ceremonies that
/// overlap must run one-after-the-other — the second observing the first's
/// completed state — rather than both reading the same `epochFloor`, preparing
/// distinct sets for one `toEpoch`, and racing the `put` into a
/// `ConflictingPendingRotation`. The serialization primitive is a per-instance
/// (per-User) ceremony lock on `EnrolmentService` with two modes: a full rotation
/// **waits** (FIFO), and a resume trigger **try-acquires and skips** when a
/// ceremony holds the lock.
///
/// Concurrency is deterministic, never timed: a `putKeyWraps` **gate** parks the
/// in-flight ceremony at an explicit point (holding the lock), a test fires a
/// second entry point while it is parked, drains the microtask queue with
/// [pumpEventQueue], asserts the interleaving, then releases the gate. Every
/// concurrency assertion is written so it **fails if the lock is removed** — the
/// parked-window `putKeyWraps` count is 1 only because the second entry point is
/// blocked; unserialized, the second would drive to its own `putKeyWraps` and the
/// count would be 2.
@TestOn('!browser')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/key_wraps.dart' show MemberKeyWrap;
import 'package:jeeves/sync/sync_transport.dart';

import '../test_helpers.dart';
import 'harness/fake_sync_server.dart';
import 'harness/sim_device.dart' show FakeClock;
import 'harness/sim_workspace.dart' show simulationStartWallMs;
import 'harness/stack_phone.dart';

const String _userId = 'rotation-serialization-user';

/// The scriptable knobs a test arms on `putKeyWraps`, shared across every member
/// transport this phone mints. A single one-shot **park** (arm with [armPark]) and a
/// per-Workspace **strand** count ([failBeforeCommit]) are enough to stage every
/// interleaving here.
class _PublishGate {
  /// Every `putKeyWraps` this phone has issued, incremented before the strand/park
  /// branches so a *parked* call still counts — the parked-window count is the
  /// non-vacuous signal that a blocked entry point made no progress.
  int putKeyWrapsCallCount = 0;

  /// workspaceId -> how many more `putKeyWraps` to throw on *before* the server
  /// commits, stranding the epoch exactly as #617's resume tests do.
  final Map<String, int> failBeforeCommit = {};

  Completer<void>? _release;
  Completer<void>? _reached;

  /// Park the **next** `putKeyWraps` (whichever Workspace it targets). Returns the
  /// future that completes the instant that park is reached — so a test knows the
  /// ceremony is suspended holding the lock — and the callback that releases it.
  ({Future<void> reached, void Function() release}) armPark() {
    final release = Completer<void>();
    final reached = Completer<void>();
    _release = release;
    _reached = reached;
    return (reached: reached.future, release: release.complete);
  }

  Future<void> onPutKeyWraps(String workspaceId) async {
    putKeyWrapsCallCount++;
    final remainingFails = failBeforeCommit[workspaceId] ?? 0;
    if (remainingFails > 0) {
      failBeforeCommit[workspaceId] = remainingFails - 1;
      throw const SyncTransportException(500, 'putKeyWraps stranded before commit');
    }
    final release = _release;
    if (release != null) {
      _release = null;
      final reached = _reached;
      _reached = null;
      if (reached != null && !reached.isCompleted) reached.complete();
      await release.future;
    }
  }
}

/// Applies [_PublishGate] to `putKeyWraps`; everything else is the real transport.
class _GatedKeyWrapsTransport implements SyncTransport {
  _GatedKeyWrapsTransport(this._inner, this._gate);

  final SyncTransport _inner;
  final _PublishGate _gate;

  @override
  Future<List<KeyWrapRecord>> putKeyWraps(
    String workspaceId, {
    required int epoch,
    required List<MemberKeyWrap> wraps,
    required Uint8List escrowWrap,
    Uint8List? keyWrapDigest,
  }) async {
    await _gate.onPutKeyWraps(workspaceId);
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

/// A [UserTransport] whose minted member transport carries the gate.
class _GatedUserTransport implements UserTransport {
  _GatedUserTransport(this._inner, this.gate);

  final UserTransport _inner;
  final _PublishGate gate;

  @override
  Future<SyncTransport> completeMemberChallenge({
    required String memberId,
    required Uint8List nonce,
    required Uint8List signature,
  }) async =>
      _GatedKeyWrapsTransport(
        await _inner.completeMemberChallenge(
            memberId: memberId, nonce: nonce, signature: signature),
        gate,
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

void main() {
  setUpAll(configureSqliteForTests);

  late FakeSyncServer server;
  late FakeClock clock;

  setUp(() {
    server = FakeSyncServer();
    clock = FakeClock(simulationStartWallMs);
  });

  Future<(StackPhone, _PublishGate)> phone({bool fileBacked = false}) async {
    final gate = _PublishGate();
    final built = await StackPhone.create(
      label: 'A',
      userId: _userId,
      server: server,
      clock: clock,
      fileBacked: fileBacked,
      userTransport: (link) => _GatedUserTransport(link, gate),
    );
    addTearDown(built.close);
    return (built, gate);
  }

  String defaultWs() => defaultWorkspaceId(_userId);
  String prefsWs() => userPreferencesWorkspaceId(_userId);

  test('two overlapping rotateWorkspaceKeys for one User serialize: the second '
      'waits for the first, both complete, and no ConflictingPendingRotation is '
      'raised (AC-1)', () async {
    final (a, gate) = await phone();
    final passphrase = (await a.enrolAsFirstDevice()).passphrase;

    // Park the first ceremony at its very first publish (default Workspace, epoch 1),
    // holding the lock. `armPark` fires `reached` the instant that park is hit.
    final park = gate.armPark();
    final first = a.stack.enrolment.turnOnEncryption(passphrase: passphrase);
    await park.reached;

    // The second ceremony is fired while the first is parked. It must queue behind the
    // first (its body must not start), so it drives no `putKeyWraps` of its own.
    final second = a.stack.enrolment.rotateWorkspaceKeys(passphrase: passphrase);
    await pumpEventQueue();
    expect(gate.putKeyWrapsCallCount, 1,
        reason: 'the second ceremony is blocked behind the lock and has issued no '
            'publish of its own — unserialized it would drive to its own '
            'putKeyWraps and this would be 2 (the assertion that fails if the lock '
            'is removed)');

    // Release the first; both now run to completion, one after the other.
    park.release();
    final firstEpochs = await first;
    final secondEpochs = await second;

    expect(firstEpochs, {defaultWs(): 1, prefsWs(): 1});
    expect(secondEpochs, {defaultWs(): 2, prefsWs(): 2},
        reason: 'the second observed the first completed and advanced past it, '
            'rather than colliding at the same epoch');
    expect(await a.workspaceKeys.keyFor(defaultWs(), 2), isNotNull);
    expect(await a.workspaceKeys.keyFor(prefsWs(), 2), isNotNull);
    expect(await a.pendingRotations.read(defaultWs()), isEmpty);
    expect(await a.pendingRotations.read(prefsWs()), isEmpty);
  });

  test('a resume fired during a running ceremony try-skips: it returns promptly '
      'without blocking on the ceremony and raises no ConflictingPendingRotation '
      '(AC-2, AC-5)', () async {
    final (a, gate) = await phone();
    final passphrase = (await a.enrolAsFirstDevice()).passphrase;

    // A ceremony parked mid-publish, holding the lock.
    final park = gate.armPark();
    final ceremony = a.stack.enrolment.turnOnEncryption(passphrase: passphrase);
    await park.reached;

    // A pull-tail resume fired while the ceremony holds the lock must NOT queue behind
    // it (that would stall the pull loop / activation — AC-5). It try-acquires, sees a
    // ceremony in flight, and returns at once. Awaiting it here completes *before* the
    // ceremony is released — the property that fails if the resume were a wait-queue.
    var resumeReturned = false;
    final resume = a.stack.enrolment
        .resumePendingRotations(workspaceId: defaultWs())
        .then((_) => resumeReturned = true);
    await resume;
    expect(resumeReturned, isTrue,
        reason: 'the resume returned while the ceremony was still parked — it skipped '
            'rather than blocking (a wait-queue resume would hang here until release)');
    expect(gate.putKeyWrapsCallCount, 1,
        reason: 'the skipped resume issued no publish — it did not race the '
            "ceremony's put");

    // Release; the ceremony finishes cleanly, never having hit a conflict with the
    // resume that overlapped it.
    park.release();
    final epochs = await ceremony;
    expect(epochs, {defaultWs(): 1, prefsWs(): 1});
    expect(await a.pendingRotations.read(defaultWs()), isEmpty);
  });

  test('a rotateWorkspaceKeys that starts mid-resume WAITS for the in-flight resume '
      'rather than racing it (AC-2, resume-first direction)', () async {
    final (a, gate) = await phone();
    final passphrase = (await a.enrolAsFirstDevice()).passphrase;

    // Strand the default Workspace at epoch 1: the rotate materialises, then the PUT
    // throws, leaving a live pending record and no held key.
    gate.failBeforeCommit[defaultWs()] = 1;
    await expectLater(
      a.stack.enrolment.turnOnEncryption(passphrase: passphrase),
      throwsA(isA<SyncTransportException>()),
    );
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNull);
    expect(await a.pendingRotations.read(defaultWs()), contains(1));
    final strandCalls = gate.putKeyWrapsCallCount;

    // A resume runs (nothing else in flight, so it acquires the lock) and parks at the
    // publish of the stranded epoch-1 set — now holding the lock.
    final park = gate.armPark();
    final resume = a.stack.enrolment.resumePendingRotations(workspaceId: defaultWs());
    await park.reached;

    // A full ceremony fired while the resume holds the lock must WAIT for it — the
    // watch-item: a successful try-acquire chains onto the tail, so the ceremony does
    // not race the resume's in-flight publish/remove. While the resume is parked the
    // ceremony body must not start, so it drives no publish of its own.
    final ceremony = a.stack.enrolment.rotateWorkspaceKeys(passphrase: passphrase);
    await pumpEventQueue();
    expect(gate.putKeyWrapsCallCount, strandCalls + 1,
        reason: "only the resume's publish has run; the ceremony is blocked behind "
            'the in-flight resume. Unserialized, the ceremony would drive to its own '
            'putKeyWraps and this would be higher (the assertion that fails if the '
            'lock is removed)');

    // Release: the resume finishes epoch 1, then the ceremony runs and advances to
    // epoch 2 — sequentially, never having raced the resume's `put`.
    park.release();
    await resume;
    final epochs = await ceremony;
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNotNull,
        reason: 'the resume published the stranded epoch-1 key');
    expect(epochs[defaultWs()], 2,
        reason: 'the ceremony then rotated past the resumed epoch');
    expect(await a.workspaceKeys.keyFor(defaultWs(), 2), isNotNull);
    expect(await a.pendingRotations.read(defaultWs()), isEmpty);
  });

  test('the internal rotateWorkspaceKeys -> resume drain does not re-acquire the '
      'lock: a ceremony with a stranded record completes without deadlock (AC-3)',
      () async {
    final (a, gate) = await phone();
    final passphrase = (await a.enrolAsFirstDevice()).passphrase;

    // Strand only the *preferences* Workspace at epoch 1 (the default rotates fully),
    // so the next ceremony's internal drain has real work to do.
    gate.failBeforeCommit[prefsWs()] = 1;
    await expectLater(
      a.stack.enrolment.turnOnEncryption(passphrase: passphrase),
      throwsA(isA<SyncTransportException>()),
    );
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNotNull);
    expect(await a.pendingRotations.read(prefsWs()), contains(1));

    // The ceremony calls the *unlocked* `_resumePendingRotationsCore` at its top while
    // already holding the lock. If that internal call re-acquired the lock it would
    // either deadlock (a wait-mutex — caught by the timeout) or silently skip the
    // drain (this try-skip resume — caught by the epoch-1 assertion below).
    final epochs = await a.stack.enrolment
        .rotateWorkspaceKeys(passphrase: passphrase)
        .timeout(const Duration(seconds: 10));

    expect(await a.workspaceKeys.keyFor(prefsWs(), 1), isNotNull,
        reason: 'the internal drain finished the stranded prefs epoch 1 — it ran, so '
            'it neither deadlocked nor was skipped');
    expect(epochs, {defaultWs(): 2, prefsWs(): 2},
        reason: 'the fresh rotation then advanced both Workspaces past the resume');
    expect(await a.pendingRotations.read(prefsWs()), isEmpty);
  });

  test('the ceremony lock is released after a throw, so a failed ceremony does not '
      'wedge the next one', () async {
    final (a, gate) = await phone();
    final passphrase = (await a.enrolAsFirstDevice()).passphrase;

    // First ceremony throws on the default publish. The lock must release on the throw
    // (the tail swallows the error and drops the in-flight count), or every later
    // ceremony would queue behind a lock that never frees.
    gate.failBeforeCommit[defaultWs()] = 1;
    await expectLater(
      a.stack.enrolment.turnOnEncryption(passphrase: passphrase),
      throwsA(isA<SyncTransportException>()),
    );

    // A second ceremony acquires cleanly and completes, proving the lock was freed.
    // The failed ceremony threw on the *default* publish before reaching prefs, so it
    // left default materialised at epoch 1 (stranded) and prefs untouched. The second
    // ceremony drains the stranded default epoch 1, then rotates default 1 -> 2 and
    // prefs 0 -> 1.
    final epochs = await a.stack.enrolment
        .rotateWorkspaceKeys(passphrase: passphrase)
        .timeout(const Duration(seconds: 10));
    expect(epochs, {defaultWs(): 2, prefsWs(): 1});
    expect(await a.workspaceKeys.keyFor(defaultWs(), 1), isNotNull,
        reason: 'the resumed epoch-1 key from the failed ceremony was published');
  });
}
