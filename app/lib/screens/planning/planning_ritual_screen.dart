/// Daily planning ritual — outer container screen (Issue #82).
///
/// Renders a full-screen, drawer-free scaffold with:
/// - A segmented progress bar across the top (4 steps).
/// - A non-swipeable [PageView] that displays each ritual step.
/// - Back / Next navigation buttons at the bottom.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/daily_planning_provider.dart';
import 'steps/next_actions_review_step.dart';
import 'steps/plan_summary_step.dart';
import 'steps/scheduled_review_step.dart';
import 'steps/time_estimates_step.dart';

class PlanningRitualScreen extends ConsumerStatefulWidget {
  const PlanningRitualScreen({super.key});

  @override
  ConsumerState<PlanningRitualScreen> createState() =>
      _PlanningRitualScreenState();
}

class _PlanningRitualScreenState extends ConsumerState<PlanningRitualScreen> {
  late final PageController _pageController;

  static const _stepTitles = [
    'Review Next Actions',
    'Today\'s Schedule',
    'Time Estimates',
    'Today\'s Plan',
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final planningState = ref.watch(dailyPlanningProvider);
    final notifier = ref.read(dailyPlanningProvider.notifier);
    final step = planningState.currentStep;

    // Animate the PageView only when currentStep actually changes.
    // Using ref.listen avoids scheduling a callback on every build.
    ref.listen<DailyPlanningState>(dailyPlanningProvider, (prev, next) {
      if (prev?.currentStep != next.currentStep && _pageController.hasClients) {
        _pageController.animateToPage(
          next.currentStep,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
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
                children: const [
                  NextActionsReviewStep(),
                  ScheduledReviewStep(),
                  TimeEstimatesStep(),
                  PlanSummaryStep(),
                ],
              ),
            ),
            if (step < 3)
              _PlanningFooter(
                step: step,
                onBack: step > 0 ? () => notifier.goToStep(step - 1) : null,
                onNext: _canAdvance(step, ref)
                    ? () => notifier.advanceStep()
                    : null,
              ),
          ],
        ),
      ),
    );
  }

  /// Returns true when the user is allowed to proceed from [step].
  bool _canAdvance(int step, WidgetRef ref) {
    return switch (step) {
      // Step 1: all next actions reviewed
      0 => ref.watch(nextActionsForPlanningProvider).asData?.value.isEmpty ??
          false,
      // Step 2: all scheduled items confirmed / rescheduled
      1 => ref.watch(scheduledDueTodayProvider).asData?.value.isEmpty ?? false,
      // Step 3: no selected task is missing an estimate
      2 => ref
              .watch(selectedTasksMissingEstimatesProvider)
              .asData
              ?.value
              .isEmpty ??
          false,
      _ => false,
    };
  }
}

// ---------------------------------------------------------------------------
// Header: title + segmented progress bar
// ---------------------------------------------------------------------------

class _PlanningHeader extends StatelessWidget {
  const _PlanningHeader({required this.step, required this.stepTitle});

  final int step;
  final String stepTitle;

  @override
  Widget build(BuildContext context) {
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
          _SegmentedProgressBar(currentStep: step, totalSteps: 4),
          const SizedBox(height: 4),
          Text(
            'Step ${step + 1} of 4',
            style: TextStyle(fontSize: 12, color: Colors.grey[400]),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SegmentedProgressBar extends StatelessWidget {
  const _SegmentedProgressBar(
      {required this.currentStep, required this.totalSteps});

  final int currentStep;
  final int totalSteps;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(totalSteps, (i) {
        final filled = i <= currentStep;
        return Expanded(
          child: Container(
            margin: EdgeInsets.only(right: i < totalSteps - 1 ? 4 : 0),
            height: 4,
            decoration: BoxDecoration(
              color: filled ? const Color(0xFF2563EB) : const Color(0xFFE5E7EB),
              borderRadius: BorderRadius.circular(2),
            ),
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
