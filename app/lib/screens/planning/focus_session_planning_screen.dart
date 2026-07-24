/// Focus session planning ritual — outer container screen (Issue #82).
///
/// Renders a full-screen, drawer-free wizard with five user-driven steps
/// (Inbox → Review → Energy → Time → Plan Summary). Once the user starts
/// the day the screen swaps the wizard for the standalone "Today's
/// Schedule" completion view — completion screens live outside the wizard
/// because they are post-ritual confirmations, not steps the user walks
/// through. Wizard chrome — header and segmented progress bar — is owned
/// by the shared [Wizard] widget per issue #322; each [WizardStep] owns
/// its own footer widget through [WizardStep.footer].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/ritual.dart';
import '../../providers/ceremony_in_progress_provider.dart';
import '../../providers/focus_session_planning_provider.dart';
import '../../widgets/ceremony/ceremony_pop_scope.dart';
import '../../widgets/ceremony/wizard.dart';
import 'steps/day_checkin_energy_step.dart';
import 'steps/day_checkin_time_step.dart';
import 'steps/inbox_clarification_step.dart';
import 'steps/plan_summary_step.dart';
import 'steps/scheduled_review_step.dart';
import 'steps/task_review_step.dart';

class FocusSessionPlanningScreen extends ConsumerStatefulWidget {
  const FocusSessionPlanningScreen({super.key});

  @override
  ConsumerState<FocusSessionPlanningScreen> createState() =>
      _FocusSessionPlanningScreenState();
}

