/// Watching a poke stream without waiting on wall time.
///
/// Every hop in the signal path — opening the socket, the server's initial
/// poke, the transport's decode — is a microtask or a stream event, never a
/// delay. So a test never sleeps: it lets the queue drain with [pumpEvents] and
/// then asserts on what arrived.
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
