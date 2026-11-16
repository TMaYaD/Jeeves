import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/plan_capacity.dart';

Todo _outcome({int? estimate, String? doneAt}) => Todo(
      id: 'id-$estimate-${doneAt != null}',
      title: 't',
      intent: 'next',
      userId: 'u',
      createdAt: DateTime.utc(2026, 11, 16),
      doneAt: doneAt,
      timeEstimate: estimate,
    );

void main() {
  final start = DateTime.utc(2026, 11, 16, 8);

  group('planTimeLeftMinutes', () {
    test('subtracts whole minutes elapsed since the session started', () {
      expect(
        planTimeLeftMinutes(
          sessionStartedAt: start,
          availableMinutes: 480,
          now: start.add(const Duration(minutes: 90, seconds: 59)),
        ),
        390,
      );
    });

    test('is zero once the available time has passed', () {
      expect(
        planTimeLeftMinutes(
          sessionStartedAt: start,
          availableMinutes: 60,
          now: start.add(const Duration(hours: 3)),
        ),
        0,
      );
    });
  });

  group('unfinishedPlanEstimateMinutes', () {
    test('counts estimate-less Outcomes at the default and skips done ones',
        () {
      final total = unfinishedPlanEstimateMinutes([
        _outcome(estimate: 60),
        _outcome(),
        _outcome(estimate: 45, doneAt: '2026-11-16T09:00:00.000Z'),
      ], 10);
      expect(total, 70);
    });
  });

  group('planExceedsTimeLeft', () {
    test('equal is within the time left', () {
      expect(
        planExceedsTimeLeft(
            unfinishedPlanMinutes: 60,
            candidateEstimateMinutes: 40,
            timeLeftMinutes: 100),
        isFalse,
      );
    });

    test('one minute over warns', () {
      expect(
        planExceedsTimeLeft(
            unfinishedPlanMinutes: 60,
            candidateEstimateMinutes: 41,
            timeLeftMinutes: 100),
        isTrue,
      );
    });
  });
}
