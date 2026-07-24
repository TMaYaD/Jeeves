import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/ritual.dart';

void main() {
  group('RitualPriority', () {
    test('ritualsByPriority ranks weeklyReview > dailyPlanning > eveningShutdown, '
        'sorted descending', () {
      expect(
        RitualId.weeklyReview.priority,
        greaterThan(RitualId.dailyPlanning.priority),
      );
      expect(
        RitualId.dailyPlanning.priority,
        greaterThan(RitualId.eveningShutdown.priority),
      );
      // The derived list reflects that ranking, sorted descending (strict
      // ordering also proves the priorities are all distinct).
      for (var i = 0; i < ritualsByPriority.length - 1; i++) {
        expect(
          ritualsByPriority[i].priority,
          greaterThan(ritualsByPriority[i + 1].priority),
        );
      }
    });

    test('ritualsByPriority contains each RitualId exactly once', () {
      expect(ritualsByPriority.length, RitualId.values.length);
      expect(ritualsByPriority.toSet(), RitualId.values.toSet());
    });

    test('keyPrefix matches existing per-Ritual storage namespaces', () {
      expect(RitualId.dailyPlanning.keyPrefix, 'planning');
      expect(RitualId.eveningShutdown.keyPrefix, 'shutdown');
      expect(RitualId.weeklyReview.keyPrefix, 'periodic_review');
    });
  });
}
