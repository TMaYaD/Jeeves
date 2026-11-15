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

  test('equal planning and shutdown times (arrived by sync) do not crash', () {
    const sameTime = DprFacts(
      planningHour: 18,
      planningMinute: 0,
      shutdownHour: 18,
      shutdownMinute: 0,
      hasAnyItem: true,
      hasInboxOrNext: true,
    );
    expect(() => dprFiringEdgeAt(evening, sameTime), returnsNormally);
    expect(
      () => esFiringEdgeAt(
        evening,
        EsFacts(
          shutdownHour: 18,
          shutdownMinute: 0,
          planningHour: 18,
          planningMinute: 0,
          sessionIsOpen: true,
          openSessionStartedAt: DateTime(2026, 5, 19, 10),
        ),
      ),
      returnsNormally,
    );
  });

  test(
    'Daily Planning fires at its anchor and is idle from shutdown until the next anchor',
    () {
      expect(
        dprFiringEdgeAt(
          morning.subtract(const Duration(microseconds: 1)),
          ready,
        ),
        isNull,
      );
      expect(dprFiringEdgeAt(morning, ready), morning);
      expect(
        dprFiringEdgeAt(evening.subtract(const Duration(microseconds: 1)), ready),
        morning,
      );
      expect(dprFiringEdgeAt(evening, ready), isNull);
      expect(dprFiringEdgeAt(DateTime(2026, 5, 20, 23, 59), ready), isNull);
      final nextMorning = morning.add(const Duration(days: 1));
      expect(
        dprFiringEdgeAt(nextMorning.subtract(const Duration(minutes: 1)), ready),
        isNull,
      );
      expect(dprFiringEdgeAt(nextMorning, ready), nextMorning);
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
    'only a session started on the current calendar day counts as the plan',
    () {
      DprFacts facts(DateTime started, {bool open = false}) => DprFacts(
        planningHour: 8,
        planningMinute: 0,
        shutdownHour: 18,
        shutdownMinute: 0,
        hasAnyItem: true,
        hasInboxOrNext: true,
        latestSessionStartedAt: started,
        sessionIsOpen: open,
      );
      // Started in yesterday's Evening: not today's plan.
      expect(dprFiringEdgeAt(morning, facts(DateTime(2026, 5, 19, 20))), morning);
      expect(
        dprFiringEdgeAt(morning, facts(DateTime(2026, 5, 19, 23, 59, 59))),
        morning,
      );
      // Started at or after midnight today: it is.
      expect(dprFiringEdgeAt(morning, facts(DateTime(2026, 5, 20))), isNull);
      // The same frozen session ceases to count for tomorrow's projection.
      expect(
        dprFiringEdgeAt(
          morning.add(const Duration(days: 1)),
          facts(DateTime(2026, 5, 20, 7)),
        ),
        morning.add(const Duration(days: 1)),
      );
      // Any open session hides Daily Planning, however old.
      expect(
        dprFiringEdgeAt(morning, facts(DateTime(2026, 5, 18, 10), open: true)),
        isNull,
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
    expect(dprFiringEdgeAt(evening, ready), isNull);
  });

  test('Weekly Review is idle before it falls due', () {
    expect(wrFiringEdgeAt(morning, const WrFacts()), isNull);
    expect(
      wrFiringEdgeAt(
        morning.subtract(const Duration(microseconds: 1)),
        WrFacts(dueAt: morning),
      ),
      isNull,
    );
  });

  test('Weekly Review fires at the due instant and afresh every day after', () {
    final dueAt = DateTime(2026, 5, 18, 12);
    expect(wrFiringEdgeAt(dueAt, WrFacts(dueAt: dueAt)), dueAt);
    // Later the same day the edge is still the due instant.
    expect(
      wrFiringEdgeAt(DateTime(2026, 5, 18, 20), WrFacts(dueAt: dueAt)),
      dueAt,
    );
    // Each following day the edge is that day's start, which releases a swipe.
    expect(
      wrFiringEdgeAt(DateTime(2026, 5, 19, 9), WrFacts(dueAt: dueAt)),
      DateTime(2026, 5, 19),
    );
    expect(
      wrFiringEdgeAt(DateTime(2026, 5, 30, 9), WrFacts(dueAt: dueAt)),
      DateTime(2026, 5, 30),
    );
  });

  test('Weekly Review uses the latest firing content edge', () {
    final dueAt = morning.subtract(const Duration(days: 3));
    final content = morning.add(const Duration(hours: 1));
    expect(
      wrFiringEdgeAt(content, WrFacts(dueAt: dueAt, contentFiringEdge: content)),
      content,
    );
    expect(
      wrFiringEdgeAt(content, WrFacts(contentFiringEdge: content)),
      content,
    );
    // A content edge older than today's start loses to the daily edge.
    expect(
      wrFiringEdgeAt(
        content,
        WrFacts(
          dueAt: dueAt,
          contentFiringEdge: morning.subtract(const Duration(days: 1)),
        ),
      ),
      DateTime(morning.year, morning.month, morning.day),
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

  group('Evening Shutdown due time and firing edge', () {
    EsFacts open(DateTime started, {int available = 480}) => EsFacts(
      shutdownHour: 18,
      shutdownMinute: 0,
      sessionIsOpen: true,
      openSessionStartedAt: started,
      availableMinutes: available,
    );

    test('a session started before the shutdown time is due at it', () {
      final facts = open(DateTime(2026, 5, 20, 7, 30));
      expect(eveningShutdownDueAt(DateTime(2026, 5, 20, 7, 30), facts), evening);
      expect(
        eveningShutdownDueAt(DateTime(2026, 5, 20, 17, 59), facts),
        evening,
      );
    });

    test('a session started in the Evening is due after its available time', () {
      final started = DateTime(2026, 5, 20, 20);
      expect(
        eveningShutdownDueAt(started, open(started, available: 180)),
        DateTime(2026, 5, 20, 23),
      );
      // At the shutdown time itself the session counts as started in the Evening.
      expect(
        eveningShutdownDueAt(evening, open(evening, available: 60)),
        DateTime(2026, 5, 20, 19),
      );
    });

    test('an Evening session is due no later than the next planning time', () {
      final started = DateTime(2026, 5, 20, 23);
      expect(
        eveningShutdownDueAt(started, open(started, available: 720)),
        DateTime(2026, 5, 21, 8),
      );
    });

    test('exactly at and one microsecond before the due time', () {
      final started = DateTime(2026, 5, 20, 20);
      final facts = open(started, available: 180);
      final due = DateTime(2026, 5, 20, 23);
      expect(
        esFiringEdgeAt(due.subtract(const Duration(microseconds: 1)), facts),
        isNull,
      );
      expect(esFiringEdgeAt(due, facts), due);
    });

    test('the edge advances to each planning and shutdown time; no gap at '
        'midnight', () {
      final facts = open(DateTime(2026, 5, 19, 10));
      expect(esFiringEdgeAt(DateTime(2026, 5, 19, 23, 59), facts),
          DateTime(2026, 5, 19, 18));
      expect(esFiringEdgeAt(DateTime(2026, 5, 20), facts),
          DateTime(2026, 5, 19, 18));
      expect(esFiringEdgeAt(DateTime(2026, 5, 20, 8), facts),
          DateTime(2026, 5, 20, 8));
      expect(esFiringEdgeAt(evening, facts), evening);
    });
  });
}
