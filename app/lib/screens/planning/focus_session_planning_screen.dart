/// Focus session planning ritual — outer container screen (Issue #82).
///
/// Renders a full-screen, drawer-free scaffold with:
/// - A 4-segment progress bar (Inbox → Energy → Time → Plan Summary).
///   The 5th screen (Today's Schedule) is the completion view: all 4 filled.
/// - A non-swipeable [PageView] that displays each step.
/// - Back / Next navigation buttons at the bottom (hidden on the last step).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/focus_session_planning_provider.dart';
import '../../providers/inbox_provider.dart';
import 'steps/day_checkin_energy_step.dart';
import 'steps/day_checkin_time_step.dart';
import 'steps/inbox_clarification_step.dart';
import 'steps/plan_summary_step.dart';
import 'steps/scheduled_review_step.dart';

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
    // Auto-advance from inbox step if inbox is already empty on first load.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeAutoAdvanceInbox(ref.read(inboxItemsProvider));
    });
  }

  /// Auto-advances from step 0 to step 1 when the inbox has no pending items.
  ///
  /// Called both on first load (via [addPostFrameCallback] in [initState]) and
  /// whenever [inboxItemsProvider] emits a new value (via [ref.listen]).
  void _maybeAutoAdvanceInbox(AsyncValue<List<Todo>> inboxAsync) {
    if (ref.read(focusSessionPlanningProvider).currentStep != 0) return;
    final items = inboxAsync.asData?.value;
    if (items == null) return; // still loading
    if (items.isEmpty) {
      ref.read(focusSessionPlanningProvider.notifier).advanceStep();
    }
  }

  /// Handles the Next button tap, inserting any step-specific side-effects.
  void _handleNext(int step) {
    final notifier = ref.read(focusSessionPlanningProvider.notifier);
    if (step == 1) {
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

    // Animate the PageView only when currentStep actually changes.
    ref.listen<FocusSessionPlanningState>(focusSessionPlanningProvider,
        (prev, next) {
      if (prev?.currentStep != next.currentStep && _pageController.hasClients) {
        _pageController.animateToPage(
          next.currentStep,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    });

    // Auto-advance from inbox step when inbox becomes empty mid-session.
    ref.listen<AsyncValue<List<Todo>>>(
      inboxItemsProvider,
      (_, next) => _maybeAutoAdvanceInbox(next),
    );

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
                  DayCheckinEnergyStep(),
                  DayCheckinTimeStep(),
                  PlanSummaryStep(),
                  ScheduledReviewStep(),
                ],
              ),
            ),
            if (step < 4)
              _PlanningFooter(
                step: step,
                onBack: step > 0 ? () => notifier.goToStep(step - 1) : null,
                onNext: _canAdvance(step, ref) ? () => _handleNext(step) : null,
              ),
          ],
        ),
      ),
    );
  }

  /// Returns true when the user is allowed to proceed from [step].
  bool _canAdvance(int step, WidgetRef ref) {
    return switch (step) {
      // Step 0: inbox empty (all items clarified or none remaining)
      0 => ref.watch(inboxItemsProvider).asData?.value.isEmpty ?? false,
      // Step 1: energy check in
      1 => true,
      // Step 2: time check in
      2 => true,
      // Step 3: Plan Summary and Next Actions view is fully controllable
      3 => true,
      // Step 4: ScheduledReviewStep is last page
      4 => false,
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
          _SegmentedProgressBar(currentStep: step, totalSteps: 4, ref: ref),
          const SizedBox(height: 4),
          _buildSubtitle(step, ref),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildSubtitle(int step, WidgetRef ref) {
    if (step == 0) {
      final state = ref.watch(focusSessionPlanningProvider);
      final initial = state.initialInboxCount ?? 0;
      final processed = state.inboxClarifiedCount + state.inboxSkippedCount;
      final skipped = state.inboxSkippedCount;
      return Text(
        'Step 1 of 4 · $processed / $initial processed (skipped $skipped)',
        style: TextStyle(fontSize: 12, color: Colors.grey[400]),
      );
    }
    // Step 4 = Today's Schedule (completion screen — all 4 segments filled).
    if (step >= 4) {
      return Text(
        'Planning complete',
        style: TextStyle(fontSize: 12, color: Colors.grey[400]),
      );
    }
    return Text(
      'Step ${step + 1} of 4',
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
  /// - Step 1 (energy): 1.0 when an energy level has been chosen, else 0.0.
  /// - Step 2 (time): 1.0 when the user has explicitly set available time.
  /// - All other steps: 0.0 (segment stays empty until the step is completed).
  double _currentStepFraction(int step, FocusSessionPlanningState state) {
    switch (step) {
      case 0:
        final initial = state.initialInboxCount ?? 1;
        final processed = state.inboxClarifiedCount + state.inboxSkippedCount;
        return initial > 0 ? (processed / initial).clamp(0.0, 1.0) : 1.0;
      case 1:
        return state.energyLevel != null ? 1.0 : 0.0;
      case 2:
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
