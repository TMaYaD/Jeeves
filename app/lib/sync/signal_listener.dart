/// Subscription lifecycle for the payload-free signal: connect, react, retry.
///
/// [SyncClient] stays a verb-set — capture, push, pull, reduce — and everything
/// that is a *policy* about staying subscribed lives here: when to reconnect,
/// how long to wait, and what a poke makes the client do. #553 drives
/// [start]/[stop] from app lifecycle and connectivity; until then the harness
/// drives them, which is what the acceptance criteria exercise.
library;

import 'dart:async';
import 'dart:math';

import 'signal_socket.dart';
import 'sync_client.dart';
import 'sync_transport.dart';

/// First backoff ceiling after a transport failure, doubling to
/// [signalMaxBackoff]. Full jitter picks uniformly below the ceiling, so a
/// fleet that lost the same server does not resubscribe in lockstep.
const Duration signalInitialBackoff = Duration(milliseconds: 500);
const Duration signalMaxBackoff = Duration(seconds: 30);

enum SignalListenerState {
  /// Never started, or stopped.
  idle,

  /// A socket is open but the initial poke has not arrived yet.
  connecting,

  /// Subscribed and acknowledged; the backoff ceiling is reset.
  live,

  /// A transport failure is being waited out.
  backingOff,

  /// The token was refused (4401). No timer, no retry: an expired token stays
  /// expired however patiently we retry. [onAuthRefreshed] is the only way out.
  authParked,

  /// The grant is gone (4403). Terminal — retrying cannot fix it, and only a
  /// fresh [start] (a new session or workspace) leaves this state.
  failed,
}

class SignalListener {
  SignalListener({
    required SyncClient client,
    required SyncTransport transport,
    Duration initialBackoff = signalInitialBackoff,
    Duration maxBackoff = signalMaxBackoff,
    Future<void> Function(Duration)? delay,
    Future<void> Function()? onSyncComplete,
    Random? random,
  })  : _client = client,
        _transport = transport,
        _initialBackoff = initialBackoff,
        _maxBackoff = maxBackoff,
        _delay = delay ?? Future<void>.delayed,
        _onSyncComplete = onSyncComplete,
        _random = random ?? Random(),
        _backoffCeiling = initialBackoff;

  final SyncClient _client;
  final SyncTransport _transport;

  /// Run after every completed pull, and swallowed if it throws. The pull tail is
  /// where a stranded key rotation heals itself (#617): a resume that fails
  /// transiently must not register as a *pull* failure on [syncFailures], so it is
  /// guarded here rather than folded into the sync it follows.
  final Future<void> Function()? _onSyncComplete;
  final Duration _initialBackoff;
  final Duration _maxBackoff;
  final Future<void> Function(Duration) _delay;
  final Random _random;

  final StreamController<Object> _syncFailures = StreamController<Object>.broadcast();
  final StreamController<SignalListenerState> _states =
      StreamController<SignalListenerState>.broadcast();

  StreamSubscription<void>? _signals;
  Duration _backoffCeiling;
  SignalListenerState _state = SignalListenerState.idle;

  /// Bumped whenever the current attempt is abandoned, so a backoff timer that
  /// was already in flight cannot resurrect a socket someone else replaced.
  int _generation = 0;

  bool _syncing = false;
  bool _pokePending = false;
  int _syncRunCount = 0;

  SignalListenerState get state => _state;

  Stream<SignalListenerState> get states => _states.stream;

  /// Failures of a poke-triggered sync. The listener does not retry — the next
  /// poke or a manual sync retries naturally — so this is how a caller learns
  /// that a sync it never asked for went wrong.
  ///
  /// Distinct from an integrity alarm, which is a persisted accusation about what
  /// the server served; this is a transport-level failure of one attempt, and it
  /// is not persisted anywhere.
  Stream<Object> get syncFailures => _syncFailures.stream;

  /// How many sync sequences have run since construction, counted as they
  /// start. The observable quantity behind the single-flight guarantee.
  int get syncRunCount => _syncRunCount;

  /// Sync now, then subscribe.
  ///
  /// The immediate sync is the poll-on-foreground fallback, and it is
  /// unconditional: it must not depend on the socket coming up, because the
  /// case it exists for is the socket never coming up.
  ///
  /// Calling [start] again without an intervening [stop] restarts rather than
  /// throws: [SignalListenerState.failed] documents a fresh [start] as its only
  /// exit, so a restart has to be legal. Any socket in hand is dropped first —
  /// the generation bump only orphans the old subscription's callbacks, it does
  /// not close the socket underneath them.
  Future<void> start() {
    _generation++;
    unawaited(_dropSocket());
    _backoffCeiling = _initialBackoff;
    _subscribe();
    return _runOrQueueSync();
  }

