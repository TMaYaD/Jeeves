/// Weekly Review wizard — outer container screen (Issue #54).
///
/// Renders a non-swipeable [PageView] with seven children: five GTD review
/// steps, an objectives step, and a final summary. Step transitions go
/// through [PeriodicReviewNotifier.advanceStep] / [goToStep], which in turn
/// drives per-step snapshot loading.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/periodic_review_provider.dart';
import 'steps/brain_dump_step.dart';
import 'steps/objectives_step.dart';
import 'steps/projects_step.dart';
import 'steps/someday_maybe_step.dart';
import 'steps/summary_step.dart';
import 'steps/waiting_for_step.dart';
import 'steps/zero_inbox_step.dart';

class PeriodicReviewScreen extends ConsumerStatefulWidget {
  const PeriodicReviewScreen({super.key});

  @override
  ConsumerState<PeriodicReviewScreen> createState() =>
      _PeriodicReviewScreenState();
}

class _PeriodicReviewScreenState
    extends ConsumerState<PeriodicReviewScreen> {
  late final PageController _pageController;

  static const _stepTitles = [
    'Process Inbox',
    'Brain Dump',
    'Review Waiting For',
    'Review Projects',
    'Review Someday/Maybe',
    'Set Objectives',
    'Review Complete',
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(
      initialPage: ref.read(periodicReviewProvider).currentStep,
    );
    // Trigger entry-side effects for the initial step.
    Future.microtask(() {
      if (!mounted) return;
      final state = ref.read(periodicReviewProvider);
      // goToStep is idempotent and fires the entry hook.
      ref.read(periodicReviewProvider.notifier).goToStep(state.currentStep);
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(periodicReviewProvider);
    final notifier = ref.read(periodicReviewProvider.notifier);
    final step = state.currentStep;

    ref.listen<PeriodicReviewState>(periodicReviewProvider, (prev, next) {
      if (prev?.currentStep != next.currentStep &&
          _pageController.hasClients) {
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
            _PeriodicReviewHeader(
              step: step,
              stepTitle: _stepTitles[step],
              state: state,
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: const [
                  ZeroInboxStep(),
                  BrainDumpStep(),
                  WaitingForStep(),
                  ProjectsStep(),
                  SomedayMaybeStep(),
                  ObjectivesStep(),
                  SummaryStep(),
                ],
              ),
            ),
            if (step != PeriodicReviewNotifier.kStepSummary)
              _PeriodicReviewFooter(
                step: step,
                onBack: _backHandler(step, state, notifier),
                onNext: _nextHandler(step, state, notifier),
                isFinish: step == PeriodicReviewNotifier.kStepObjectives,
              ),
          ],
        ),
      ),
    );
  }

  VoidCallback? _backHandler(
    int step,
    PeriodicReviewState state,
    PeriodicReviewNotifier notifier,
  ) {
    if (step == PeriodicReviewNotifier.kStepInbox) return null;
    return () {
      switch (step) {
        case PeriodicReviewNotifier.kStepWaitingFor:
          if (state.waitingForNav.canGoBack) {
            notifier.previousWaitingFor();
          } else {
            notifier.goToStep(step - 1);
          }
        case PeriodicReviewNotifier.kStepProjects:
          if (state.projectsNav.canGoBack) {
            notifier.previousProjects();
          } else {
            notifier.goToStep(step - 1);
          }
        case PeriodicReviewNotifier.kStepSomeMaybe:
          if (state.somedayNav.canGoBack) {
            notifier.previousSomeday();
          } else {
            notifier.goToStep(step - 1);
          }
        default:
          notifier.goToStep(step - 1);
      }
    };
  }

  VoidCallback? _nextHandler(
    int step,
    PeriodicReviewState state,
    PeriodicReviewNotifier notifier,
  ) {
    switch (step) {
      case PeriodicReviewNotifier.kStepInbox:
        // Only let the user advance once the snapshot is loaded — same
        // pattern as the planning Inbox step.
        if (!state.inboxNav.isLoaded) return null;
        return notifier.advanceStep;
      case PeriodicReviewNotifier.kStepObjectives:
        // Finish requires at least one non-empty objective.
        final hasAny =
            state.objectives.any((o) => o.trim().isNotEmpty);
        if (!hasAny) return null;
        return notifier.advanceStep;
      default:
        return notifier.advanceStep;
    }
  }
}

