/// One simulated device: its own store, its own keypairs, a shared fake clock.
///
/// Everything a real device has except a UI and a network — which is the point.
/// The PowerSync engine could not run here, so the delete-on-absent windows in
/// `docs/SYNC.md` were only ever verified by hand; an op log over a plain
/// transport interface can be driven end to end in a unit test.
///
/// A device here enrols the same way a real one does: it runs the whole
/// ceremony in `EnrolmentService`, including obtaining Root from the passphrase.
/// No key is ever handed from one [SimDevice] to another, which is what makes
/// "a second device enrols with the passphrase alone" a claim the harness can
/// actually make.
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:jeeves/sync/device_key_store.dart';
import 'package:jeeves/sync/enrolment.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/member_identity.dart';
import 'package:jeeves/sync/passphrase_policy.dart';
import 'package:jeeves/sync/preferences_store.dart';
import 'package:jeeves/sync/recovery_escrow.dart';
import 'package:jeeves/sync/reducer.dart';
import 'package:jeeves/sync/signal_listener.dart';
import 'package:jeeves/sync/signal_socket.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_transport.dart';

import 'fake_sync_server.dart';
import 'signal_probe.dart';

/// Argon2id costs for the harness.
///
/// Reduced so a test suite that enrols dozens of devices does not spend minutes
/// in a pure-Dart KDF. They are injected as *both* the parameters and the floor,
/// so every blob still goes through the same floor-checking code path
/// production uses — the check is exercised, only the cost is not.
const Argon2idParameters harnessKdfParameters = Argon2idParameters(
  memoryKib: 32,
  timeCost: 1,
  parallelism: 1,
);

/// A manually advanced clock. Two devices reading the same value produce
/// genuinely concurrent HLCs, which is what the field-grain merge cases need —
/// racing real time would make them flaky instead of concurrent.
class FakeClock {
  FakeClock(this.nowMs);

  int nowMs;

  void advance(int milliseconds) => nowMs += milliseconds;

  DateTime get asDateTime => DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true);
}

/// A manually advanced timer wheel, plus an instant [delay].
///
/// Everything in the signal path that would otherwise wait — the server's
/// keepalive cadence, the transport's idle deadline, the listener's backoff —
/// is driven from here, so the whole reconnect ladder is exercised with no real
/// sleeps and no timing flake.
class SimTimers {
  Duration _now = Duration.zero;
  final List<_SimTimer> _pending = [];

  /// Every backoff wait the listener asked for, in order — the schedule a test
  /// asserts against.
  final List<Duration> requestedDelays = [];

  Timer create(Duration duration, void Function() callback) {
    final timer = _SimTimer(_now + duration, callback);
    _pending.add(timer);
    return timer;
  }

  /// Waits on the wheel, not on the clock. Completing instantly instead would
  /// let the reconnect ladder spin through a whole retry cycle in microtasks,
  /// which is both untestable and a busy loop.
  Future<void> delay(Duration duration) {
    requestedDelays.add(duration);
    final waited = Completer<void>();
    create(duration, waited.complete);
    return waited.future;
  }

  /// Fire every timer due within [by], in order, letting queued events settle
  /// between fires — a timer callback that emits a frame must reach the
  /// listener before the next one fires.
  Future<void> advance(Duration by) async {
    final target = _now + by;
    while (true) {
      _pending.removeWhere((timer) => !timer.isActive);
      final due = _pending.where((timer) => timer.due <= target).toList()
        ..sort((a, b) => a.due.compareTo(b.due));
      if (due.isEmpty) break;
      final next = due.first;
      _pending.remove(next);
      _now = next.due;
      next.callback();
      await pumpEvents(8);
    }
    _now = target;
  }
}

class _SimTimer implements Timer {
  _SimTimer(this.due, this.callback);

  final Duration due;
  final void Function() callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  void cancel() => _active = false;

  @override
  int get tick => 0;
}

/// Full jitter that always picks the ceiling, so the schedule a test asserts is
/// the schedule the ladder defines rather than one sample from it.
class CeilingJitter implements Random {
  @override
  int nextInt(int max) => max - 1;

  @override
  bool nextBool() => true;

  @override
  double nextDouble() => 1;
}

/// The device's link to the server: where offline and fault injection live, so
/// [FakeSyncServer] stays a clean contract double.
///
/// It implements both credentials' surfaces because a *device* holds both — the
/// User's session and, after enrolment, its own. The server keeps them apart;
/// this is just where the network switch lives.
class DeviceLink implements SyncTransport, UserTransport {
  DeviceLink(
    this._userSession, {
    SimTimers? timers,
    this.keepaliveInterval = signalKeepaliveInterval,
  }) : timers = timers ?? SimTimers();

  final FakeSyncServerUserSession _userSession;

  /// Set by [completeMemberChallenge]. Typed as the concrete member session
  /// because the socket lives there: the raw frame stream is what fault
  /// injection needs, and only the member credential has one.
  FakeSyncServerMemberSession? _memberSession;

  /// Drives the transport's idle deadline, the half of the signal contract that
  /// lives on this side of the wire.
  final SimTimers timers;

