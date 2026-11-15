import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/time_context_provider.dart';

void main() {
  final now = DateTime(2026, 11, 15, 10);

  test('a From date 365 days ahead is capped', () {
    final delay = boundaryTimerDelay(now, now.add(const Duration(days: 365)));
    expect(delay, maxBoundaryTimerDelay);
    expect(delay.inMilliseconds, lessThan(2147483647));
  });

  test('a near boundary keeps its exact delay', () {
    expect(
      boundaryTimerDelay(now, now.add(const Duration(minutes: 90))),
      const Duration(minutes: 90),
    );
  });

  test('a past boundary fires immediately', () {
    expect(
      boundaryTimerDelay(now, now.subtract(const Duration(seconds: 5))),
      Duration.zero,
    );
  });
}
