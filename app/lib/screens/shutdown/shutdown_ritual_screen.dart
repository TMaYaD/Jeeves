/// Evening shutdown ritual — outer container screen (Issue #83).
///
/// Steps 0–1 are composed against the shared [Wizard] widget, and so is the
/// habit step, which takes the place of Close Day while the closing day has
/// open Habits; Close Day
/// is rendered standalone — full-screen moon-rise animation
/// that commits dispositions, fades out, and exits the app. The wizard
/// chrome is owned by [Wizard] per issue #322; each [WizardStep] owns its
/// own footer widget through [WizardStep.footer].
///
/// Step 1 → Step 2 advances automatically once the user resolves the last
/// unfinished task; the screen latches onto [CloseDayStep] once reached so
/// `closeDay()` resetting `currentStep` mid fade-out cannot expose the
/// Review step underneath.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/ritual.dart';
import '../../providers/ceremony_in_progress_provider.dart';
import '../../providers/evening_shutdown_provider.dart';
import '../../providers/focus_session_planning_provider.dart';
import '../../providers/habit_progress_provider.dart';
import '../../providers/shutdown_habits_provider.dart';
import '../../widgets/ceremony/ceremony_pop_scope.dart';
import '../../widgets/ceremony/wizard.dart';
import '../habits/habit_copy.dart';
import 'steps/close_day_step.dart';
import 'steps/habit_check_in_step.dart';
import 'steps/settled_review_step.dart';
import 'steps/unfinished_tasks_step.dart';

class ShutdownRitualScreen extends ConsumerStatefulWidget {
  const ShutdownRitualScreen({super.key, this.habitsOnly = false});

  /// Every Outcome is done and only Habits are open: the ritual is the habit
  /// step alone, then the session closes. It has no Review, no Resolve
  /// Unfinished and no Close Day screen.
  final bool habitsOnly;

  @override
  ConsumerState<ShutdownRitualScreen> createState() =>
      _ShutdownRitualScreenState();
}

class _ShutdownRitualScreenState extends ConsumerState<ShutdownRitualScreen> {
  late final CeremonyInProgressNotifier _ceremonyNotifier;
  late final ShutdownThenPlanNotifier _thenPlanNotifier;
  // True when Daily Planning launched this performance. Only then does
  // dispose() clear the intent, so it can never clobber a fresh set(true)
  // made for a later performance.
  late final bool _launchedByDailyPlanning;
  int? _resolveInitialTotal;
  bool _showCloseDay = false;

  /// The open Habits, latched the first time the habit step is reached so a
  /// row stays in place after its Check-in. Null until then.
  List<ShutdownOpenHabit>? _latchedHabits;

  static const _ceremonyId = 'shutdown';
  static const _accent = Color(0xFF1E3A5F);
  static const _stepTitles = ['Review Your Day', 'Resolve Unfinished'];

