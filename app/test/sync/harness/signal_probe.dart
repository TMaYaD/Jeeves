/// Watching a stream without waiting on wall time.
///
/// Every hop in the signal path — opening the socket, the server's initial
/// poke, the transport's decode — is a microtask or a stream event, never a
/// delay. So a test never sleeps: it lets the queue drain with [pumpEvents] and
/// then asserts on what arrived. A Drift-driven stream is the same shape of
/// question one step further out — "has the emission landed?" is a condition,
/// not a duration — which is what [waitUntil] is for.
library;

import 'dart:async';

/// Let queued microtasks and stream events run to completion. The default is
/// generous because a poke-triggered sync is a directory refresh, a paged pull
/// and a handful of Drift writes deep.
Future<void> pumpEvents([int rounds = 32]) async {
  for (var round = 0; round < rounds; round++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Poll until [condition] holds, or fail rather than assert on a stale value.
///
/// A fixed sleep is a bet that the emission lands inside it; on a loaded runner
/// that bet is the flake. The timeout is generous because it only ever costs
/// wall time when the condition is genuinely never met.
Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met within $timeout', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Counts pokes and captures errors from one `newSeqSignals` subscription.
class PokeRecorder {
  PokeRecorder(Stream<void> signals) {
    _subscription = signals.listen(
      (_) => pokeCount++,
      onError: errors.add,
      onDone: () => done = true,
    );
  }

  int pokeCount = 0;
  bool done = false;
  final List<Object> errors = [];

  late final StreamSubscription<void> _subscription;

  Future<void> cancel() => _subscription.cancel();
}
