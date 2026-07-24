/// Integration tests for the Daily Planning and Evening Shutdown Cadence
/// Triggers under the ES-anchor day-attribution model (issue #460, ADR-0020).
///
/// The DPR trigger fires when now is past today's DPR anchor AND no qualifying
/// session exists (none started since the last Evening Shutdown anchor). The ES
/// trigger is unchanged: session open AND past the shutdown anchor. Both read
/// the clock through the overridable [clockProvider]; [nudgeBoundaryTickProvider]
/// is stubbed to a constant so no wall-clock timer is scheduled.
library;

import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/focus_session_planning_settings.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/models/shutdown_settings.dart';
import 'package:jeeves/providers/ceremony_in_progress_provider.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart'
    show activeSessionProvider;
import 'package:jeeves/providers/focus_session_planning_settings_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/providers/nudge_triggers.dart';
import 'package:jeeves/providers/onboarding_provider.dart';
import 'package:jeeves/providers/shutdown_settings_provider.dart';

class _StubPlanningSettings extends FocusSessionPlanningSettingsNotifier {
  _StubPlanningSettings(this._time);
  final TimeOfDay _time;
  @override
  FocusSessionPlanningSettings build() =>
      FocusSessionPlanningSettings(planningTime: _time);
}

class _StubShutdownSettings extends ShutdownSettingsNotifier {
  _StubShutdownSettings(this._time);
  final TimeOfDay _time;
  @override
  ShutdownSettings build() => ShutdownSettings(shutdownTime: _time);
}

FocusSession _openSession(DateTime startedAt) => FocusSession(
      id: 'open',
      userId: 'u',
      startedAt: startedAt.toUtc().toIso8601String(),
      endedAt: null,
      currentTaskId: null,
    );

Todo _todo() => Todo(
      id: 't',
      title: 'A next action',
      createdAt: DateTime(2026, 1, 1),
      clarified: true,
      intent: 'next',
      userId: 'u',
      timeSpentMinutes: 0,
    );

ProviderContainer _makeContainer({
  required DateTime now,
  TimeOfDay planningTime = const TimeOfDay(hour: 8, minute: 0),
  TimeOfDay shutdownTime = const TimeOfDay(hour: 18, minute: 0),
  bool qualifying = false,
  FocusSession? activeSession,
  bool hasItems = true,
  bool nextEmpty = false,
}) {
  return ProviderContainer(overrides: [
    clockProvider.overrideWithValue(() => now),
    nudgeBoundaryTickProvider.overrideWithValue(0),
    focusSessionPlanningSettingsProvider
        .overrideWith(() => _StubPlanningSettings(planningTime)),
    shutdownSettingsProvider
        .overrideWith(() => _StubShutdownSettings(shutdownTime)),
    qualifyingSessionTodayProvider.overrideWith((ref) => Stream.value(qualifying)),
    activeSessionProvider.overrideWith((ref) => Stream.value(activeSession)),
    hasAnyItemProvider.overrideWith((ref) => Stream.value(hasItems)),
    unfilteredInboxProvider.overrideWith((ref) => Stream.value(const [])),
    unfilteredNextProvider
        .overrideWith((ref) => Stream.value(nextEmpty ? const [] : [_todo()])),
    ceremonyInProgressForProvider.overrideWith((ref, r) => false),
  ]);
}

/// Keeps [ritual]'s Cadence Trigger (and its transitive async deps) subscribed
/// so the overridden `Stream.value` providers emit, pumps the event loop, then
/// reads the resolved state. A live listener is required — `read` alone does
/// not hold the subscription, leaving StreamProviders stuck in loading.
Future<TriggerState> _readTrigger(
    ProviderContainer c, RitualId ritual) async {
  // Hold a live listener so the StreamProviders stay subscribed (read alone
  // does not), then pump the event queue. The trigger reads its async deps
  // sequentially — each emission triggers a recompute that starts the next
  // dep loading — so several turns are needed for the whole chain to resolve.
  final sub = c.listen(cadenceTriggerProvider(ritual), (_, _) {});
  addTearDown(sub.close);
  await pumpEventQueue(times: 30);
  return c.read(cadenceTriggerProvider(ritual));
}

