import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/providers/periodic_review_settings_provider.dart';
import 'package:jeeves/providers/system_trust_provider.dart';

void main() {
  group('nextNudgeBoundary', () {
    test('picks today\'s shutdown anchor when it is the earliest future '
        'boundary', () {
      final now = DateTime(2026, 6, 29, 10, 0);
      final next = nextNudgeBoundary(now,
          shutdownHour: 17, shutdownMinute: 0, weeklyReviewDueAt: null);
      expect(next, DateTime(2026, 6, 29, 17, 0));
    });

    test('falls back to the next day boundary once the anchor has passed', () {
      final now = DateTime(2026, 6, 29, 18, 0);
      final next = nextNudgeBoundary(now,
          shutdownHour: 17, shutdownMinute: 0, weeklyReviewDueAt: null);
      expect(next, DateTime(2026, 6, 30));
    });

    test('picks the weekly-review due instant when it is earliest', () {
      final now = DateTime(2026, 6, 29, 10, 0);
      // due = lastCompleted + 7d = 2026-06-29 12:00, earlier than the 17:00
      // shutdown anchor and tonight's midnight.
      final last = DateTime(2026, 6, 22, 12, 0);
      final next = nextNudgeBoundary(now,
          shutdownHour: 17, shutdownMinute: 0, weeklyReviewDueAt: last.add(const Duration(days: 7)));
      expect(next, DateTime(2026, 6, 29, 12, 0));
    });

    test('schedules subsequent weekly-review refires before other boundaries', () {
      final last = DateTime(2026, 6, 15, 12);
      final next = nextNudgeBoundary(DateTime(2026, 6, 29, 11),
          shutdownHour: 17, shutdownMinute: 0, weeklyReviewDueAt: last.add(const Duration(days: 7)));
      expect(next, DateTime(2026, 6, 29, 12));
    });

    test('ignores a weekly-review due instant that is already in the past', () {
      final now = DateTime(2026, 6, 29, 10, 0);
      final last = DateTime(2026, 6, 1, 9, 0); // due long ago
      final next = nextNudgeBoundary(now,
          shutdownHour: 23, shutdownMinute: 0, weeklyReviewDueAt: last.add(const Duration(days: 7)));
      // Past due instant is skipped; the 23:00 anchor is the earliest future one.
      expect(next, DateTime(2026, 6, 29, 23, 0));
    });
  });

  group('periodicReviewIsDueProvider — follows the due instant', () {
    ProviderContainer containerAt(DateTime now, DateTime? dueAt) =>
        ProviderContainer(overrides: [
          clockProvider.overrideWithValue(() => now),
          nudgeBoundaryTickProvider.overrideWithValue(0),
          weeklyReviewDueAtProvider.overrideWithValue(dueAt),
        ]);

    final due = DateTime(2026, 6, 30, 10, 0);

    test('is not due one second before the due instant', () {
      final container =
          containerAt(due.subtract(const Duration(seconds: 1)), due);
      addTearDown(container.dispose);
      expect(container.read(periodicReviewIsDueProvider), isFalse);
    });

    test('is due at the due instant and after it', () {
      for (final now in [due, due.add(const Duration(days: 30))]) {
        final container = containerAt(now, due);
        addTearDown(container.dispose);
        expect(container.read(periodicReviewIsDueProvider), isTrue);
      }
    });

    test('is not due when there is no due instant (no items yet)', () {
      final container = containerAt(DateTime(2026, 6, 29), null);
      addTearDown(container.dispose);
      expect(container.read(periodicReviewIsDueProvider), isFalse);
    });
  });
}
