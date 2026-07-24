import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/ritual.dart';

void main() {
  group('RitualPriority', () {
    test('weeklyReview outranks eveningShutdown outranks dailyPlanning', () {
      // Evening Shutdown outranks Daily Planning: "Shutdown wins" while a
      // session is open (ADR-0020).
      expect(
        RitualId.weeklyReview.priority,
        greaterThan(RitualId.eveningShutdown.priority),
      );
      expect(
        RitualId.eveningShutdown.priority,
        greaterThan(RitualId.dailyPlanning.priority),
      );
    });

    test('priorities are unique', () {
      final priorities = RitualId.values.map((r) => r.priority).toSet();
      expect(priorities.length, RitualId.values.length);
    });

    test('ritualsByPriority is sorted descending', () {
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
