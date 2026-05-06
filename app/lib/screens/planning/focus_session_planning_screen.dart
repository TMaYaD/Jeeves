/// Focus session planning ritual — outer container screen (Issue #82).
///
/// Renders a full-screen, drawer-free scaffold with:
/// - A 5-segment progress bar (Inbox → Review → Energy → Time → Plan Summary).
///   The 6th screen (Today's Schedule) is the completion view: all 5 filled.
/// - A non-swipeable [PageView] that displays each step.
/// - Back / Next navigation buttons at the bottom (hidden on the last step).
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

  /// Handles the Next button tap, inserting any step-specific side-effects.
  void _handleNext(int step) {
    final notifier = ref.read(focusSessionPlanningProvider.notifier);
    if (step == 1) {
      final nav = ref.read(focusSessionPlanningProvider).reviewNav;
      if (nav.isLoaded && !nav.isComplete) {
        // Still items to review — skip the current one.
        notifier.skipReviewItem();
      } else {
        notifier.advanceStep();
      }
    } else if (step == 2) {
      // Energy → Time: auto-skip tasks that exceed today's energy.
      notifier.autoSkipByEnergy().then((_) => notifier.advanceStep());
    } else {
      notifier.advanceStep();
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
                step: step,
                onBack: step == 0
                    ? null
                    : step == 1
                        ? () {
                            if (ref.read(focusSessionPlanningProvider).reviewNav.index > 0) {
                              notifier.reviewBack();
                            } else {
                              notifier.goToStep(0);
                            }
                          }
                        : () => notifier.goToStep(step - 1),
                onNext: _canAdvance(step, ref) ? () => _handleNext(step) : null,
              ),
          ],
        ),
      ),
    );
  }

  /// Returns true when the user is allowed to proceed from [step].
  bool _canAdvance(int step, WidgetRef ref) {
    final s = ref.watch(focusSessionPlanningProvider);
    return switch (step) {
      // Step 0: inbox snapshot loaded and all items processed or skipped.
      0 => s.inboxNav.isComplete,
      // Step 1: task review — always enabled; tapping Next skips the current item.
      1 => true,
      // Step 2: energy check in
      2 => true,
      // Step 3: time check in
      3 => true,
      // Step 4: Plan Summary and Next Actions view is fully controllable
      4 => true,
      // Step 5: ScheduledReviewStep is last page
      5 => false,
      _ => false,
    };
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
// Footer: Back / Next buttons
// ---------------------------------------------------------------------------

class _PlanningFooter extends StatelessWidget {
  const _PlanningFooter({
    required this.step,
    required this.onBack,
    required this.onNext,
  });

  final int step;
  final VoidCallback? onBack;
  final VoidCallback? onNext;

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
          FilledButton(
            onPressed: onNext,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              disabledBackgroundColor: const Color(0xFFD1D5DB),
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
            ),
            child: const Text('Next'),
          ),
        ],
      ),
    );
  }
}
