/// The Unfinished Trigger of Daily Planning and Evening Shutdown: it fires from
/// the instant a started performance is left, and is void once the Ritual is
/// finished by any route. Real providers and an in-memory database; only the
/// clock is controlled.
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/ceremony_in_progress_provider.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/evening_shutdown_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/providers/nudge_triggers.dart';

import '../test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer c;
  late DateTime now;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    now = DateTime(2026, 5, 8, 16);
    c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
      nudgeBoundaryTickProvider.overrideWithValue(0),
    ]);
  });

  tearDown(() async {
    c.dispose();
    await db.close();
  });

  /// Keeps the Trigger's inputs subscribed, as the app shell does.
  Future<void> watch(RitualId ritual) async {
    final subscription = c.listen(
        unfinishedCeremonyTriggerProvider(ritual), (_, _) {});
    addTearDown(subscription.close);
    c.listen(activeSessionProvider, (_, _) {});
    await pumpEventQueue(times: 10);
  }

  TriggerState trigger(RitualId ritual) =>
      c.read(unfinishedCeremonyTriggerProvider(ritual));

  group('Daily Planning', () {
    const ritual = RitualId.dailyPlanning;

    test('opening the intro and leaving is not unfinished', () async {
      await watch(ritual);
      final ceremony = c.read(ceremonyInProgressProvider.notifier);
      ceremony.enter(ritual);
      ceremony.exit(ritual);
      expect(trigger(ritual).isFiring, isFalse);
    });

    test('leaving after proceeding fires from the instant left, and a second '
        'leave advances the edge', () async {
      await watch(ritual);
      final ceremony = c.read(ceremonyInProgressProvider.notifier);
      ceremony.enter(ritual);
      c.read(focusSessionPlanningProvider.notifier).goToStep(3);
      expect(trigger(ritual).isFiring, isFalse, reason: 'in progress');
      // Backing out passes through the intro: the latch outlives the step.
      c.read(focusSessionPlanningProvider.notifier).goToStep(0);
      ceremony.exit(ritual);
      expect(trigger(ritual),
          TriggerState(isFiring: true, firingSince: now));

      now = now.add(const Duration(hours: 1));
      ceremony.enter(ritual);
      expect(trigger(ritual).isFiring, isFalse);
      ceremony.exit(ritual);
      expect(trigger(ritual).firingSince, now);
    });

    test('a session opening voids it for good, even after that session closes',
        () async {
      await watch(ritual);
      final ceremony = c.read(ceremonyInProgressProvider.notifier);
      ceremony.enter(ritual);
      c.read(focusSessionPlanningProvider.notifier).goToStep(2);
      ceremony.exit(ritual);
      expect(trigger(ritual).isFiring, isTrue);

      final sessionId =
          await db.focusSessionDao.openSession(userId: 'local', taskIds: []);
      await pumpEventQueue(times: 10);
      expect(trigger(ritual).isFiring, isFalse);

      await db.focusSessionDao.closeSession(sessionId: sessionId);
      await pumpEventQueue(times: 10);
      expect(trigger(ritual).isFiring, isFalse);
    });

    test('a step advance still awaiting its reads cannot restore the latch a '
        'synced session just voided', () async {
      await watch(ritual);
      final ceremony = c.read(ceremonyInProgressProvider.notifier);
      final planning = c.read(focusSessionPlanningProvider.notifier);
      ceremony.enter(ritual);
      planning.goToStep(1);
      expect(c.read(dailyPlanningStartedProvider), isTrue);

      // The session opens (as through sync) while the advance into Review is
      // reading from the database.
      final advancing = planning.advanceStep();
      await db.focusSessionDao.openSession(userId: 'local', taskIds: []);
      await pumpEventQueue(times: 10);
      await advancing;
      await pumpEventQueue(times: 10);
      expect(c.read(dailyPlanningStartedProvider), isFalse);

      ceremony.exit(ritual);
      expect(trigger(ritual).isFiring, isFalse);
    });

    test('a session that opens and closes while the advance is still reading '
        'does not get its voided latch restored', () async {
      final session =
          await db.focusSessionDao.openSession(userId: 'local', taskIds: []);
      final opened = await db.focusSessionDao.watchActiveSession().first;
      await db.focusSessionDao.closeSession(sessionId: session);

      final sessionEvents = StreamController<FocusSession?>();
      addTearDown(sessionEvents.close);
      final gated = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(() => now),
        nudgeBoundaryTickProvider.overrideWithValue(0),
        activeSessionProvider.overrideWith((ref) => sessionEvents.stream),
      ]);
      addTearDown(gated.dispose);
      gated.listen(activeSessionProvider, (_, _) {});
      gated.listen(unfinishedCeremonyTriggerProvider(ritual), (_, _) {});
      sessionEvents.add(null);
      await pumpEventQueue(times: 10);

      final ceremony = gated.read(ceremonyInProgressProvider.notifier);
      final planning = gated.read(focusSessionPlanningProvider.notifier);
      ceremony.enter(ritual);
      planning.goToStep(1);
      expect(gated.read(dailyPlanningStartedProvider), isTrue);

      // Hold the database so the advance into Review cannot finish its reads
      // until both session events have been observed.
      final releaseDatabase = Completer<void>();
      final transactionEntered = Completer<void>();
      final heldTransaction = db.uncapturedTransaction(() async {
        transactionEntered.complete();
        await releaseDatabase.future;
      });
      try {
        await transactionEntered.future;
        final advancing = planning.advanceStep();

        sessionEvents.add(opened);
        await pumpEventQueue(times: 10);
        expect(
            gated.read(dailyPlanningStartedProvider), isFalse);
        sessionEvents.add(null);
        await pumpEventQueue(times: 10);

        releaseDatabase.complete();
        await heldTransaction;
        await advancing;
        await pumpEventQueue(times: 10);
        expect(
            gated.read(dailyPlanningStartedProvider), isFalse);
      } finally {
        if (!releaseDatabase.isCompleted) releaseDatabase.complete();
        await heldTransaction;
      }

      ceremony.exit(ritual);
      expect(gated.read(unfinishedCeremonyTriggerProvider(ritual)).isFiring,
          isFalse);
    });

    test('a session that opens and closes during the final session read from '
        'the intro does not get its latch restored', () async {
      final session =
          await db.focusSessionDao.openSession(userId: 'local', taskIds: []);
      final opened = await db.focusSessionDao.watchActiveSession().first;
      await db.focusSessionDao.closeSession(sessionId: session);

      final sessionEvents = StreamController<FocusSession?>();
      addTearDown(sessionEvents.close);
      final gated = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(() => now),
        nudgeBoundaryTickProvider.overrideWithValue(0),
        activeSessionProvider.overrideWith((ref) => sessionEvents.stream),
      ]);
      addTearDown(gated.dispose);
      gated.listen(activeSessionProvider, (_, _) {});
      gated.listen(unfinishedCeremonyTriggerProvider(ritual), (_, _) {});
      sessionEvents.add(null);
      await pumpEventQueue(times: 10);

      // From the intro the step 0 -> 1 advance has no review reads: the only
      // await is the final active-session read, which the held transaction
      // keeps pending.
      final planning = gated.read(focusSessionPlanningProvider.notifier);
      final releaseDatabase = Completer<void>();
      final transactionEntered = Completer<void>();
      final heldTransaction = db.uncapturedTransaction(() async {
        transactionEntered.complete();
        await releaseDatabase.future;
      });
      try {
        await transactionEntered.future;
        final advancing = planning.advanceStep();
        await pumpEventQueue(times: 10);

        sessionEvents.add(opened);
        await pumpEventQueue(times: 10);
        sessionEvents.add(null);
        await pumpEventQueue(times: 10);

        releaseDatabase.complete();
        await heldTransaction;
        await advancing;
        await pumpEventQueue(times: 10);
        expect(gated.read(dailyPlanningStartedProvider), isFalse);
      } finally {
        if (!releaseDatabase.isCompleted) releaseDatabase.complete();
        await heldTransaction;
      }
    });

    test('advancing while a session is already open does not latch', () async {
      await watch(ritual);
      final planning = c.read(focusSessionPlanningProvider.notifier);
      planning.goToStep(1);
      await db.focusSessionDao.openSession(userId: 'local', taskIds: []);
      await pumpEventQueue(times: 10);
      expect(c.read(dailyPlanningStartedProvider), isFalse);
      await planning.advanceStep();
      expect(c.read(dailyPlanningStartedProvider), isFalse);
    });

    test('resetting the draft voids it', () async {
      await watch(ritual);
      final ceremony = c.read(ceremonyInProgressProvider.notifier);
      ceremony.enter(ritual);
      c.read(focusSessionPlanningProvider.notifier).goToStep(2);
      ceremony.exit(ritual);
      expect(trigger(ritual).isFiring, isTrue);

      await c.read(focusSessionPlanningProvider.notifier).reEnterPlanning();
      expect(trigger(ritual).isFiring, isFalse);
    });
  });

  group('Evening Shutdown', () {
    const ritual = RitualId.eveningShutdown;

    test('fires on leaving a started performance, before the shutdown anchor',
        () async {
      final sessionId =
          await db.focusSessionDao.openSession(userId: 'local', taskIds: []);
      await watch(ritual);
      final ceremony = c.read(ceremonyInProgressProvider.notifier);
      ceremony.enter(ritual);
      await c.read(eveningShutdownProvider.notifier).markStarted();
      expect(c.read(eveningShutdownProvider).startedSessionId, sessionId);
      ceremony.exit(ritual);
      expect(trigger(ritual),
          TriggerState(isFiring: true, firingSince: now));
    });

    test('is void once that session closes without the Ceremony, and a new '
        'session does not inherit it', () async {
      final sessionId =
          await db.focusSessionDao.openSession(userId: 'local', taskIds: []);
      await watch(ritual);
      final ceremony = c.read(ceremonyInProgressProvider.notifier);
      ceremony.enter(ritual);
      await c.read(eveningShutdownProvider.notifier).markStarted();
      ceremony.exit(ritual);
      expect(trigger(ritual).isFiring, isTrue);

      await db.focusSessionDao.closeSession(sessionId: sessionId);
      await pumpEventQueue(times: 10);
      expect(trigger(ritual).isFiring, isFalse);

      await db.focusSessionDao.openSession(userId: 'local', taskIds: []);
      await pumpEventQueue(times: 10);
      expect(trigger(ritual).isFiring, isFalse);
    });

    test('a second performance after the first session closed rebinds and '
        'fires, instead of keeping the first session\'s id', () async {
      final firstId =
          await db.focusSessionDao.openSession(userId: 'local', taskIds: []);
      await watch(ritual);
      final ceremony = c.read(ceremonyInProgressProvider.notifier);
      final shutdown = c.read(eveningShutdownProvider.notifier);
      ceremony.enter(ritual);
      await shutdown.markStarted();
      ceremony.exit(ritual);
      expect(trigger(ritual).isFiring, isTrue);

      // Session A ends without the Ceremony (End Session or sync); B opens.
      await db.focusSessionDao.closeSession(sessionId: firstId);
      await pumpEventQueue(times: 10);
      expect(trigger(ritual).isFiring, isFalse);
      final secondId =
          await db.focusSessionDao.openSession(userId: 'local', taskIds: []);
      await pumpEventQueue(times: 10);

      now = now.add(const Duration(hours: 2));
      ceremony.enter(ritual);
      await shutdown.markStarted();
      expect(c.read(eveningShutdownProvider).startedSessionId, secondId);
      ceremony.exit(ritual);
      expect(trigger(ritual),
          TriggerState(isFiring: true, firingSince: now));
    });
  });
}
