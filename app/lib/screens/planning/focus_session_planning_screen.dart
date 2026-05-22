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

import '../../models/ritual.dart';
import '../../providers/ceremony_in_progress_provider.dart';
import '../../providers/focus_session_planning_provider.dart';
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
    // ADR-0009: hold the Nudge while this Ceremony performance is in progress.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(ceremonyInProgressProvider.notifier)
          .enter(RitualId.dailyPlanning);
    });
  }

  @override
  void dispose() {
    ref.read(ceremonyInProgressProvider.notifier).exit(RitualId.dailyPlanning);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(focusSessionPlanningProvider);
    final notifier = ref.read(focusSessionPlanningProvider.notifier);
    final step = state.currentStep;

    // Completion screen lives outside the wizard — it is a post-ritual
    // confirmation, not a step the user walks through. The notifier still
    // owns currentStep so resuming mid-ritual returns to the same place.
    if (step >= _kProgressSegmentCount) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(child: ScheduledReviewStep()),
      );
    }

    final steps = <WizardStep>[
      _buildInboxStep(state, notifier),
      _buildReviewStep(state, notifier),
      _buildEnergyStep(state, notifier),
      _buildTimeStep(state, notifier),
      _buildPlanSummaryStep(state, notifier),
    ];

    return Wizard(
      ceremonyLabel: 'Daily Planning',
      ceremonyIcon: Icons.wb_sunny_outlined,
      accentColor: _accent,
      currentStep: step,
      steps: steps,
      progressSegmentCount: _kProgressSegmentCount,
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
        onBack: nav.canGoBack ? notifier.previousInboxItem : null,
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
        // At item 0 of the review snapshot Back should cross to Step 0.
        onBack: nav.canGoBack
            ? notifier.reviewBack
            : _backToPrevStep(state, notifier),
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
    // `state.energyLevel` (see `nextActionsForFocusSessionPlanningProvider`);
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
