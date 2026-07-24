import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/ceremony_in_progress_provider.dart';
import 'package:jeeves/providers/nudge_provider.dart';
import 'package:jeeves/providers/nudge_triggers.dart';

void main() {
  group('NudgeState', () {
    test('copyWith leaves existing values when no args passed', () {
      final ts = DateTime(2026, 5, 22, 10);
      final s = NudgeState(dismissedAt: ts, snoozedUntil: ts);
      expect(s.copyWith(), s);
    });

    test('clear flags drop the corresponding field', () {
      final ts = DateTime(2026, 5, 22, 10);
      final s = NudgeState(dismissedAt: ts, snoozedUntil: ts);
      expect(s.copyWith(clearDismissedAt: true).dismissedAt, isNull);
      expect(s.copyWith(clearSnoozedUntil: true).snoozedUntil, isNull);
    });

    test('equality compares both fields', () {
      final a = NudgeState(
        dismissedAt: DateTime(2026, 5, 22, 10),
        snoozedUntil: DateTime(2026, 5, 22, 11),
      );
      final b = NudgeState(
        dismissedAt: DateTime(2026, 5, 22, 10),
        snoozedUntil: DateTime(2026, 5, 22, 11),
      );
      expect(a, equals(b));
    });
  });

  group('nudgeVisibleProvider', () {
    /// Builds a container that lets the test control:
    /// - whether [ritual]'s Trigger is currently firing (via [firingEdge])
    /// - whether [ritual] is in-progress (via [inProgress])
    /// - the persisted [NudgeState] for [ritual]
    ///
    /// Other Rituals default to "not firing" so they don't pollute queue
    /// tests. Pass `firingEdges` directly to address them.
    ProviderContainer makeContainer({
      DateTime? firingEdge,
      Map<RitualId, DateTime?> firingEdges = const {},
      bool inProgress = false,
      Set<RitualId> inProgressSet = const {},
      NudgeState state = const NudgeState(),
      RitualId ritual = RitualId.dailyPlanning,
    }) {
      final edges = <RitualId, DateTime?>{
        ritual: firingEdge,
        ...firingEdges,
      };
      final inProgressMembers = {
        if (inProgress) ritual,
        ...inProgressSet,
      };
      return ProviderContainer(overrides: [
        nudgePrefsReadyProvider.overrideWith((ref) => true),
        mostRecentFiringEdgeProvider.overrideWith(
          (ref, r) => edges[r],
        ),
        ceremonyInProgressForProvider.overrideWith(
          (ref, r) => inProgressMembers.contains(r),
        ),
        nudgeStateProvider.overrideWith(
          (ref, r) => r == ritual ? state : const NudgeState(),
        ),
      ]);
    }

    test('not visible when no Trigger is firing', () {
      final c = makeContainer(firingEdge: null);
      addTearDown(c.dispose);
      expect(c.read(nudgeVisibleProvider(RitualId.dailyPlanning)), isFalse);
    });

    test('visible when a Trigger is firing and state is clean', () {
      final c = makeContainer(firingEdge: DateTime(2026, 5, 22, 0));
      addTearDown(c.dispose);
      expect(c.read(nudgeVisibleProvider(RitualId.dailyPlanning)), isTrue);
    });

    test('not visible while synced prefs are still loading', () {
      // Same firing-edge scenario as the previous test, but with the
      // readiness gate flipped off — guard must take precedence.
      final c = ProviderContainer(overrides: [
        nudgePrefsReadyProvider.overrideWith((ref) => false),
        mostRecentFiringEdgeProvider.overrideWith(
          (ref, r) => DateTime(2026, 5, 22, 0),
        ),
        ceremonyInProgressForProvider.overrideWith((ref, r) => false),
        nudgeStateProvider.overrideWith((ref, r) => const NudgeState()),
      ]);
      addTearDown(c.dispose);
      expect(c.read(nudgeVisibleProvider(RitualId.dailyPlanning)), isFalse);
    });

    test('not visible while the Ceremony is in progress', () {
      final c = makeContainer(
        firingEdge: DateTime(2026, 5, 22, 0),
        inProgress: true,
      );
      addTearDown(c.dispose);
      expect(c.read(nudgeVisibleProvider(RitualId.dailyPlanning)), isFalse);
    });

    test('not visible while snooze is active', () {
      final future = DateTime.now().add(const Duration(hours: 1));
      final c = makeContainer(
        firingEdge: DateTime(2026, 5, 22, 0),
        state: NudgeState(snoozedUntil: future),
      );
      addTearDown(c.dispose);
      expect(c.read(nudgeVisibleProvider(RitualId.dailyPlanning)), isFalse);
    });

    test('visible again once snooze has expired', () {
      final past = DateTime.now().subtract(const Duration(hours: 1));
      final c = makeContainer(
        firingEdge: DateTime(2026, 5, 22, 0),
        state: NudgeState(snoozedUntil: past),
      );
      addTearDown(c.dispose);
      expect(c.read(nudgeVisibleProvider(RitualId.dailyPlanning)), isTrue);
    });

    test('not visible when dismissed after the current firing edge', () {
      final firing = DateTime(2026, 5, 22, 0);
      final dismissed = firing.add(const Duration(hours: 2));
      final c = makeContainer(
        firingEdge: firing,
        state: NudgeState(dismissedAt: dismissed),
      );
      addTearDown(c.dispose);
      expect(c.read(nudgeVisibleProvider(RitualId.dailyPlanning)), isFalse);
    });

    test('visible again when a Trigger refires past the dismiss time', () {
      // User dismissed at 10am. A new firing edge starts at 11am (e.g.
      // content-state Trigger flipped true→false→true, or next period).
      // Dismiss should release.
      final dismissed = DateTime(2026, 5, 22, 10);
      final refiredAt = DateTime(2026, 5, 22, 11);
      final c = makeContainer(
        firingEdge: refiredAt,
        state: NudgeState(dismissedAt: dismissed),
      );
      addTearDown(c.dispose);
      expect(c.read(nudgeVisibleProvider(RitualId.dailyPlanning)), isTrue);
    });
  });

  group('nudgeQueueProvider', () {
    ProviderContainer makeContainer(Set<RitualId> visible) {
      return ProviderContainer(overrides: [
        nudgeVisibleProvider.overrideWith((ref, r) => visible.contains(r)),
      ]);
    }

    test('empty queue when no Ritual is visible', () {
      final c = makeContainer(const {});
      addTearDown(c.dispose);
      expect(c.read(nudgeQueueProvider), isEmpty);
      expect(c.read(nudgeQueueHeadProvider), isNull);
    });

    test('orders visible Rituals by priority — WR > ES > DPR', () {
      // Evening Shutdown outranks Daily Planning: "Shutdown wins" while a
      // session is open (ADR-0020). The two only fire together on a stale open
      // session, where the ES nudge must lead.
      final c = makeContainer({
        RitualId.eveningShutdown,
        RitualId.weeklyReview,
        RitualId.dailyPlanning,
      });
      addTearDown(c.dispose);
      expect(c.read(nudgeQueueProvider), [
        RitualId.weeklyReview,
        RitualId.eveningShutdown,
        RitualId.dailyPlanning,
      ]);
      expect(c.read(nudgeQueueHeadProvider), RitualId.weeklyReview);
    });

    test('Evening Shutdown leads Daily Planning when both fire (Shutdown wins)',
        () {
      final c = makeContainer({
        RitualId.dailyPlanning,
        RitualId.eveningShutdown,
      });
      addTearDown(c.dispose);
      expect(c.read(nudgeQueueProvider),
          [RitualId.eveningShutdown, RitualId.dailyPlanning]);
      expect(c.read(nudgeQueueHeadProvider), RitualId.eveningShutdown);
    });
  });
}
