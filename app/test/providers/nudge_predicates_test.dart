import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/nudge_predicates.dart';

void main() {
  final morning = DateTime(2026, 5, 20, 8);
  final evening = DateTime(2026, 5, 20, 18);
  const ready = DprFacts(
    planningHour: 8,
    planningMinute: 0,
    shutdownHour: 18,
    shutdownMinute: 0,
    hasAnyItem: true,
    hasInboxOrNext: true,
  );

  test(
    'Daily Planning fires exactly at its anchor and refires at shutdown',
    () {
      expect(
        dprFiringEdgeAt(
          morning.subtract(const Duration(microseconds: 1)),
          ready,
        ),
        isNull,
      );
      expect(dprFiringEdgeAt(morning, ready), morning);
      expect(dprFiringEdgeAt(evening, ready), evening);
    },
  );

  test(
    'live qualifying-session facts match timestamp facts at the same instant',
    () {
      for (final qualifying in [false, true]) {
        final live = DprFacts.forCurrentPeriod(
          planningHour: 8,
          planningMinute: 0,
          shutdownHour: 18,
          shutdownMinute: 0,
          hasAnyItem: true,
          hasInboxOrNext: true,
          qualifyingSessionExists: qualifying,
        );
        final snapshot = DprFacts(
          planningHour: 8,
          planningMinute: 0,
          shutdownHour: 18,
          shutdownMinute: 0,
          hasAnyItem: true,
          hasInboxOrNext: true,
          latestSessionStartedAt: qualifying ? DateTime(2026, 5, 20, 7) : null,
        );
        expect(
          dprFiringEdgeAt(morning, live),
          dprFiringEdgeAt(morning, snapshot),
        );
      }
    },
  );

  test(
    'session at the last shutdown anchor qualifies; a stale session does not',
    () {
      final previous = DateTime(2026, 5, 19, 18);
      DprFacts facts(DateTime started) => DprFacts(
        planningHour: 8,
        planningMinute: 0,
        shutdownHour: 18,
        shutdownMinute: 0,
        hasAnyItem: true,
        hasInboxOrNext: true,
        latestSessionStartedAt: started,
      );
      expect(dprFiringEdgeAt(morning, facts(previous)), isNull);
      expect(
        dprFiringEdgeAt(
          morning,
          facts(previous.subtract(const Duration(microseconds: 1))),
        ),
        morning,
      );
      // The same frozen session ceases to qualify for tomorrow's projection.
      expect(
        dprFiringEdgeAt(morning.add(const Duration(days: 1)), facts(previous)),
        morning.add(const Duration(days: 1)),
      );
    },
  );

  test('Daily Planning needs both onboarding and plannable content', () {
    for (final flags in [(false, true), (true, false), (false, false)]) {
      expect(
        dprFiringEdgeAt(
          morning,
          DprFacts(
            planningHour: 8,
            planningMinute: 0,
            shutdownHour: 18,
            shutdownMinute: 0,
            hasAnyItem: flags.$1,
            hasInboxOrNext: flags.$2,
          ),
        ),
        isNull,
      );
    }
  });

  test('Evening Shutdown requires an open session and its anchor', () {
    const open = EsFacts(
      shutdownHour: 18,
      shutdownMinute: 0,
      sessionIsOpen: true,
    );
    expect(
      esFiringEdgeAt(evening.subtract(const Duration(microseconds: 1)), open),
      isNull,
    );
    expect(esFiringEdgeAt(evening, open), evening);
    expect(
      esFiringEdgeAt(
        evening,
        const EsFacts(
          shutdownHour: 18,
          shutdownMinute: 0,
          sessionIsOpen: false,
        ),
      ),
      isNull,
    );
    expect(dprFiringEdgeAt(evening, ready), evening);
  });

  test(
    'Weekly Review fires at seven days and refires each elapsed seven-day period',
    () {
      final completed = morning.subtract(const Duration(days: 7));
      final facts = WrFacts(hasAnyItem: true, lastCompleted: completed);
      expect(
        wrFiringEdgeAt(
          morning.subtract(const Duration(microseconds: 1)),
          facts,
        ),
        isNull,
      );
      expect(wrFiringEdgeAt(morning, facts), morning);
      // Just before the second boundary the first edge still holds; at it,
      // the edge moves to the new period.
      final secondBoundary = morning.add(const Duration(days: 7));
      expect(
        wrFiringEdgeAt(
          secondBoundary.subtract(const Duration(microseconds: 1)),
          facts,
        ),
        morning,
      );
      expect(wrFiringEdgeAt(secondBoundary, facts), secondBoundary);
      expect(
        wrFiringEdgeAt(secondBoundary.add(const Duration(days: 3)), facts),
        secondBoundary,
      );
      expect(
        wrFiringEdgeAt(morning, const WrFacts(hasAnyItem: true)),
        DateTime(2026, 5, 20),
      );
      expect(wrFiringEdgeAt(morning, const WrFacts(hasAnyItem: false)), isNull);
    },
  );

  test('Weekly Review uses the latest firing content edge', () {
    final content = morning.add(const Duration(hours: 1));
    expect(
      wrFiringEdgeAt(
        content,
        WrFacts(
          hasAnyItem: true,
          lastCompleted: morning.subtract(const Duration(days: 7)),
          contentFiringEdge: content,
        ),
      ),
      content,
    );
    expect(
      wrFiringEdgeAt(
        content,
        WrFacts(
          hasAnyItem: true,
          lastCompleted: morning,
          contentFiringEdge: content,
        ),
      ),
      content,
    );
  });

  test('in-progress edge matches the same instant stored in UTC', () {
    expect(
      nudgeVisibleAt(morning, morning, const NudgeState(), morning.toUtc()),
      isFalse,
    );
  });

  test(
    'visibility respects dismiss, snooze expiry, and only the in-progress edge',
    () {
      expect(nudgeVisibleAt(morning, null, const NudgeState(), null), isFalse);
      expect(
        nudgeVisibleAt(morning, morning, const NudgeState(), null),
        isTrue,
      );
      expect(
        nudgeVisibleAt(
          morning,
          morning,
          NudgeState(dismissedAt: morning),
          null,
        ),
        isFalse,
      );
      expect(
        nudgeVisibleAt(
          evening,
          evening,
          NudgeState(dismissedAt: morning),
          null,
        ),
        isTrue,
      );
      expect(
        nudgeVisibleAt(
          morning,
          morning,
          NudgeState(snoozedUntil: evening),
          null,
        ),
        isFalse,
      );
      expect(
        nudgeVisibleAt(
          evening,
          morning,
          NudgeState(snoozedUntil: evening),
          null,
        ),
        isTrue,
      );
      expect(
        nudgeVisibleAt(morning, morning, const NudgeState(), morning),
        isFalse,
      );
      expect(
        nudgeVisibleAt(evening, evening, const NudgeState(), morning),
        isTrue,
      );
    },
  );
}
