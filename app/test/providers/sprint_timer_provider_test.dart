/// Regression coverage for [SprintTimerNotifier.stopSprint]'s teardown
/// contract (#428 review follow-up).
///
/// Stopping is terminal, which is what makes its failure modes nastier than
/// they look. Every control that can stop a sprint lives behind an active focus
/// mode, and the callers tearing a sprint down are usually clearing focus mode
/// in the same breath — so a stop that half-succeeds leaves a sprint the user
/// can neither see nor end. Three ways that used to happen:
///
/// - the local reset sat after two awaits that can throw, so a failure left the
///   state reporting `isActive`;
/// - the cleanups were chained, so a throwing notification channel skipped
///   `_clearPrefs` and the sprint came back on the next launch;
/// - an `isProcessing` early-return made a stop issued mid-operation a silent
///   no-op that callers could not distinguish from success.
///
/// These pin all three against the real notifier. The fakes in
/// active_focus_screen_test.dart model the contract; a fake cannot prove
/// production honours it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/providers/sprint_timer_provider.dart';
import 'package:jeeves/services/notification_service.dart';

/// Mirrors the keys `_restoreFromPrefs` reads on launch. Duplicated rather than
/// exported: the test asserts against the on-disk contract, so it should fail
/// if production renames a key without a migration.
const _kPrefActiveTaskId = 'sprint_active_task_id';
const _kPrefActiveTaskTitle = 'sprint_active_task_title';
const _kPrefEndTime = 'sprint_end_time';
const _kPrefPhase = 'sprint_phase';
const _kPrefSprintNumber = 'sprint_sprint_number';

/// A notification service whose sprint-notification teardown fails, standing in
/// for the platform channel throwing under a wedged notification plugin.
class _ThrowingNotificationService extends NotificationService {
  _ThrowingNotificationService() : super.forTesting();

  @override
  Future<void> cancelSprintNotifications() async {
    throw StateError('notification channel unavailable');
  }
}

/// A notification service that tears down cleanly — the control case.
class _SilentNotificationService extends NotificationService {
  _SilentNotificationService() : super.forTesting();

  @override
  Future<void> cancelSprintNotifications() async {}
}

/// Parks the break-end *scheduling* on [gate] and records what was scheduled.
///
/// Gating the schedule rather than the teardown is deliberate: by the time
/// `_startBreak` reaches it the transition has already written state and
/// persisted the break, so the stop lands with those side effects pending — the
/// state a stop actually has to unwind, rather than one caught before it began.
///
/// Cancellation is left ungated so `stopSprint` can run: it cancels the same
/// notifications, and parking that too would deadlock the stop against the
/// transition it is meant to supersede.
class _GatedNotificationService extends NotificationService {
  _GatedNotificationService(this.gate) : super.forTesting();

  final Future<void> gate;

  /// Break-end notifications scheduled but not since cancelled — a stale one
  /// left here means the OS would fire "break over" for a break that was
  /// stopped.
  int scheduled = 0;

  @override
  Future<void> cancelSprintNotifications() async {
    scheduled = 0;
  }

  @override
  Future<void> scheduleBreakEndNotification({
    required DateTime endTime,
  }) async {
    await gate;
    scheduled++;
  }
}

/// Seeds the prefs a live sprint leaves behind, so the tests start from the
/// state a real running sprint would have persisted.
Map<String, Object> _activeSprintPrefs(String taskId) => {
      _kPrefActiveTaskId: taskId,
      _kPrefActiveTaskTitle: 'Doomed',
      _kPrefEndTime:
          DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
      _kPrefPhase: 'focus',
      _kPrefSprintNumber: 1,
    };

/// Every key `_restoreFromPrefs` consults to rebuild a sprint. Asserting only
/// the id would pass while the rest lingered — and a half-cleared sprint is
/// exactly what a partially-failed teardown leaves behind.
void _expectNoPersistedSprint(SharedPreferences prefs, {String? reason}) {
  expect(prefs.getString(_kPrefActiveTaskId), isNull, reason: reason);
  expect(prefs.getString(_kPrefActiveTaskTitle), isNull, reason: reason);
  expect(prefs.getString(_kPrefEndTime), isNull, reason: reason);
  expect(prefs.getString(_kPrefPhase), isNull, reason: reason);
  expect(prefs.getInt(_kPrefSprintNumber), isNull, reason: reason);
}

