/// End-to-end: a change on one device reaches another with no poll.
///
/// This file is the acceptance criteria of #552. The live app still runs on
/// PowerSync until #553, so the two-emulator half of the AC cannot be staged
/// here; the harness alternative the issue names is what binds. The HTTP path
/// is held to the same contract by `backend/tests/sync/test_signal_socket.py`
/// and the case-for-case twin in `fake_sync_server_contract_test.dart`.
///
/// Nothing in this file sleeps. Keepalives, the idle deadline and the backoff
/// ladder all run on `SimTimers`, so the reconnect behaviour is asserted as a
/// schedule rather than sampled from a race.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/signal_listener.dart';
import 'package:jeeves/sync/signal_socket.dart';
import 'package:jeeves/sync/sync_transport.dart';
import 'package:uuid/uuid.dart';

import 'harness/signal_probe.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';

const String _userId = 'signal-user';

/// Short enough to keep the arithmetic in the tests readable; the wheel is
/// manual, so the value only has to be a round number.
const Duration _keepaliveInterval = Duration(seconds: 10);

void main() {
  late SimWorkspace workspace;

  setUp(() async {
    workspace = await SimWorkspace.create(
      userId: _userId,
      keepaliveInterval: _keepaliveInterval,
    );
  });

  tearDown(() => workspace.close());

  // --- AC 1: an edit on A appears on B with no poll on B ---------------------

  test('an edit on A reaches B with no sync call on B', () async {
    await workspace.b.listener.start();
    await pumpEvents();

    await workspace.a.preferences.set('theme', '"dark"');
    await workspace.a.sync();
    await pumpEvents();

    // No `b.sync()` anywhere: the poke did it.
    expect(await workspace.b.preferences.get('theme'), '"dark"');
  });

  test("a newly enrolled member's first ops land instead of quarantining",
      () async {
    await workspace.b.listener.start();
    await pumpEvents();

    // C enrols after B subscribed, so B has never heard of it. Nothing refreshes
    // a directory here — C's MemberRegister is its own op 1, and `seq` ordering
    // puts it ahead of C's content op in the very page the poke provokes, so the
    // pull learns C's key before it needs it. This is the case that would break
    // if the register were not pinned to author_seq 1: the content op would
    // quarantine as `member_not_chained_to_root` and the cursor would move past
    // it for good.
    final c = await SimDevice.create(
      label: 'C',
      userId: _userId,
      server: workspace.server,
      clock: workspace.clock,
      timers: workspace.timers,
      keepaliveInterval: _keepaliveInterval,
      memberId: const Uuid().v5(jeevesWorkspaceNamespace, 'sim/device/late'),
      seed: Uint8List.fromList(List<int>.generate(32, (byte) => (byte + 7) % 256)),
      // A later device enrols with the passphrase and nothing else — the Root in
      // the escrow slot is A's, and minting a fresh one would be refused.
      passphrase: workspace.passphrase,
    );
    await c.preferences.set('font', '"serif"');
    await c.sync();
    await pumpEvents();

    expect(await workspace.b.preferences.get('font'), '"serif"');
    expect(await workspace.b.client.quarantined(), isEmpty);
    await c.close();
  });

  // --- Coalescing -----------------------------------------------------------

  test('pokes arriving mid-sync collapse into exactly one follow-up run',
      () async {
    await workspace.b.listener.start();
    await pumpEvents();
    final runsBeforeGate = workspace.b.listener.syncRunCount;

    // Hold B's next pull open, so every poke A produces lands while a sync is
    // already in flight. (This gate is unrelated to the listener's `authParked`
    // state — it is the harness holding a request, not a credential problem.)
    final gate = Completer<void>();
    workspace.b.link.pullGate = gate;

    await workspace.a.preferences.set('one', '1');
    await workspace.a.sync();
    await pumpEvents();

    for (var index = 0; index < 5; index++) {
      await workspace.a.preferences.set('key$index', '"$index"');
      await workspace.a.sync();
      await pumpEvents();
    }

    workspace.b.link.pullGate = null;
    gate.complete();
    await pumpEvents();

    // One run for the poke that opened the gated sequence, one follow-up for
    // everything that arrived while it was held — no matter how many pokes that
    // was. The initial poke's run is excluded by construction: it finished
    // before the gate went up.
    expect(workspace.b.listener.syncRunCount - runsBeforeGate, 2);
    expect(await workspace.b.preferences.get('key4'), '"4"');
  });

  // --- Error policy ----------------------------------------------------------

  test('a failing poke-triggered sync surfaces and is not retried', () async {
    await workspace.b.listener.start();
    await pumpEvents();

    final failures = <Object>[];
    workspace.b.listener.syncFailures.listen(failures.add);

    workspace.b.link.pullFailure =
        const SyncTransportException(500, 'the server fell over');
    await workspace.a.preferences.set('theme', '"dark"');
    await workspace.a.sync();
    await pumpEvents();

    expect(failures, hasLength(1));
    final runsAfterFailure = workspace.b.listener.syncRunCount;

    // No retry loop of its own: nothing happens until the next poke.
    await pumpEvents();
    expect(workspace.b.listener.syncRunCount, runsAfterFailure);

    // And the next poke runs cleanly — the single-flight flag was released.
    await workspace.a.preferences.set('font', '"serif"');
    await workspace.a.sync();
    await pumpEvents();
    expect(workspace.b.listener.syncRunCount, runsAfterFailure + 1);
    expect(await workspace.b.preferences.get('font'), '"serif"');
  });

  // --- Reconnect -------------------------------------------------------------

  test('reconnecting after network loss delivers what was missed', () async {
    await workspace.b.listener.start();
    await pumpEvents();

    workspace.b.goOffline();
    await pumpEvents();
    expect(workspace.b.listener.state, SignalListenerState.backingOff);

    await workspace.a.preferences.set('theme', '"dark"');
    await workspace.a.sync();
    await pumpEvents();
    expect(await workspace.b.preferences.get('theme'), isNull,
        reason: 'no poke can reach an offline device');

    workspace.b.goOnline();
    await workspace.timers.advance(_keepaliveInterval);
    await pumpEvents();

    // The resubscribe's initial poke is the catch-up trigger: nothing on the
    // server remembers what B missed, and nothing has to.
    expect(workspace.b.listener.state, SignalListenerState.live);
    expect(await workspace.b.preferences.get('theme'), '"dark"');
  });

  test('transport failures ride the backoff ladder and reset on success',
      () async {
    await workspace.b.listener.start();
    await pumpEvents();
    workspace.timers.requestedDelays.clear();

    // Full jitter picks the ceiling here (CeilingJitter), so the recorded waits
    // are the ladder itself: 500ms, then double, then double again.
    workspace.b.goOffline();
    await pumpEvents();
    expect(workspace.timers.requestedDelays, [const Duration(milliseconds: 500)]);
    expect(workspace.b.listener.state, SignalListenerState.backingOff);

    await workspace.timers.advance(const Duration(milliseconds: 500));
    await pumpEvents();
    await workspace.timers.advance(const Duration(seconds: 1));
    await pumpEvents();
    expect(workspace.timers.requestedDelays, [
      const Duration(milliseconds: 500),
      const Duration(seconds: 1),
      const Duration(seconds: 2),
    ]);

    workspace.b.goOnline();
    await workspace.timers.advance(const Duration(seconds: 2));
    await pumpEvents();
    expect(workspace.b.listener.state, SignalListenerState.live);

    // Reset on a successful subscribe, defined as the initial poke arriving.
    workspace.timers.requestedDelays.clear();
    workspace.b.goOffline();
    await pumpEvents();
    expect(workspace.timers.requestedDelays, [const Duration(milliseconds: 500)]);
  });

  test('restarting without a stop leaves one socket, not two', () async {
    await workspace.b.listener.start();
    await pumpEvents();
    expect(workspace.server.signalSubscriberCount(workspace.workspaceId), 1);

    // A restart is legal — `failed` names a fresh `start` as its only exit — so
    // it has to drop the socket in hand rather than orphan it. Bumping the
    // generation only silences the old subscription's callbacks; the socket
    // underneath would stay open and keep taking pokes.
    await workspace.b.listener.start();
    await pumpEvents();

    expect(workspace.server.signalSubscriberCount(workspace.workspaceId), 1);
    expect(workspace.b.listener.state, SignalListenerState.live);
  });

  test('a 4403 refusal is terminal and schedules nothing', () async {
    // A grant that is gone cannot be retried into existence.
    final probe = SignalListener(
      client: workspace.b.client,
      transport: _ForeignWorkspaceTransport(workspace.b.link),
      delay: workspace.timers.delay,
    );
    await probe.start();
    await pumpEvents();

    expect(probe.state, SignalListenerState.failed);
    expect(workspace.timers.requestedDelays, isEmpty);
    await probe.dispose();
  });

  test('a 4401 refusal parks until the token is refreshed', () async {
    final refusing = _RefusingTransport(workspace.b.link);
    final probe = SignalListener(
      client: workspace.b.client,
      transport: refusing,
      delay: workspace.timers.delay,
    );
    await probe.start();
    await pumpEvents();

    expect(probe.state, SignalListenerState.authParked);
    expect(workspace.timers.requestedDelays, isEmpty,
        reason: 'an expired token stays expired however long we wait');

    // The refreshed token is picked up because the socket re-reads the provider
    // on every subscribe, not because anyone hands it to the listener.
    workspace.b.link.bearerTokenProvider = () async => 'refreshed-token';
    refusing.refuse = false;
    probe.onAuthRefreshed();
    await pumpEvents();

    expect(probe.state, SignalListenerState.live);
    expect(workspace.b.link.readBearerTokens.last, 'refreshed-token');
    await probe.dispose();
  });

  test('a silent socket trips the idle deadline and reconnects', () async {
    await workspace.b.listener.start();
    await pumpEvents();

    // Half-open: the socket is up and nothing crosses it. Keepalives are what
    // make this distinguishable from a healthy idle connection.
    workspace.b.goSilent();
    await workspace.timers.advance(_keepaliveInterval * 3);
    await pumpEvents();
    expect(workspace.b.listener.state, SignalListenerState.backingOff);

    workspace.b.goAudible();
    await workspace.timers.advance(const Duration(milliseconds: 500));
    await pumpEvents();
    expect(workspace.b.listener.state, SignalListenerState.live);
  });

  test('a healthy idle socket is kept alive rather than reconnected', () async {
    await workspace.b.listener.start();
    await pumpEvents();

    // The complement of the case above: the same elapsed time, but the server
    // is still sending keepalives, so the deadline never fires.
    await workspace.timers.advance(_keepaliveInterval * 5);
    await pumpEvents();

    expect(workspace.b.listener.state, SignalListenerState.live);
    expect(
      workspace.server.emittedSignalFrames[workspace.workspaceId],
      contains(keepaliveFrame),
    );
  });

  test('a frame that is neither a poke nor the keepalive is a protocol violation',
      () async {
    final probe = PokeRecorder(
      _ChattyTransport(workspace.b.link).newSeqSignals(workspace.workspaceId),
    );
    await pumpEvents();

    expect(
      probe.errors.single,
      isA<SyncTransportException>()
          .having((e) => e.statusCode, 'statusCode', signalCloseProtocolError),
    );
    await probe.cancel();
  });
}