  /// Held here rather than read off [_memberSession] so the idle deadline is
  /// known before enrolment — computing it must not be what reports that a
  /// device has no member credential yet.
  final Duration keepaliveInterval;

  bool online = true;

  /// Half-open: the socket is up, the server is still sending, and not one
  /// frame arrives — keepalives included. The failure mode the idle deadline
  /// exists for, and the only one that never announces itself.
  bool silent = false;

  /// Simulates a POST whose ops the server accepted but whose response never
  /// arrived. The device must re-send on the next sync, and that re-send must
  /// be a no-op — which is exactly what op-id dedupe is for.
  bool dropPostResponse = false;

  /// Holds a pull mid-flight, so a test can decide what arrives while a sync is
  /// already running.
  Completer<void>? pullGate;

  /// Fails the next [pullOps] — the poke-triggered sync failing on the one step
  /// a poke exists to trigger.
  Object? pullFailure;

  /// Read once per signal socket, exactly as [HttpSyncTransport] reads its
  /// injected provider: reassigning it and reconnecting is how a test proves a
  /// refreshed token is picked up by construction.
  Future<String> Function() bearerTokenProvider = () async => 'initial-token';

  /// Every value [bearerTokenProvider] returned, one entry per socket opened.
  final List<String> readBearerTokens = [];

  final List<StreamController<String>> _liveSignals = [];

  void _requireOnline() {
    if (!online) {
      throw const SyncTransportException.unreachable('device is offline');
    }
  }

  FakeSyncServerMemberSession get _member =>
      _memberSession ?? (throw StateError('device has not completed enrolment'));

  /// The network died under any open socket, and refuses to carry a new one.
  void dropSignals() {
    for (final relay in [..._liveSignals]) {
      if (!relay.isClosed) {
        relay.addError(const SyncTransportException.unreachable('device is offline'));
      }
    }
  }

  @override
  Future<MemberRecord> registerMember({
    required String memberId,
    required Uint8List signPk,
    required Uint8List kexPk,
  }) async {
    _requireOnline();
    return _userSession.registerMember(
      memberId: memberId,
      signPk: signPk,
      kexPk: kexPk,
    );
  }

  @override
  Future<List<MemberRecord>> fetchMembers(String workspaceId) async {
    _requireOnline();
    return _userSession.fetchMembers(workspaceId);
  }

  @override
  Future<RecoveryEscrowRecord?> fetchRecoveryEscrow(String workspaceId) async {
    _requireOnline();
    return _userSession.fetchRecoveryEscrow(workspaceId);
  }

  @override
  Future<RecoveryEscrowRecord> putRecoveryEscrow(
    String workspaceId,
    RecoveryEscrowRecord record,
  ) async {
    _requireOnline();
    return _userSession.putRecoveryEscrow(workspaceId, record);
  }

  @override
  Future<Uint8List> requestMemberChallenge(String memberId) async {
    _requireOnline();
    return _userSession.requestMemberChallenge(memberId);
  }

  @override
  Future<SyncTransport> completeMemberChallenge({
    required String memberId,
    required Uint8List nonce,
    required Uint8List signature,
  }) async {
    _requireOnline();
    _memberSession = await _userSession.completeMemberChallenge(
      memberId: memberId,
      nonce: nonce,
      signature: signature,
    ) as FakeSyncServerMemberSession;
    // The client syncs through the link, not around it, so `goOffline` keeps
    // working after enrolment.
    return this;
  }

  @override
  Future<List<OpAppendResult>> postOps(
    String workspaceId,
    List<Uint8List> envelopes,
  ) async {
    _requireOnline();
    final results = await _member.postOps(workspaceId, envelopes);
    if (dropPostResponse) {
      throw const SyncTransportException.unreachable('response lost after append');
    }
    return results;
  }

  @override
  Future<PullPage> pullOps(
    String workspaceId, {
    required int since,
    required int limit,
  }) async {
    _requireOnline();
    final gate = pullGate;
    if (gate != null) await gate.future;
    final failure = pullFailure;
    if (failure != null) {
      pullFailure = null;
      throw failure;
    }
    return _member.pullOps(workspaceId, since: since, limit: limit);
  }

  @override
  Stream<void> newSeqSignals(String workspaceId) => decodeSignalFrames(
        () async {
          _requireOnline();
          readBearerTokens.add(await bearerTokenProvider());
          final relay = StreamController<String>();
          // Through the member session: a device that has not enrolled has no
          // credential the socket would accept, and saying so here is the same
          // refusal the server makes at the handshake.
          final upstream = _member.signalFrames(workspaceId).listen(
            (frame) {
              if (!silent && !relay.isClosed) relay.add(frame);
            },
            onError: (Object error) {
              if (!relay.isClosed) relay.addError(error);
            },
            onDone: () {
              if (!relay.isClosed) relay.close();
            },
          );
          _liveSignals.add(relay);
          return SignalSocket(
            frames: relay.stream,
            close: () async {
              _liveSignals.remove(relay);
              await upstream.cancel();
              if (!relay.isClosed) await relay.close();
            },
          );
        },
        // The same three-missed-keepalives rule the real transport applies.
        idleDeadline: keepaliveInterval * 3,
        timerFactory: timers.create,
      );
}

