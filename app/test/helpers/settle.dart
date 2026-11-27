import 'package:flutter_test/flutter_test.dart';

/// Pumps bounded frames until [finder] matches.
///
/// A live Drift stream's first emission lands on the real event loop, so a
/// surface that only reads it once its own data has arrived needs a turn of
/// its own. [rounds] bounds the wait, so a stream that never delivers fails
/// the test rather than hanging it.
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int rounds = 20,
}) async {
  for (var i = 0; i < rounds && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Deterministic, wall-clock-free replacement for the ceremony tests' old
/// `runAsync(Future.delayed(200ms))` settle.
///
/// The ritual wizards (Daily Planning, Weekly Review, Evening Shutdown) load
/// their per-step snapshots through drift watch-streams that only emit on the
/// *real* event loop. The old settle waited a fixed 200ms for that emission —
/// identical wall-clock on every host and the single biggest cost in the
/// screen suite (#440). Draining the real event queue via [pumpEventQueue]
/// lets the in-memory write land in microseconds; the following `pumpAndSettle`
/// flushes the frames it produced.
///
/// If a future change makes a snapshot need more than one real-async turn,
/// raise [rounds] here rather than reinstating a sleep — a bounded drain stays
/// hang-attributable, which #440 cares about.
Future<void> settleWithRealAsync(WidgetTester tester, {int rounds = 1}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
  }
  await tester.pumpAndSettle();
}