void main() {
  group('Daily Planning Cadence Trigger — ES-anchor attribution', () {
    test('idle before today\'s DPR anchor (no pre-anchor nagging)', () async {
      final c = _makeContainer(now: DateTime(2026, 5, 20, 7, 0));
      addTearDown(c.dispose);
      expect((await _readTrigger(c, RitualId.dailyPlanning)).isFiring, isFalse);
    });

    test('fires past the anchor with no qualifying session', () async {
      final c = _makeContainer(now: DateTime(2026, 5, 20, 9, 0));
      addTearDown(c.dispose);
      final t = await _readTrigger(c, RitualId.dailyPlanning);
      expect(t.isFiring, isTrue);
      // firingSince = later of today's DPR anchor (08:00) and last ES anchor
      // (yesterday 18:00) = today 08:00.
      expect(t.firingSince, DateTime(2026, 5, 20, 8, 0));
    });

    test('suppressed while a qualifying session exists (early 07:30 start)',
        () async {
      // Session opened 07:30 today qualifies (after yesterday's ES anchor);
      // clock 10:00, DPR anchor 08:00. No DPR nudge.
      final c = _makeContainer(
        now: DateTime(2026, 5, 20, 10, 0),
        qualifying: true,
        activeSession: _openSession(DateTime(2026, 5, 20, 7, 30)),
      );
      addTearDown(c.dispose);
      expect((await _readTrigger(c, RitualId.dailyPlanning)).isFiring, isFalse);
    });

    test('re-arms after a completed plan+shutdown once past the ES anchor',
        () async {
      // Planned 08:30, shut down 18:10; clock 18:30. The closed session started
      // before today's 18:00 ES anchor, so it no longer qualifies — DPR
      // re-arms, firingSince = 18:00 (so a morning dismiss doesn't suppress it).
      final c = _makeContainer(
        now: DateTime(2026, 5, 20, 18, 30),
        planningTime: const TimeOfDay(hour: 8, minute: 30),
        qualifying: false,
        activeSession: null,
      );
      addTearDown(c.dispose);
      final t = await _readTrigger(c, RitualId.dailyPlanning);
      expect(t.isFiring, isTrue);
      expect(t.firingSince, DateTime(2026, 5, 20, 18, 0));
    });

    test('defers (idle) while content is empty', () async {
      final c = _makeContainer(
        now: DateTime(2026, 5, 20, 9, 0),
        nextEmpty: true, // inbox already empty
      );
      addTearDown(c.dispose);
      expect((await _readTrigger(c, RitualId.dailyPlanning)).isFiring, isFalse);
    });
  });

  group('Stale open session — DPR and ES both fire, ES leads', () {
    test('past both anchors: DPR fires (no qualifying) AND ES fires', () async {
      // Session opened yesterday, still open; clock 18:30 today; anchors 08:00
      // / 18:00. It started before today\'s ES anchor, so does not qualify.
      final c = _makeContainer(
        now: DateTime(2026, 5, 20, 18, 30),
        qualifying: false,
        activeSession: _openSession(DateTime(2026, 5, 19, 9, 0)),
      );
      addTearDown(c.dispose);

      final dpr = await _readTrigger(c, RitualId.dailyPlanning);
      final es = await _readTrigger(c, RitualId.eveningShutdown);
      expect(dpr.isFiring, isTrue, reason: 'stale open session re-arms DPR');
      expect(es.isFiring, isTrue, reason: 'session open past shutdown anchor');
      // ES leads DPR in the queue — pinned by ritual_test / nudge_provider_test
      // ("Shutdown wins", ADR-0020).
      expect(RitualId.eveningShutdown.priority,
          greaterThan(RitualId.dailyPlanning.priority));
    });
  });

  group('Evening Shutdown Cadence Trigger — unchanged', () {
    test('idle with no active session even past the anchor', () async {
      final c = _makeContainer(
        now: DateTime(2026, 5, 20, 19, 0),
        activeSession: null,
      );
      addTearDown(c.dispose);
      expect((await _readTrigger(c, RitualId.eveningShutdown)).isFiring, isFalse);
    });

    test('idle with an active session before the anchor', () async {
      final c = _makeContainer(
        now: DateTime(2026, 5, 20, 10, 0),
        activeSession: _openSession(DateTime(2026, 5, 20, 8, 0)),
      );
      addTearDown(c.dispose);
      expect((await _readTrigger(c, RitualId.eveningShutdown)).isFiring, isFalse);
    });

    test('fires with an active session past the anchor', () async {
      final c = _makeContainer(
        now: DateTime(2026, 5, 20, 18, 30),
        qualifying: true,
        activeSession: _openSession(DateTime(2026, 5, 20, 8, 0)),
      );
      addTearDown(c.dispose);
      final t = await _readTrigger(c, RitualId.eveningShutdown);
      expect(t.isFiring, isTrue);
      expect(t.firingSince, DateTime(2026, 5, 20, 18, 0));
    });
  });
}