/// Subscribes to a Workspace this device has no grant for.
class _ForeignWorkspaceTransport extends _DelegatingTransport {
  _ForeignWorkspaceTransport(super.inner);

  @override
  Stream<void> newSeqSignals(String workspaceId) =>
      inner.newSeqSignals(implicitWorkspaceId('someone-else'));
}

/// A server that refuses the token until it is told the token was refreshed.
class _RefusingTransport extends _DelegatingTransport {
  _RefusingTransport(super.inner);

  bool refuse = true;

  @override
  Stream<void> newSeqSignals(String workspaceId) => refuse
      ? Stream<void>.error(
          const SyncTransportException(signalCloseUnauthenticated, 'token expired'),
        )
      : inner.newSeqSignals(workspaceId);
}

/// A server that says something. Anything the client cannot name is a violation
/// of the two-frame grammar, not an extension to be tolerated.
class _ChattyTransport extends _DelegatingTransport {
  _ChattyTransport(super.inner);

  @override
  Stream<void> newSeqSignals(String workspaceId) => decodeSignalFrames(
        () async => SignalSocket(
          frames: Stream<String>.value('here is some news for you'),
          close: () async {},
        ),
      );
}

/// Wraps only the member-credential surface, because that is the whole of
/// [SyncTransport]: the registry and escrow calls live on [UserTransport], which
/// has no socket to interfere with.
abstract class _DelegatingTransport implements SyncTransport {
  _DelegatingTransport(this.inner);

  final SyncTransport inner;

  @override
  Future<List<OpAppendResult>> postOps(String workspaceId, List<Uint8List> envelopes) =>
      inner.postOps(workspaceId, envelopes);

  @override
  Future<PullPage> pullOps(String workspaceId, {required int since, required int limit}) =>
      inner.pullOps(workspaceId, since: since, limit: limit);
}