  @override
  void initState() {
    super.initState();
    // Capture the notifier now so dispose() can call exit() without
    // touching `ref` after the widget has been unmounted.
    _ceremonyNotifier = ref.read(ceremonyInProgressProvider.notifier);
    _thenPlanNotifier = ref.read(shutdownThenPlanProvider.notifier);
    _launchedByDailyPlanning = ref.read(shutdownThenPlanProvider);
    // hold the Nudge while this Ceremony performance is in progress.
    // Defer `enter()` to the post-frame callback — Riverpod 3.x forbids
    // notifier mutation during the build phase, which initState is part of.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ceremonyNotifier.enter(RitualId.eveningShutdown);
      // Evening Shutdown has no intro: showing its first step is the start.
      ref.read(eveningShutdownProvider.notifier).markStarted();
    });
  }

  @override
  void dispose() {
    // Defer `exit()` to a microtask — unmount runs while the widget tree is
    // locked, and Riverpod forbids notifier mutation during that phase (the
    // mirror of the deferred `enter()` above). The notifier guards against
    // the container being torn down before the microtask fires.
    final notifier = _ceremonyNotifier;
    Future.microtask(() => notifier.exit(RitualId.eveningShutdown));
    // The and-then-plan intent lives for one performance: leaving without
    // finishing (Close Day already clears it) must not colour a later one.
    if (_launchedByDailyPlanning) {
      final thenPlanNotifier = _thenPlanNotifier;
      Future.microtask(thenPlanNotifier.clear);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shutdownState = ref.watch(eveningShutdownProvider);
    final notifier = ref.read(eveningShutdownProvider.notifier);
    final step = shutdownState.currentStep;

    // The habit step needs the closing day and every Habit's history. Watch
    // both from the start so they are loaded by the time the step is reached.
    final closingDayAsync = ref.watch(shutdownClosingDayProvider);
    final habitsLoaded = ref.watch(habitHistoriesProvider).hasValue;
    final habitsReady = habitsLoaded && closingDayAsync.hasValue;
    final liveOpenHabits = ref.watch(shutdownOpenHabitsProvider);
    final closingDay = closingDayAsync.value;
    ref.watch(shutdownHabitCheckInsProvider);

    if (widget.habitsOnly) {
      return _buildHabitsOnly(
        habitsReady: habitsReady,
        closingDay: closingDay,
        liveOpenHabits: liveOpenHabits,
        notifier: notifier,
      );
    }

    final pastResolve = step == kShutdownCloseDayStep && !_showCloseDay;
    if (pastResolve && !shutdownState.habitsStepDone && habitsReady) {
      _latchedHabits ??= liveOpenHabits;
    }
    final habitStepPending = pastResolve &&
        !shutdownState.habitsStepDone &&
        (_latchedHabits == null || _latchedHabits!.isNotEmpty);

    // Still finding out whether there is a habit step: show nothing yet rather
    // than flash Close Day.
    if (habitStepPending && _latchedHabits == null) {
      return CeremonyPopScope(
        onBack: () => notifier.goToStep(kShutdownReviewStep),
        child: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    // Lock onto CloseDayStep once reached. closeDay() resets currentStep to 0
    // mid fade-out; without this latch the parent would rebuild and unmount
    // CloseDayStep, exposing the Review step underneath.
    final atCloseDay = step == kShutdownCloseDayStep && !habitStepPending;
    if (atCloseDay && !_showCloseDay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_showCloseDay) {
          setState(() => _showCloseDay = true);
        }
      });
    }
    // Close Day is the terminal confirmation — footer Back is unavailable,
    // so system back exits to the execution home like other completion
    // screens (the ritual itself exits the app once Close Day is tapped).
    if (_showCloseDay || atCloseDay) {
      return const CeremonyPopScope(onBack: null, child: CloseDayStep());
    }

    // Latch the initial unfinished count once so the resolve progress fills
    // correctly. Auto-advance off step 1 whenever the list is empty — covers
    // both "resolved the last task" and "nothing to resolve to begin with".
    ref.listen<AsyncValue<List<Todo>>>(unfinishedSelectedTodayProvider,
        (prev, next) {
      final tasks = next.asData?.value;
      if (tasks == null) return;
      if (tasks.isNotEmpty && _resolveInitialTotal == null) {
        setState(() => _resolveInitialTotal = tasks.length);
      }
      if (tasks.isEmpty &&
          ref.read(eveningShutdownProvider).currentStep ==
              kShutdownResolveStep) {
        notifier.advanceStep();
      }
    });

    // If we render step 1 with no unfinished tasks (e.g. user landed here
    // directly with an empty list, so the listener above never observed a
    // transition), skip past it on the next frame.
    if (step == kShutdownResolveStep &&
        (ref.watch(unfinishedSelectedTodayProvider).asData?.value.isEmpty ??
            false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            ref.read(eveningShutdownProvider).currentStep ==
                kShutdownResolveStep) {
          notifier.advanceStep();
        }
      });
    }

    double resolveProgress = 0.0;
    if (step == kShutdownResolveStep && _resolveInitialTotal != null && _resolveInitialTotal! > 0) {
      final current =
          ref.watch(unfinishedSelectedTodayProvider).asData?.value.length;
      if (current != null) {
        final resolved = _resolveInitialTotal! - current;
        resolveProgress = (resolved / _resolveInitialTotal!).clamp(0.0, 1.0);
      }
    }

    // The habit step counts as a step only when there are open Habits.
    final habitsForStep = _latchedHabits ?? liveOpenHabits;
    final showsHabitStep = habitsReady && habitsForStep.isNotEmpty;
    final stepCount = showsHabitStep ? 3 : 2;

    final steps = <WizardStep>[
      WizardStep(
        title: _stepTitles[0],
        body: const SettledReviewStep(),
        subtitle: 'Step 1 of $stepCount',
        footer: WizardFooter(
          ceremonyId: _ceremonyId,
          accentColor: _accent,
          onBack: _backForStep(0, shutdownState, notifier),
          onNext: notifier.advanceStep,
        ),
      ),
      WizardStep(
        title: _stepTitles[1],
        body: const UnfinishedTasksStep(),
        activeFraction: resolveProgress,
        subtitle: 'Step 2 of $stepCount',
        // Dispositions on each task drive advancement here; the footer
        // offers no forward affordance, only Back. Back retreats the
        // unfinished snapshot cursor before crossing to Step 0.
        footer: BackOnlyFooter(
          ceremonyId: _ceremonyId,
          onBack: _backForStep(1, shutdownState, notifier),
        ),
      ),
      if (showsHabitStep && closingDay != null)
        WizardStep(
          title: habitShutdownStepTitle,
          body: HabitCheckInStep(
            closingDay: closingDay,
            habits: habitsForStep,
          ),
          activeFraction: _habitProgress(
            habitsForStep,
            ref.watch(shutdownHabitCheckInsProvider),
          ),
          subtitle: 'Step 3 of 3',
          footer: ListItemFooter(
            ceremonyId: _ceremonyId,
            accentColor: _accent,
            onBack: _backForStep(kShutdownCloseDayStep, shutdownState, notifier),
            onSkip: notifier.finishHabitsStep,
            onNext: notifier.finishHabitsStep,
            hasMoreItems: _anyHabitUntouched(
              habitsForStep,
              ref.watch(shutdownHabitCheckInsProvider),
            ),
          ),
        ),
    ];

    return CeremonyPopScope(
      // System back mirrors the active step's footer Back; on the first
      // step (no Back) it exits to the execution home.
      onBack: _backForStep(step, shutdownState, notifier),
      child: Wizard(
        ceremonyLabel: 'Evening Shutdown',
        ceremonyIcon: Icons.nightlight_outlined,
        accentColor: _accent,
        currentStep: step,
        steps: steps,
      ),
    );
  }

  /// The habits-only ritual: the habit step alone, whose forward button closes
  /// the session. Back leaves the session open and returns to Now.
  Widget _buildHabitsOnly({
    required bool habitsReady,
    required String? closingDay,
    required List<ShutdownOpenHabit> liveOpenHabits,
    required EveningShutdownNotifier notifier,
  }) {
    if (habitsReady) _latchedHabits ??= liveOpenHabits;
    final habits = _latchedHabits;
    if (habits == null || closingDay == null) {
      return CeremonyPopScope(
        onBack: null,
        child: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    final made = ref.watch(shutdownHabitCheckInsProvider);
    return CeremonyPopScope(
      onBack: null,
      child: Wizard(
        ceremonyLabel: 'Evening Shutdown',
        ceremonyIcon: Icons.nightlight_outlined,
        accentColor: _accent,
        currentStep: 0,
        steps: [
          WizardStep(
            title: habitShutdownStepTitle,
            body: HabitCheckInStep(closingDay: closingDay, habits: habits),
            activeFraction: _habitProgress(habits, made),
            footer: ListItemFooter(
              ceremonyId: _ceremonyId,
              accentColor: _accent,
              onBack: () => context.go(kCeremonyExitRoute),
              onSkip: () => _closeAfterHabitsOnly(notifier),
              onNext: () => _closeAfterHabitsOnly(notifier),
              hasMoreItems: _anyHabitUntouched(habits, made),
              nextLabel: habitShutdownForwardLabelHabitsOnly,
            ),
          ),
        ],
      ),
    );
  }

  bool _closingAfterHabitsOnly = false;

  /// Closes the session and leaves for the inbox; when something turns out to
  /// be unfinished, the full ritual starts instead.
  Future<void> _closeAfterHabitsOnly(EveningShutdownNotifier notifier) async {
    if (_closingAfterHabitsOnly) return;
    _closingAfterHabitsOnly = true;
    try {
      final closed = await notifier.closeAfterHabitsOnly();
      if (!mounted) return;
      context.go(closed ? '/inbox' : '/shutdown');
    } finally {
      _closingAfterHabitsOnly = false;
    }
  }

  /// The Back callback for [stepIndex] — the same callback its footer
  /// renders. Null when Back is unavailable, which [CeremonyPopScope]
  /// translates into a ceremony exit.
  VoidCallback? _backForStep(
    int stepIndex,
    EveningShutdownState shutdownState,
    EveningShutdownNotifier notifier,
  ) =>
      switch (stepIndex) {
        kShutdownReviewStep => null,
        kShutdownResolveStep => shutdownState.unfinishedNav.canGoBack
            ? notifier.previousUnfinishedTask
            : () => notifier.goToStep(kShutdownReviewStep),
        // The habit step: Resolve Unfinished is empty by now and would only
        // advance again, so Back goes to Review.
        _ => () => notifier.goToStep(kShutdownReviewStep),
      };

  static bool _anyHabitUntouched(
    List<ShutdownOpenHabit> habits,
    Map<String, List<String>> made,
  ) =>
      habits.any((open) => (made[open.habit.id] ?? const []).isEmpty);

  static double _habitProgress(
    List<ShutdownOpenHabit> habits,
    Map<String, List<String>> made,
  ) {
    if (habits.isEmpty) return 0;
    final touched =
        habits.where((o) => (made[o.habit.id] ?? const []).isNotEmpty).length;
    return touched / habits.length;
  }
}