  Future<void> stop() async {
    _generation++;
    _setState(SignalListenerState.idle);
    await _dropSocket();
  }

  /// A fresh token is available: drop whatever we have and resubscribe with it.
  ///
  /// Live, backing off or parked, the move is the same — the socket in hand was
  /// opened with the old token, and the backoff ceiling is about a server that
  /// was unreachable, not about credentials.
  void onAuthRefreshed() {
    if (_state == SignalListenerState.idle || _state == SignalListenerState.failed) return;
    _generation++;
    unawaited(_dropSocket());
    _backoffCeiling = _initialBackoff;
    _subscribe();
  }

  Future<void> dispose() async {
    await stop();
    await _syncFailures.close();
    await _states.close();
  }

  // --- Subscription ----------------------------------------------------------

  void _subscribe() {
    final generation = _generation;
    _setState(SignalListenerState.connecting);
    _signals = _transport.newSeqSignals(_client.workspaceId).listen(
      (_) {
        if (generation != _generation) return;
        if (_state != SignalListenerState.live) {
          // The initial poke *is* the subscribe acknowledgement, so this is the
          // only honest definition of "the connection worked".
          _setState(SignalListenerState.live);
          _backoffCeiling = _initialBackoff;
        }
        unawaited(_runOrQueueSync());
      },
      onError: (Object error) => _onSocketLost(generation, error),
      onDone: () => _onSocketLost(
        generation,
        const SyncTransportException.unreachable('the signal stream ended'),
      ),
      cancelOnError: false,
    );
  }

  void _onSocketLost(int generation, Object error) {
    if (generation != _generation) return;
    _generation++;
    unawaited(_dropSocket());
    // Whatever was missed while away is covered by the next subscribe's initial
    // poke, so a pending flag from the dead connection is noise.
    _pokePending = false;

    final code = error is SyncTransportException ? error.statusCode : null;
    if (code == signalCloseForbidden) {
      _setState(SignalListenerState.failed);
      return;
    }
    if (code == signalCloseUnauthenticated) {
      _setState(SignalListenerState.authParked);
      return;
    }
    unawaited(_reconnectAfterBackoff());
  }

  Future<void> _reconnectAfterBackoff() async {
    _setState(SignalListenerState.backingOff);
    final ceiling = _backoffCeiling;
    _backoffCeiling = Duration(
      milliseconds: min(ceiling.inMilliseconds * 2, _maxBackoff.inMilliseconds),
    );
    final generation = _generation;
    await _delay(Duration(milliseconds: _random.nextInt(ceiling.inMilliseconds + 1)));
    if (generation != _generation) return;
    _subscribe();
  }

  Future<void> _dropSocket() async {
    final open = _signals;
    _signals = null;
    await open?.cancel();
  }

  void _setState(SignalListenerState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  // --- The sync a poke means -------------------------------------------------

  /// Single-flight with a dirty flag: pokes arriving mid-sequence collapse into
  /// exactly one follow-up run, mirroring the server's own coalescing.
  Future<void> _runOrQueueSync() async {
    if (_syncing) {
      _pokePending = true;
      return;
    }
    _syncing = true;
    try {
      while (true) {
        _pokePending = false;
        await _runSync();
        if (!_pokePending) break;
      }
    } on Object catch (error) {
      // No retry here: a second retry loop would have nothing to tune it
      // against and would fight the reconnect ladder. The next poke or a manual
      // sync retries naturally.
      _pokePending = false;
      if (!_syncFailures.isClosed) _syncFailures.add(error);
    } finally {
      _syncing = false;
    }
  }

  /// A pull, and only a pull. A poke carries no outbox implication — pokes are
  /// inbound news, so there is nothing to push in response to one.
  ///
  /// No directory refresh precedes it, because there is no directory to refresh:
  /// a Member's key is learned from its own Root-signed MemberRegister, which is
  /// that author's op 1, and `seq` ordering guarantees the register is pulled
  /// before any of that author's content. The pull hydrates the directory in
  /// order by itself, which is why `SyncClient` has no `refreshMemberDirectory`
  /// for this to call. Ops from a Member whose registration has not been
  /// verified still quarantine as `member_not_chained_to_root`, and terminally:
  /// the release scan re-admits chain-gap refusals only, so an unchained author's
  /// content stays refused until #549 opens membership up. A refresh here could
  /// not have prevented it either way.
  Future<void> _runSync() async {
    _syncRunCount++;
    await _client.pull();
    final onSyncComplete = _onSyncComplete;
    if (onSyncComplete != null) {
      try {
        await onSyncComplete();
      } on Object {
        // The pull itself succeeded; a post-pull hook that failed is its own
        // concern and retries on the next pull. Letting it throw here would mark a
        // healthy sync as failed and fight the reconnect ladder.
      }
    }
  }
}
