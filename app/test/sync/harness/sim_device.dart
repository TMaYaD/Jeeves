/// One simulated device: its own store, its own keypair, a shared fake clock.
///
/// Everything a real device has except a UI and a network — which is the point.
/// The PowerSync engine could not run here, so the delete-on-absent windows in
/// `docs/SYNC.md` were only ever verified by hand; an op log over a plain
/// transport interface can be driven end to end in a unit test.
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/member_identity.dart';
import 'package:jeeves/sync/preferences_store.dart';
import 'package:jeeves/sync/reducer.dart';
import 'package:jeeves/sync/signal_listener.dart';
import 'package:jeeves/sync/signal_socket.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_transport.dart';

import 'fake_sync_server.dart';
import 'signal_probe.dart';

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
class DeviceLink implements SyncTransport {
  DeviceLink(this._session, {SimTimers? timers}) : timers = timers ?? SimTimers();

  final FakeSyncServerSession _session;

  /// Drives the transport's idle deadline, the half of the signal contract that
  /// lives on this side of the wire.
  final SimTimers timers;

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
  }) async {
    _requireOnline();
    return _session.registerMember(memberId: memberId, signPk: signPk);
  }

  @override
  Future<List<MemberRecord>> fetchMembers(String workspaceId) async {
    _requireOnline();
    return _session.fetchMembers(workspaceId);
  }

  @override
  Future<List<OpAppendResult>> postOps(
    String workspaceId,
    List<Uint8List> envelopes,
  ) async {
    _requireOnline();
    final results = await _session.postOps(workspaceId, envelopes);
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
    return _session.pullOps(workspaceId, since: since, limit: limit);
  }

  @override
  Stream<void> newSeqSignals(String workspaceId) => decodeSignalFrames(
        () async {
          _requireOnline();
          readBearerTokens.add(await bearerTokenProvider());
          final relay = StreamController<String>();
          final upstream = _session.signalFrames(workspaceId).listen(
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
        idleDeadline: _session.keepaliveInterval * 3,
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
  }) : preferences = PreferencesStore(client: client, registry: registry);

  static Future<SimDevice> create({
    required String label,
    required String userId,
    required FakeSyncServer server,
    required FakeClock clock,
    String? memberId,
    Uint8List? seed,
    SimTimers? timers,
    Duration keepaliveInterval = signalKeepaliveInterval,
  }) async {
    // N devices means N stores, which is the whole premise. Drift's warning is
    // about several databases sharing one executor; each device here has its
    // own in-memory one, so there is nothing to race.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final database = SyncDatabase(NativeDatabase.memory());
    final identity = await MemberIdentity.generate(memberId: memberId, seed: seed);
    final hlc = HlcClock(
      memberIdHex: identity.memberIdHex,
      nowMs: () => clock.nowMs,
    );
    final registry = CollectionRegistry(database);
    final simTimers = timers ?? SimTimers();
    final link = DeviceLink(
      server.connectAs(
        userId,
        signalTimerFactory: simTimers.create,
        keepaliveInterval: keepaliveInterval,
      ),
      timers: simTimers,
    );
    final client = SyncClient(
      workspaceId: implicitWorkspaceId(userId),
      identity: identity,
      transport: link,
      database: database,
      clock: hlc,
      reducer: Reducer(database, nowMs: () => clock.nowMs),
      now: () => clock.asDateTime,
    );
    final device = SimDevice._(
      label: label,
      userId: userId,
      database: database,
      identity: identity,
      clock: clock,
      hlc: hlc,
      registry: registry,
      client: client,
      link: link,
    );
    await client.enrol();
    return device;
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

  /// A real client learns about new members before it can verify their ops, so
  /// the directory refresh is part of a sync, not a one-off at enrolment.
  Future<void> sync() async {
    await client.refreshMemberDirectory();
    await client.sync();
  }

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