class SimDevice {
  SimDevice._({
    required this.label,
    required this.userId,
    required this.database,
    required this.identity,
    required this.clock,
    required this.hlc,
    required this.registry,
    required this.client,
    required this.link,
    required this.keyStore,
    required this.enrolment,
    required this.outcome,
  }) : preferences = PreferencesStore(client: client, registry: registry);

  /// Build a device and run the enrolment ceremony on it.
  ///
  /// [passphrase] is null for the very first device of an account — the
  /// ceremony generates one and hands it back on [outcome], which is the only
  /// thing any later device is given.
  static Future<SimDevice> create({
    required String label,
    required String userId,
    required FakeSyncServer server,
    required FakeClock clock,
    String? memberId,
    Uint8List? seed,
    String? passphrase,
    Random? random,
    Argon2idParameters kdf = harnessKdfParameters,
    PassphrasePolicy passphrasePolicy = const PassphrasePolicy(),
    SimTimers? timers,
    Duration keepaliveInterval = signalKeepaliveInterval,
  }) async {
    // N devices means N stores, which is the whole premise. Drift's warning is
    // about several databases sharing one executor; each device here has its
    // own in-memory one, so there is nothing to race.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final database = SyncDatabase(NativeDatabase.memory());
    final identity = await MemberIdentity.generate(
      memberId: memberId,
      signSeed: seed,
      // A distinct KEX seed from the same deterministic source: using one seed
      // for two algorithms is exactly what F8's separate keys forbid.
      kexSeed: seed == null
          ? null
          : Uint8List.fromList([for (final byte in seed) (byte + 0x5A) % 256]),
    );
    final hlc = HlcClock(
      memberIdHex: identity.memberIdHex,
      nowMs: () => clock.nowMs,
    );
    final registry = CollectionRegistry(database);
    final simTimers = timers ?? SimTimers();
    final link = DeviceLink(
      // The clock the socket will run on is chosen here, and travels through
      // the ceremony onto the member session that actually subscribes.
      server.connectAsUser(
        userId,
        signalTimerFactory: simTimers.create,
        keepaliveInterval: keepaliveInterval,
      ),
      timers: simTimers,
      keepaliveInterval: keepaliveInterval,
    );
    final client = SyncClient(
      workspaceId: implicitWorkspaceId(userId),
      userId: userId,
      identity: identity,
      database: database,
      clock: hlc,
      reducer: Reducer(database, nowMs: () => clock.nowMs),
      now: () => clock.asDateTime,
    );
    final keyStore = InMemoryDeviceKeyStore();
    final enrolment = EnrolmentService(
      client: client,
      userTransport: link,
      keyStore: keyStore,
      nowMs: () => clock.nowMs,
      passphrasePolicy: passphrasePolicy,
      kdfParameters: kdf,
      kdfFloor: kdf,
      random: random ?? Random(label.codeUnitAt(0)),
    );
    final outcome = passphrase == null
        ? await enrolment.enrolFirstDevice()
        : await enrolment.enrolWithPassphrase(passphrase);

    return SimDevice._(
      label: label,
      userId: userId,
      database: database,
      identity: identity,
      clock: clock,
      hlc: hlc,
      registry: registry,
      client: client,
      link: link,
      keyStore: keyStore,
      enrolment: enrolment,
      outcome: outcome,
    );
  }

  final String label;
  final String userId;
  final SyncDatabase database;
  final MemberIdentity identity;
  final FakeClock clock;
  final HlcClock hlc;
  final CollectionRegistry registry;
  final SyncClient client;
  final DeviceLink link;
  final DeviceKeyStore keyStore;
  final EnrolmentService enrolment;

  /// What this device's enrolment produced — including the passphrase, which
  /// for the first device is the only copy that will ever exist.
  final EnrolmentOutcome outcome;

  final PreferencesStore preferences;

  SimTimers get timers => link.timers;

  /// The subscription lifecycle, on this device's deterministic hooks: the
  /// harness's timer wheel for backoff and a jitter that always picks the
  /// ceiling, so an asserted schedule is the ladder's, not a sample of it.
  late final SignalListener listener = SignalListener(
    client: client,
    transport: link,
    delay: link.timers.delay,
    random: CeilingJitter(),
  );

  void goOffline() {
    link.online = false;
    link.dropSignals();
  }

  void goOnline() => link.online = true;

  /// Half-open: the socket survives, and nothing crosses it. Distinguishable
  /// from healthy-idle only because a healthy server keeps sending keepalives.
  void goSilent() => link.silent = true;

  void goAudible() => link.silent = false;

  /// Push, then pull. There is no directory refresh: a MemberRegister is its
  /// author's op 1, so the pull hydrates the directory in order by itself.
  Future<void> sync() => client.sync();

  /// Sync, tolerating the offline case — for tests that just want everyone as
  /// converged as the network allows.
  Future<void> syncIfOnline() async {
    if (!link.online) return;
    await sync();
  }

  Future<void> close() async {
    await listener.dispose();
    await database.close();
  }
}
