/// Evening shutdown ritual — outer container screen (Issue #83).
///
/// Steps 0–1 share a header (segmented progress bar) and footer (Back/Next).
/// Step 2 — Close Day — is rendered full-screen with the moon-rise animation;
/// it commits dispositions, fades out, and exits the app.
///
/// Step 1 → Step 2 advances automatically once the user resolves the last
/// unfinished task.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/evening_shutdown_provider.dart';
import 'steps/close_day_step.dart';
import 'steps/completed_review_step.dart';
import 'steps/unfinished_tasks_step.dart';

class ShutdownRitualScreen extends ConsumerStatefulWidget {
  const ShutdownRitualScreen({super.key});

  @override
  ConsumerState<ShutdownRitualScreen> createState() =>
      _ShutdownRitualScreenState();
}

class _ShutdownRitualScreenState extends ConsumerState<ShutdownRitualScreen> {
  late final PageController _pageController;
  int? _resolveInitialTotal;

  static const _stepTitles = ['Review Your Day', 'Resolve Unfinished'];

  @override
  void initState() {
    super.initState();
    final initialStep = ref.read(eveningShutdownProvider).currentStep;
    _pageController = PageController(
      initialPage: initialStep.clamp(0, _stepTitles.length - 1),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shutdownState = ref.watch(eveningShutdownProvider);
    final notifier = ref.read(eveningShutdownProvider.notifier);
    final step = shutdownState.currentStep;

    if (step == 2) return const CloseDayStep();

    ref.listen<EveningShutdownState>(eveningShutdownProvider, (prev, next) {
      if (prev?.currentStep != next.currentStep &&
          next.currentStep < _stepTitles.length &&
          _pageController.hasClients) {
        _pageController.animateToPage(
          next.currentStep,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    });

    // Latch the initial unfinished count once so the resolve progress fills
    // correctly, then auto-advance to Close Day on the transition to empty.
    ref.listen<AsyncValue<List<Todo>>>(unfinishedSelectedTodayProvider,
        (prev, next) {
      final tasks = next.asData?.value;
      if (tasks == null) return;
      if (tasks.isNotEmpty && _resolveInitialTotal == null) {
        setState(() => _resolveInitialTotal = tasks.length);
      }
      final wasNonEmpty = prev?.asData?.value.isNotEmpty ?? false;
      if (wasNonEmpty &&
          tasks.isEmpty &&
          ref.read(eveningShutdownProvider).currentStep == 1) {
        notifier.advanceStep();
      }
    });

    double? resolveProgress;
    if (step == 1 && _resolveInitialTotal != null && _resolveInitialTotal! > 0) {
      final current =
          ref.watch(unfinishedSelectedTodayProvider).asData?.value.length;
      if (current != null) {
        final resolved = _resolveInitialTotal! - current;
        resolveProgress = (resolved / _resolveInitialTotal!).clamp(0.0, 1.0);
      }
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            _ShutdownHeader(
              step: step,
              stepTitle: _stepTitles[step],
              activeStepProgress: resolveProgress,
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: const [
                  CompletedReviewStep(),
                  UnfinishedTasksStep(),
                ],
              ),
            ),
            _ShutdownFooter(
              step: step,
              onBack: step > 0 ? () => notifier.goToStep(step - 1) : null,
              onNext: _canAdvance(step, ref) ? () => notifier.advanceStep() : null,
            ),
          ],
        ),
      ),
    );
  }

  /// Returns true when the user is allowed to proceed from [step].
  bool _canAdvance(int step, WidgetRef ref) {
    return switch (step) {
      // Step 0: completed review — always navigable (informational).
      0 => true,
      // Step 1: only manually advanceable when there were no unfinished tasks
      // to begin with; otherwise the auto-advance listener handles it.
      1 => ref.watch(unfinishedSelectedTodayProvider).asData?.value.isEmpty ??
          false,
      _ => false,
    };
  }
}

// ---------------------------------------------------------------------------
// Header: title + segmented progress bar
// ---------------------------------------------------------------------------

class _ShutdownHeader extends StatelessWidget {
  const _ShutdownHeader({
    required this.step,
    required this.stepTitle,
    this.activeStepProgress,
  });

  final int step;
  final String stepTitle;
  final double? activeStepProgress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.nightlight_outlined,
                  color: Color(0xFF1E3A5F), size: 20),
              const SizedBox(width: 8),
              Text(
                'Evening Shutdown',
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
            totalSteps: 2,
            activeStepProgress: activeStepProgress,
          ),
          const SizedBox(height: 4),
          Text(
            'Step ${step + 1} of 2',
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
    this.activeStepProgress,
  });

  final int currentStep;
  final int totalSteps;

  /// If set, the active step renders as a partial fill (0.0–1.0) instead of solid.
  final double? activeStepProgress;

  Widget _buildBar(bool completed, bool active, double? progress) {
    if (completed) {
      return Container(
        height: 4,
        decoration: BoxDecoration(
          color: const Color(0xFF1E3A5F),
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    if (active && progress != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: progress,
          minHeight: 4,
          backgroundColor: const Color(0xFFE5E7EB),
          valueColor:
              const AlwaysStoppedAnimation<Color>(Color(0xFF1E3A5F)),
        ),
      );
    }
    return Container(
      height: 4,
      decoration: BoxDecoration(
        color: active ? const Color(0xFF1E3A5F) : const Color(0xFFE5E7EB),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(totalSteps, (i) {
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < totalSteps - 1 ? 4 : 0),
            child: _buildBar(
              i < currentStep,
              i == currentStep,
              i == currentStep ? activeStepProgress : null,
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

class _ShutdownFooter extends StatelessWidget {
  const _ShutdownFooter({
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
              backgroundColor: const Color(0xFF1E3A5F),
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
