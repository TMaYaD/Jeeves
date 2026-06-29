import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/providers/periodic_review_settings_provider.dart';

void main() {
  group('nextNudgeBoundary', () {
    test('picks today\'s shutdown anchor when it is the earliest future '
        'boundary', () {
      final now = DateTime(2026, 6, 29, 10, 0);
      final next = nextNudgeBoundary(now,
          shutdownHour: 17, shutdownMinute: 0, weeklyReviewLastCompleted: null);
      expect(next, DateTime(2026, 6, 29, 17, 0));
    });

    test('falls back to the next day boundary once the anchor has passed', () {
      final now = DateTime(2026, 6, 29, 18, 0);
      final next = nextNudgeBoundary(now,
          shutdownHour: 17, shutdownMinute: 0, weeklyReviewLastCompleted: null);
      expect(next, DateTime(2026, 6, 30));
    });

    test('picks the weekly-review due instant when it is earliest', () {
      final now = DateTime(2026, 6, 29, 10, 0);
      // due = lastCompleted + 7d = 2026-06-29 12:00, earlier than the 17:00
      // shutdown anchor and tonight's midnight.
      final last = DateTime(2026, 6, 22, 12, 0);
      final next = nextNudgeBoundary(now,
          shutdownHour: 17, shutdownMinute: 0, weeklyReviewLastCompleted: last);
      expect(next, DateTime(2026, 6, 29, 12, 0));
    });

    test('ignores a weekly-review due instant that is already in the past', () {
      final now = DateTime(2026, 6, 29, 10, 0);
      final last = DateTime(2026, 6, 1, 9, 0); // due long ago
      final next = nextNudgeBoundary(now,
          shutdownHour: 23, shutdownMinute: 0, weeklyReviewLastCompleted: last);
      // Past due instant is skipped; the 23:00 anchor is the earliest future one.
      expect(next, DateTime(2026, 6, 29, 23, 0));
    });
  });

  group('periodicReviewIsDueProvider — reactive to the cadence boundary', () {
    test('flips false→true when the clock crosses last + 7d', () {
      var now = DateTime(2026, 6, 29, 10, 0);
      final last = DateTime(2026, 6, 23, 10, 0); // due at 2026-06-30 10:00

      final container = ProviderContainer(overrides: [
        clockProvider.overrideWithValue(() => now),
        periodicReviewLastCompletedProvider.overrideWithValue(last),
      ]);
      addTearDown(container.dispose);

      // One day before the cadence boundary: not yet due.
      expect(container.read(periodicReviewIsDueProvider), isFalse);

      // Advance the clock past the boundary; the predicate re-evaluates to due.
      now = DateTime(2026, 6, 30, 10, 1);
      container.invalidate(periodicReviewIsDueProvider);
      expect(container.read(periodicReviewIsDueProvider), isTrue);
    });

    test('is due immediately when never completed', () {
      final container = ProviderContainer(overrides: [
        clockProvider.overrideWithValue(() => DateTime(2026, 6, 29)),
        periodicReviewLastCompletedProvider.overrideWithValue(null),
      ]);
      addTearDown(container.dispose);
      expect(container.read(periodicReviewIsDueProvider), isTrue);
    });
  });
}
