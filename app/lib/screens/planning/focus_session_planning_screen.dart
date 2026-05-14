/// Focus session planning ritual — outer container screen (Issue #82).
///
/// Renders a full-screen, drawer-free scaffold with:
/// - A 5-segment progress bar (Inbox → Review → Energy → Time → Plan Summary).
///   The 6th screen (Today's Schedule) is the completion view: all 5 filled.
/// - A non-swipeable [PageView] that displays each step.
/// - A Back button plus a single forward affordance at the bottom (hidden on
///   the last step): a secondary Skip while the step's item cursor still has
///   items, swapping to a primary Next step once it is spent.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/focus_session_planning_provider.dart';
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
  late final PageController _pageController;

  static const _stepTitles = [
    'Clarify Inbox',
    'Review Tasks',
    'Energy Check-in',
    'Time Check-in',
    'Review Next Actions',
    'Today\'s Schedule',
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(
      initialPage: ref.read(focusSessionPlanningProvider).currentStep,
    );
  }

  /// Picks the footer's single forward affordance for [step] and the callback
  /// that drives it, preserving the screen's existing per-step behaviour:
  /// Skip advances the per-item cursor while items remain; Next step crosses
  /// into the following step, carrying any step-specific side effect.
  ///
  /// A null callback means a disabled button — the only such case is Step 0's
  /// Next step before the inbox snapshot has loaded.
  (_FooterAction, VoidCallback?) _footerAction(int step) {
    final notifier = ref.read(focusSessionPlanningProvider.notifier);
    final state = ref.watch(focusSessionPlanningProvider);
    switch (step) {
      case 0:
        // Inbox — Next step is disabled until the snapshot loads. Once loaded,
        // Skip advances the per-item cursor until nothing remains.
        if (!state.inboxNav.isLoaded) return (_FooterAction.nextStep, null);
        return state.inboxNav.isComplete
            ? (_FooterAction.nextStep, notifier.advanceStep)
            : (_FooterAction.skip, notifier.skipInboxItem);
      case 1:
        // Task review — Skip advances the per-item cursor while items remain;
        // otherwise (including before the snapshot loads) Next step crosses.
        if (state.reviewNav.isLoaded && !state.reviewNav.isComplete) {
          return (_FooterAction.skip, notifier.skipReviewItem);
        }
        return (_FooterAction.nextStep, notifier.advanceStep);
      case 2:
        // Energy → Time: auto-skip tasks that exceed today's energy first.
        return (
          _FooterAction.nextStep,
          () => notifier.autoSkipByEnergy().whenComplete(notifier.advanceStep),
        );
      default:
        return (_FooterAction.nextStep, notifier.advanceStep);
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final planningState = ref.watch(focusSessionPlanningProvider);
    final notifier = ref.read(focusSessionPlanningProvider.notifier);
    final step = planningState.currentStep;
    final footer = _footerAction(step);

    // Animate the PageView when currentStep changes; also auto-advance from
    // Step 0 when the inbox snapshot loads and is empty.
    ref.listen<FocusSessionPlanningState>(focusSessionPlanningProvider,
        (prev, next) {
      if (prev?.currentStep != next.currentStep && _pageController.hasClients) {
        _pageController.animateToPage(
          next.currentStep,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
      // Auto-advance when the snapshot loads to empty (inbox was already clear).
      if (next.currentStep == 0 &&
          next.inboxNav.isLoaded &&
          next.inboxNav.isEmpty &&
          (prev == null || !prev.inboxNav.isLoaded)) {
        ref.read(focusSessionPlanningProvider.notifier).advanceStep();
      }
    });

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            _PlanningHeader(
              step: step,
              stepTitle: _stepTitles[step],
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  InboxClarificationStep(),
                  TaskReviewStep(),
                  DayCheckinEnergyStep(),
                  DayCheckinTimeStep(),
                  PlanSummaryStep(),
                  ScheduledReviewStep(),
                ],
              ),
            ),
            if (step < 5)
              _PlanningFooter(
                onBack: step == 0
                    ? (ref.watch(focusSessionPlanningProvider).inboxNav.canGoBack
                        ? () => notifier.previousInboxItem()
                        : null)
                    : step == 1
                        ? () {
                            if (ref.read(focusSessionPlanningProvider).reviewNav.canGoBack) {
                              notifier.reviewBack();
                            } else {
                              notifier.goToStep(0);
                            }
                          }
                        : () => notifier.goToStep(step - 1),
                action: footer.$1,
                onPressed: footer.$2,
              ),
          ],
        ),
      ),
    );
  }

}

// ---------------------------------------------------------------------------
// Header: title + segmented progress bar
// ---------------------------------------------------------------------------

class _PlanningHeader extends ConsumerWidget {
  const _PlanningHeader({required this.step, required this.stepTitle});

