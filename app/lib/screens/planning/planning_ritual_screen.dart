/// Daily planning ritual — outer container screen (Issue #82).
///
/// Renders a full-screen, drawer-free scaffold with:
/// - A segmented progress bar across the top (6 steps).
/// - A non-swipeable [PageView] that displays each ritual step.
/// - Back / Next navigation buttons at the bottom.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/daily_planning_provider.dart';
import '../../providers/inbox_provider.dart';
import 'steps/day_checkin_energy_step.dart';
import 'steps/day_checkin_time_step.dart';
import 'steps/inbox_clarification_step.dart';
import 'steps/plan_summary_step.dart';
import 'steps/scheduled_review_step.dart';

class PlanningRitualScreen extends ConsumerStatefulWidget {
  const PlanningRitualScreen({super.key});

  @override
  ConsumerState<PlanningRitualScreen> createState() =>
      _PlanningRitualScreenState();
}

class _PlanningRitualScreenState extends ConsumerState<PlanningRitualScreen> {
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
      initialPage: ref.read(dailyPlanningProvider).currentStep,
    );
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
      // Step 0: inbox empty or skipped out of queue
      0 => ref.watch(inboxItemsProvider).asData?.value.where((i) => !(i.selectedForToday == false && i.dailySelectionDate == ref.read(planningSessionDateProvider))).isEmpty ?? false,
      // Step 1: energy check in
      1 => true,
      // Step 2: time check in
      2 => true,
      // Step 3: Plan Summary and Next Actions view is fully controllable, just let them advance
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
      final state = ref.watch(dailyPlanningProvider);
      final initial = state.initialInboxCount ?? 0;
      final processed = state.inboxClarifiedCount + state.inboxSkippedCount;
      final skipped = state.inboxSkippedCount;
      return Text(
        'Step 1 of 5. $processed processed out of $initial (skipped $skipped)',
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

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dailyPlanningProvider);
    final initial = state.initialInboxCount ?? 1;
    final processed = state.inboxClarifiedCount + state.inboxSkippedCount;
    final clarifyProgress = initial > 0 ? (processed / initial).clamp(0.0, 1.0) : 1.0;

    return Row(
      children: List.generate(totalSteps, (i) {
        final isClarify = i == 0;
        final filled = i < currentStep;
        
        Widget bar = Container(
          height: 4,
          decoration: BoxDecoration(
            color: filled ? const Color(0xFF2563EB) : const Color(0xFFE5E7EB),
            borderRadius: BorderRadius.circular(2),
          ),
        );

        if (isClarify && currentStep == 0) {
          bar = Stack(
            children: [
              Container(
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE5E7EB),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              FractionallySizedBox(
                widthFactor: clarifyProgress,
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

        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < totalSteps - 1 ? 4 : 0),
            child: bar,
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