void main() {
  // `stopSprint` reaches the haptics platform channel, and
  // `SharedPreferences.setMockInitialValues` needs a binding too — both throw
  // "Binding has not yet been initialized" without this, failing these tests
  // for a reason that has nothing to do with teardown.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SprintTimerNotifier.stopSprint', () {
    test('clears the persisted sprint even when notification teardown throws',
        () async {
      SharedPreferences.setMockInitialValues(_activeSprintPrefs('sp1'));
      final container = ProviderContainer(overrides: [
        notificationServiceProvider
            .overrideWithValue(_ThrowingNotificationService()),
      ]);
      addTearDown(container.dispose);

      // Let the notifier restore itself from those prefs, so the sprint under
      // test is one it produced rather than one the test assigned.
      final notifier = await _startedNotifier(container);

      await expectLater(notifier.stopSprint(), throwsA(isA<StateError>()));

      // In-memory: no phantom sprint left reporting itself active.
      expect(container.read(sprintTimerProvider).isActive, isFalse);
      expect(container.read(sprintTimerProvider).activeTaskId, isNull);

      // On disk: the failing notification cancel must not have skipped the
      // prefs clear. This is the half that outlives the process — a sprint left
      // on disk is one `_restoreFromPrefs` hands back on the next launch.
      final prefs = await SharedPreferences.getInstance();
      _expectNoPersistedSprint(prefs,
          reason: 'a failed notification cancel must not skip the prefs clear');

      // And prove it: a fresh container reads the same prefs the app would.
      final relaunched = ProviderContainer(overrides: [
        notificationServiceProvider
            .overrideWithValue(_SilentNotificationService()),
      ]);
      addTearDown(relaunched.dispose);
      relaunched.read(sprintTimerProvider);
      await _settle();
      expect(relaunched.read(sprintTimerProvider).isActive, isFalse,
          reason: 'a relaunch must not resurrect the stopped sprint');
      expect(relaunched.read(sprintTimerProvider).activeTaskId, isNull);
    });

    test('clears local and persisted state on the success path', () async {
      SharedPreferences.setMockInitialValues(_activeSprintPrefs('sp2'));
      final container = ProviderContainer(overrides: [
        notificationServiceProvider
            .overrideWithValue(_SilentNotificationService()),
      ]);
      addTearDown(container.dispose);

      final notifier = await _startedNotifier(container);

      await notifier.stopSprint();

      expect(container.read(sprintTimerProvider).isActive, isFalse);
      expect(container.read(sprintTimerProvider).activeTaskId, isNull);
      final prefs = await SharedPreferences.getInstance();
      _expectNoPersistedSprint(prefs);
    });

    test('a stop lands while a real transition is suspended mid-flight',
        () async {
      // Drives an *actually* suspended operation rather than setting
      // `isProcessing` by hand: `completeSprint` is held inside the break-end
      // *scheduling* (`_startBreak` → `_scheduleEndNotification`), which is
      // where `_GatedNotificationService` parks it. Cancellation is left
      // ungated so the stop can run. By that point the transition has already
      // written state and persisted the break — the state a hand-set flag only
      // imitates.
      //
      // Two failures are in scope. A stop that bailed on `isProcessing`
      // returned normally having done nothing, and the missing-task teardown
      // read that as success. And once it stops bailing, the suspended
      // transition resumes holding pre-stop values and would re-persist the
      // break it was starting — putting the sprint back on disk for the next
      // launch to restore.
      SharedPreferences.setMockInitialValues(_activeSprintPrefs('sp3'));
      final gate = Completer<void>();
      final notifications = _GatedNotificationService(gate.future);
      final container = ProviderContainer(overrides: [
        notificationServiceProvider.overrideWithValue(notifications),
      ]);
      addTearDown(container.dispose);

      final notifier = await _startedNotifier(container);

      // Suspend a real transition *after* its side effects have begun: by the
      // time `_startBreak` reaches the schedule it has already written state
      // and persisted the break.
      final completing = notifier.completeSprint();
      await _settle();
      expect(container.read(sprintTimerProvider).isBreak, isTrue,
          reason: 'precondition: the break was started and is mid-schedule');
      final prefsMid = await SharedPreferences.getInstance();
      expect(prefsMid.getString(_kPrefPhase), isNotNull,
          reason: 'precondition: the break is already on disk');

      await notifier.stopSprint();
      expect(container.read(sprintTimerProvider).isActive, isFalse,
          reason: 'a stop must win over an in-flight operation, not skip');
      final prefsAfterStop = await SharedPreferences.getInstance();
      _expectNoPersistedSprint(prefsAfterStop,
          reason: 'the stop clears what the suspended transition persisted');
      expect(notifications.scheduled, 0);

      // Let the superseded transition resume. It must recreate neither the
      // persisted sprint nor the scheduled notification.
      gate.complete();
      await completing;
      await _settle();

      expect(container.read(sprintTimerProvider).isActive, isFalse,
          reason: 'a resumed transition must not resurrect the sprint');
      final prefs = await SharedPreferences.getInstance();
      _expectNoPersistedSprint(prefs,
          reason: 'nor re-persist the break it was starting');
      expect(notifications.scheduled, 0,
          reason: 'nor leave a break-end notification the OS would still fire');
    });
  });
}

/// `build()` kicks `_restoreFromPrefs()` fire-and-forget, so the restored state
/// lands a few microtasks later — and `completeSprint` chains several awaits
/// before it settles. `pumpEventQueue` drains many turns rather than the single
/// one a bare zero-delay yields, so a multi-step flow finishes before the
/// assertions rather than racing them.
Future<void> _settle() => pumpEventQueue();

/// Reads the notifier, lets its fire-and-forget restore land, and pins the
/// precondition every test here shares: the sprint under test is one the
/// notifier rebuilt from prefs, not one the test assigned.
Future<SprintTimerNotifier> _startedNotifier(ProviderContainer c) async {
  final notifier = c.read(sprintTimerProvider.notifier);
  await _settle();
  expect(c.read(sprintTimerProvider).isActive, isTrue,
      reason: 'precondition: a sprint was restored from prefs');
  return notifier;
}