class _FocusSessionPlanningScreenState
    extends ConsumerState<FocusSessionPlanningScreen> {
  late final CeremonyInProgressNotifier _ceremonyNotifier;

  static const _ceremonyId = 'planning';
  static const _stepTitles = [
    'Clarify Inbox',
    'Review Tasks',
    'Energy Check-in',
    'Time Check-in',
    'Review Next Actions',
  ];

  static const _accent = Color(0xFF2563EB);
  static const int _kProgressSegmentCount = 5;

  @override
  void initState() {
    super.initState();
    // Capture the notifier now so dispose() can call exit() without
    // touching `ref` after the widget has been unmounted (Riverpod
    // forbids ref access in dispose).
    _ceremonyNotifier = ref.read(ceremonyInProgressProvider.notifier);
    // ADR-0009: hold the Nudge while this Ceremony performance is in progress.
    // Defer `enter()` to the post-frame callback — Riverpod 3.x forbids
    // notifier mutation during the build phase, which initState is part of.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ceremonyNotifier.enter(RitualId.dailyPlanning);
      // Recompute rollover pre-selection on mount (#461). Covers the
      // warm-process replan — reaching this screen next morning on an already
      // built notifier, which build()'s once-per-process microtask misses.
      // Fire-and-forget: the method is idempotent, guards against an open
      // session, and its reviewed-ids merge keeps deselected tasks out.
      ref.read(focusSessionPlanningProvider.notifier).ensureRolloverPreload();
    });
  }

  @override
  void dispose() {
    // Defer `exit()` to a microtask — unmount runs while the widget tree is
    // locked, and Riverpod forbids notifier mutation during that phase (the
    // mirror of the deferred `enter()` above). The notifier guards against
    // the container being torn down before the microtask fires.
    final notifier = _ceremonyNotifier;
    Future.microtask(() => notifier.exit(RitualId.dailyPlanning));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Blocked-start gate (ADR-0020, ruling 4): a new session cannot open while
    // one is already open. If reached with an open session (via the Re-plan
    // menu or the planning notification), surface a blocking interstitial that
    // sequences the user through Evening Shutdown first — carrying an
    // and-then-plan intent so Close Day routes back here instead of exiting.
    final activeSession = ref.watch(activeSessionProvider);
    if (activeSession.asData?.value != null) {
      return const _SessionOpenInterstitial();
    }

    final state = ref.watch(focusSessionPlanningProvider);
    final notifier = ref.read(focusSessionPlanningProvider.notifier);
    final step = state.currentStep;

    // Completion screen lives outside the wizard — it is a post-ritual
    // confirmation, not a step the user walks through. The notifier still
    // owns currentStep so resuming mid-ritual returns to the same place.
    if (step >= _kProgressSegmentCount) {
      return const CeremonyPopScope(
        onBack: null,
        child: Scaffold(
          backgroundColor: Colors.white,
          body: SafeArea(child: ScheduledReviewStep()),
        ),
      );
    }

    final steps = <WizardStep>[
      _buildInboxStep(state, notifier),
      _buildReviewStep(state, notifier),
      _buildEnergyStep(state, notifier),
      _buildTimeStep(state, notifier),
      _buildPlanSummaryStep(state, notifier),
    ];

    return CeremonyPopScope(
      // System back mirrors the active step's footer Back; when that is
      // unavailable (step 0, first item) it exits to the execution home.
      onBack: _backForStep(step, state, notifier),
      child: Wizard(
        ceremonyLabel: 'Daily Planning',
        ceremonyIcon: Icons.wb_sunny_outlined,
        accentColor: _accent,
        currentStep: step,
        steps: steps,
        progressSegmentCount: _kProgressSegmentCount,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Step factories
  // ---------------------------------------------------------------------------

  VoidCallback? _backToPrevStep(
    FocusSessionPlanningState state,
    FocusSessionPlanningNotifier notifier,
  ) {
    if (state.currentStep == 0) return null;
    final previous = state.currentStep - 1;
    return () => notifier.goToStep(previous);
  }

  /// The Back callback for [stepIndex] — the same callback its footer
  /// renders. Null when Back is unavailable (step 0, first item), which
  /// [CeremonyPopScope] translates into a ceremony exit.
  VoidCallback? _backForStep(
    int stepIndex,
    FocusSessionPlanningState state,
    FocusSessionPlanningNotifier notifier,
  ) =>
      switch (stepIndex) {
        0 => state.inboxNav.canGoBack ? notifier.previousInboxItem : null,
        // At item 0 of the review snapshot Back crosses to Step 0.
        1 => state.reviewNav.canGoBack
            ? notifier.reviewBack
            : _backToPrevStep(state, notifier),
        _ => _backToPrevStep(state, notifier),
      };

  WizardStep _buildInboxStep(
    FocusSessionPlanningState state,
    FocusSessionPlanningNotifier notifier,
  ) {
    final nav = state.inboxNav;
    final hasMore = nav.isLoaded && !nav.isComplete;

    return WizardStep(
      title: _stepTitles[0],
      body: const InboxClarificationStep(),
      activeFraction: nav.isLoaded && !nav.isEmpty
          ? (nav.index / nav.length).clamp(0.0, 1.0)
          : 0.0,
      subtitle: _inboxSubtitle(state),
      footer: ListItemFooter(
        ceremonyId: _ceremonyId,
        accentColor: _accent,
        onBack: _backForStep(0, state, notifier),
        onSkip: notifier.skipInboxItem,
        // Next step is disabled until the inbox snapshot has loaded.
        onNext: nav.isLoaded ? notifier.advanceStep : null,
        hasMoreItems: hasMore,
      ),
    );
  }

  WizardStep _buildReviewStep(
    FocusSessionPlanningState state,
    FocusSessionPlanningNotifier notifier,
  ) {
    final nav = state.reviewNav;
    final hasMore = nav.isLoaded && !nav.isComplete;
    final activeFraction =
        nav.length > 0 ? (nav.index / nav.length).clamp(0.0, 1.0) : 1.0;

    return WizardStep(
      title: _stepTitles[1],
      body: const TaskReviewStep(),
      activeFraction: activeFraction,
      subtitle: 'Step 2 of $_kProgressSegmentCount · '
          '${nav.index} / ${nav.length} seen',
      footer: ListItemFooter(
        ceremonyId: _ceremonyId,
        accentColor: _accent,
        onBack: _backForStep(1, state, notifier),
        onSkip: notifier.skipReviewItem,
        onNext: notifier.advanceStep,
        hasMoreItems: hasMore,
      ),
    );
  }

  WizardStep _buildEnergyStep(
    FocusSessionPlanningState state,
    FocusSessionPlanningNotifier notifier,
  ) {
    // Energy-based filtering of Pending Review is a reactive selector on
    // `state.energyLevel` (see `nextForFocusSessionPlanningProvider`);
    // crossing into Time is a plain step advance.
    return WizardStep(
      title: _stepTitles[2],
      body: const DayCheckinEnergyStep(),
      activeFraction: state.energyLevel != null ? 1.0 : 0.0,
      subtitle: 'Step 3 of $_kProgressSegmentCount',
      footer: WizardFooter(
        ceremonyId: _ceremonyId,
        accentColor: _accent,
        onBack: _backToPrevStep(state, notifier),
        onNext: notifier.advanceStep,
      ),
    );
  }

  WizardStep _buildTimeStep(
    FocusSessionPlanningState state,
    FocusSessionPlanningNotifier notifier,
  ) {
    return WizardStep(
      title: _stepTitles[3],
      body: const DayCheckinTimeStep(),
      activeFraction: state.availableTimeSet ? 1.0 : 0.0,
      subtitle: 'Step 4 of $_kProgressSegmentCount',
      footer: WizardFooter(
        ceremonyId: _ceremonyId,
        accentColor: _accent,
        onBack: _backToPrevStep(state, notifier),
        onNext: notifier.advanceStep,
      ),
    );
  }

  WizardStep _buildPlanSummaryStep(
    FocusSessionPlanningState state,
    FocusSessionPlanningNotifier notifier,
  ) {
    return WizardStep(
      title: _stepTitles[4],
      body: const PlanSummaryStep(),
      subtitle: 'Step 5 of $_kProgressSegmentCount',
      footer: WizardFooter(
        ceremonyId: _ceremonyId,
        accentColor: _accent,
        onBack: _backToPrevStep(state, notifier),
        onNext: notifier.advanceStep,
      ),
    );
  }

  String _inboxSubtitle(FocusSessionPlanningState state) {
    final nav = state.inboxNav;
    if (!nav.isLoaded) {
      return 'Step 1 of $_kProgressSegmentCount · Loading inbox…';
    }
    // Count routings strictly below the cursor: this excludes both items
    // the user skipped (no routing recorded) and the item currently shown
    // when they've navigated Back to revisit it.
    final processed =
        state.inboxRoutings.keys.where((k) => k < nav.index).length;
    final skipped = nav.index - processed;
    return 'Step 1 of $_kProgressSegmentCount · '
        '$processed / ${nav.length} processed (skipped $skipped)';
  }
}

/// Blocking interstitial shown when Daily Planning is entered while a session
/// is still open (ADR-0020, ruling 4). The user must close the current session
/// before opening a new one; the primary action begins Evening Shutdown,
/// carrying an and-then-plan intent so Close Day routes back into planning.
class _SessionOpenInterstitial extends ConsumerWidget {
  const _SessionOpenInterstitial();

  static const _accent = Color(0xFF2563EB);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CeremonyPopScope(
      onBack: null,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.nightlight_outlined,
                    size: 56, color: Color(0xFF1E3A5F)),
                const SizedBox(height: 28),
                const Text(
                  'Close your current session first',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'A focus session is still open. Review and close it in '
                  'Evening Shutdown, then plan your next one — sessions never '
                  'close on their own.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.5,
                    color: Color(0xFF6B7280),
                  ),
                ),
                const SizedBox(height: 36),
                FilledButton(
                  onPressed: () {
                    // Carry the and-then-plan intent into Evening Shutdown.
                    ref.read(shutdownThenPlanProvider.notifier).set(true);
                    context.go('/shutdown');
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1E3A5F),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text(
                    'Begin Evening Shutdown',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => context.go('/focus'),
                  style: TextButton.styleFrom(foregroundColor: _accent),
                  child: const Text('Not now'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