// ---------------------------------------------------------------------------
// Header — title + segmented progress bar
// ---------------------------------------------------------------------------

class _PeriodicReviewHeader extends StatelessWidget {
  const _PeriodicReviewHeader({
    required this.step,
    required this.stepTitle,
    required this.state,
  });

  final int step;
  final String stepTitle;
  final PeriodicReviewState state;

  static const _accent = Color(0xFF059669);

  double _activeFraction() {
    switch (step) {
      case PeriodicReviewNotifier.kStepInbox:
        final nav = state.inboxNav;
        if (!nav.isLoaded || nav.isEmpty) return 0.0;
        return (nav.index / nav.length).clamp(0.0, 1.0);
      case PeriodicReviewNotifier.kStepBrainDump:
        return state.brainDumpAdded > 0 ? 1.0 : 0.0;
      case PeriodicReviewNotifier.kStepWaitingFor:
        final nav = state.waitingForNav;
        if (!nav.isLoaded || nav.isEmpty) return 0.0;
        return (nav.index / nav.length).clamp(0.0, 1.0);
      case PeriodicReviewNotifier.kStepProjects:
        final nav = state.projectsNav;
        if (!nav.isLoaded || nav.isEmpty) return 0.0;
        return (nav.index / nav.length).clamp(0.0, 1.0);
      case PeriodicReviewNotifier.kStepSomeMaybe:
        final nav = state.somedayNav;
        if (!nav.isLoaded || nav.isEmpty) return 0.0;
        return (nav.index / nav.length).clamp(0.0, 1.0);
      case PeriodicReviewNotifier.kStepObjectives:
        return state.objectives.any((o) => o.trim().isNotEmpty) ? 1.0 : 0.0;
      default:
        return 0.0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.refresh, color: _accent, size: 20),
              const SizedBox(width: 8),
              Text(
                'Weekly Review',
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
          _SegmentedProgressBar(
            currentStep: step,
            totalSteps: 6,
            activeFraction: _activeFraction(),
            accent: _accent,
          ),
          const SizedBox(height: 4),
          Text(
            step == PeriodicReviewNotifier.kStepSummary
                ? 'Review complete'
                : 'Step ${step + 1} of 6',
            style: TextStyle(fontSize: 12, color: Colors.grey[400]),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SegmentedProgressBar extends StatelessWidget {
  const _SegmentedProgressBar({
    required this.currentStep,
    required this.totalSteps,
    required this.activeFraction,
    required this.accent,
  });

  final int currentStep;
  final int totalSteps;
  final double activeFraction;
  final Color accent;

  Widget _buildBar(double fraction) {
    if (fraction >= 1.0) {
      return Container(
        height: 4,
        decoration: BoxDecoration(
          color: accent,
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
              color: accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(totalSteps, (i) {
        final double fraction;
        if (i < currentStep) {
          fraction = 1.0;
        } else if (i == currentStep) {
          fraction = activeFraction;
        } else if (currentStep >= totalSteps) {
          // Summary step — all segments full.
          fraction = 1.0;
        } else {
          fraction = 0.0;
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
// Footer — Back / Next
// ---------------------------------------------------------------------------

class _PeriodicReviewFooter extends StatelessWidget {
  const _PeriodicReviewFooter({
    required this.step,
    required this.onBack,
    required this.onNext,
    required this.isFinish,
  });

  final int step;
  final VoidCallback? onBack;
  final VoidCallback? onNext;
  final bool isFinish;

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
            key: const Key('periodic_review_next'),
            onPressed: onNext,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF059669),
              disabledBackgroundColor: const Color(0xFFD1D5DB),
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
            ),
            child: Text(isFinish ? 'Finish' : 'Next'),
          ),
        ],
      ),
    );
  }
}