  final int step;
  final String stepTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.wb_sunny_outlined,
                  color: Color(0xFF2563EB), size: 20),
              const SizedBox(width: 8),
              Text(
                'Daily Planning',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[500],
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            stepTitle,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 14),
          _SegmentedProgressBar(currentStep: step, totalSteps: 5, ref: ref),
          const SizedBox(height: 4),
          _buildSubtitle(step, ref),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildSubtitle(int step, WidgetRef ref) {
    if (step == 0) {
      final nav = ref.watch(focusSessionPlanningProvider).inboxNav;
      if (!nav.isLoaded) {
        return Text(
          'Step 1 of 5 · Loading inbox…',
          style: TextStyle(fontSize: 12, color: Colors.grey[400]),
        );
      }
      final routings =
          ref.watch(focusSessionPlanningProvider.select((s) => s.inboxRoutings));
      // Count routings strictly below the cursor: this excludes both items
      // the user skipped (no routing recorded) and the item currently shown
      // when they've navigated Back to revisit it.
      final processed = routings.keys.where((k) => k < nav.index).length;
      final skipped = nav.index - processed;
      return Text(
        'Step 1 of 5 · $processed / ${nav.length} processed (skipped $skipped)',
        style: TextStyle(fontSize: 12, color: Colors.grey[400]),
      );
    }
    if (step == 1) {
      final nav = ref.watch(focusSessionPlanningProvider).reviewNav;
      return Text(
        'Step 2 of 5 · ${nav.index} / ${nav.length} reviewed',
        style: TextStyle(fontSize: 12, color: Colors.grey[400]),
      );
    }
    // Step 5 = Today's Schedule (completion screen — all 5 segments filled).
    if (step >= 5) {
      return Text(
        'Planning complete',
        style: TextStyle(fontSize: 12, color: Colors.grey[400]),
      );
    }
    return Text(
      'Step ${step + 1} of 5',
      style: TextStyle(fontSize: 12, color: Colors.grey[400]),
    );
  }
}

class _SegmentedProgressBar extends StatelessWidget {
  const _SegmentedProgressBar(
      {required this.currentStep, required this.totalSteps, required this.ref});

  final int currentStep;
  final int totalSteps;
  final WidgetRef ref;

  /// Returns the fill fraction (0.0–1.0) for the current segment of [step].
  ///
  /// - Step 0 (inbox): ratio of items processed so far.
  /// - Step 1 (task review): ratio of review items acted on so far.
  /// - Step 2 (energy): 1.0 when an energy level has been chosen, else 0.0.
  /// - Step 3 (time): 1.0 when the user has explicitly set available time.
  /// - All other steps: 0.0 (segment stays empty until the step is completed).
  double _currentStepFraction(int step, FocusSessionPlanningState state) {
    switch (step) {
      case 0:
        final nav = state.inboxNav;
        if (!nav.isLoaded || nav.isEmpty) return 0.0;
        return (nav.index / nav.length).clamp(0.0, 1.0);
      case 1:
        final nav = state.reviewNav;
        return nav.length > 0 ? (nav.index / nav.length).clamp(0.0, 1.0) : 1.0;
      case 2:
        return state.energyLevel != null ? 1.0 : 0.0;
      case 3:
        return state.availableTimeSet ? 1.0 : 0.0;
      default:
        return 0.0;
    }
  }

  Widget _buildBar(double fraction) {
    if (fraction >= 1.0) {
      return Container(
        height: 4,
        decoration: BoxDecoration(
          color: const Color(0xFF2563EB),
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    if (fraction <= 0.0) {
      return Container(
        height: 4,
        decoration: BoxDecoration(
          color: const Color(0xFFE5E7EB),
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    // Partial fill
    return Stack(
      children: [
        Container(
          height: 4,
          decoration: BoxDecoration(
            color: const Color(0xFFE5E7EB),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        FractionallySizedBox(
          widthFactor: fraction,
          child: Container(
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFF2563EB),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(focusSessionPlanningProvider);

    return Row(
      children: List.generate(totalSteps, (i) {
        final double fraction;
        if (i < currentStep) {
          fraction = 1.0; // completed step
        } else if (i == currentStep) {
          fraction = _currentStepFraction(i, state); // active step
        } else {
          fraction = 0.0; // future step
        }

        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < totalSteps - 1 ? 4 : 0),
            child: _buildBar(fraction),
          ),
        );
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// Footer: Back + a single forward affordance (Skip or Next step)
// ---------------------------------------------------------------------------

/// Which forward affordance the footer renders. The two never co-exist; the
/// footer swaps between them inside a fixed-size slot so the button's shape,
/// size, and position are identical across the swap.
enum _FooterAction { skip, nextStep }

class _PlanningFooter extends StatelessWidget {
  const _PlanningFooter({
    required this.onBack,
    required this.action,
    required this.onPressed,
  });

  final VoidCallback? onBack;

  /// Selects which forward button to render.
  final _FooterAction action;

  /// Tap handler for the rendered button. Always non-null for [_FooterAction.skip];
  /// null for [_FooterAction.nextStep] only while Step 0's inbox snapshot is
  /// still loading (renders a disabled Next step).
  final VoidCallback? onPressed;

  // Fixed slot dimensions so the OutlinedButton ↔ FilledButton swap causes no
  // layout shift. Width is sized to comfortably fit the "Next step" label.
  static const double _slotWidth = 148;
  static const double _slotHeight = 48;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Row(
        children: [
          if (onBack != null)
            OutlinedButton(
              onPressed: onBack,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF374151),
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              ),
              child: const Text('Back'),
            ),
          const Spacer(),
          SizedBox(
            key: const Key('planning_footer_slot'),
            width: _slotWidth,
            height: _slotHeight,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: _buildAction(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAction() {
    switch (action) {
      case _FooterAction.skip:
        return OutlinedButton(
          key: const Key('planning_skip'),
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF6B7280),
            minimumSize: const Size(_slotWidth, _slotHeight),
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
          ),
          child: const Text('Skip'),
        );
      case _FooterAction.nextStep:
        return FilledButton(
          key: const Key('planning_next_step'),
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF2563EB),
            disabledBackgroundColor: const Color(0xFFD1D5DB),
            minimumSize: const Size(_slotWidth, _slotHeight),
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
          ),
          child: const Text('Next step'),
        );
    }
  }
}
