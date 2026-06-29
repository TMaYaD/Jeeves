import 'package:fake_async/fake_async.dart';
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
    test('its scheduled boundary Timer fires at last + 7d and flips to due', () {
      fakeAsync((async) {
        final last = DateTime(2026, 6, 23, 10, 0); // due exactly at 6/30 10:00
        var now = DateTime(2026, 6, 29, 10, 0); // one day before the boundary

        final container = ProviderContainer(overrides: [
          clockProvider.overrideWithValue(() => now),
          periodicReviewLastCompletedProvider.overrideWithValue(last),
        ]);
        addTearDown(container.dispose);

        // Building the provider schedules a Timer for the exact due instant.
        expect(container.read(periodicReviewIsDueProvider), isFalse);

        // One second short of the cutoff: the timer has not fired, still not due.
        now = DateTime(2026, 6, 30, 9, 59, 59);
        async.elapse(const Duration(days: 1) - const Duration(seconds: 1));
        expect(container.read(periodicReviewIsDueProvider), isFalse);

        // Cross the exact cutoff: the scheduled Timer fires invalidateSelf and
        // the predicate re-evaluates to due — no manual invalidation.
        now = DateTime(2026, 6, 30, 10, 0);
        async.elapse(const Duration(seconds: 1));
        expect(container.read(periodicReviewIsDueProvider), isTrue);
      });
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
