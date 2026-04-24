/// Evening shutdown ritual — outer container screen (Issue #83).
///
/// Renders a full-screen, drawer-free scaffold with:
/// - A 3-segment progress bar (Review → Resolve → Close Day).
/// - A non-swipeable [PageView] that displays each step.
/// - Back / Next navigation buttons at the bottom (hidden on the last step).
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/evening_shutdown_provider.dart';
import 'steps/completed_review_step.dart';
import 'steps/shutdown_summary_step.dart';
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
  bool _showingGoodNight = false;

  static const _stepTitles = [
    'Review Your Day',
    'Resolve Unfinished',
    'Close Day',
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(
      initialPage: ref.read(eveningShutdownProvider).currentStep,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _triggerGoodNight() => setState(() => _showingGoodNight = true);

  @override
  Widget build(BuildContext context) {
    if (_showingGoodNight) return const _GoodNightScreen();

    final shutdownState = ref.watch(eveningShutdownProvider);
    final notifier = ref.read(eveningShutdownProvider.notifier);
    final step = shutdownState.currentStep;

    ref.listen<EveningShutdownState>(eveningShutdownProvider, (prev, next) {
      if (prev?.currentStep != next.currentStep && _pageController.hasClients) {
        _pageController.animateToPage(
          next.currentStep,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    });

    // Latch the initial unfinished count once so the resolve progress fills correctly.
    ref.listen<AsyncValue<List<Todo>>>(unfinishedSelectedTodayProvider,
        (_, next) {
      final tasks = next.asData?.value;
      if (tasks != null && tasks.isNotEmpty && _resolveInitialTotal == null) {
        setState(() => _resolveInitialTotal = tasks.length);
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
                children: [
                  const CompletedReviewStep(),
                  const UnfinishedTasksStep(),
                  ShutdownSummaryStep(onCloseDay: _triggerGoodNight),
                ],
              ),
            ),
            if (step < 2)
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
      // Step 1: all unfinished tasks must be resolved.
      1 => ref.watch(unfinishedSelectedTodayProvider).asData?.value.isEmpty ??
          false,
      // Step 2: Close Day is the terminal action — no Next button.
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
            totalSteps: 3,
            activeStepProgress: activeStepProgress,
          ),
          const SizedBox(height: 4),
          Text(
            'Step ${step + 1} of 3',
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

// ---------------------------------------------------------------------------
// Good-night screen: moon rise animation + Jeeves phrase + app close
// ---------------------------------------------------------------------------

class _GoodNightScreen extends StatefulWidget {
  const _GoodNightScreen();

  @override
  State<_GoodNightScreen> createState() => _GoodNightScreenState();
}

class _GoodNightScreenState extends State<_GoodNightScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _slideY;
  late final Animation<double> _fade;

  static const _phrases = [
    'Another day superbly managed, sir. Pleasant dreams.',
    'Capital effort today, sir. I shall stand down for the evening.',
    'The books are balanced and all tasks accounted for, sir. Good night.',
    'Rest well, sir. Tomorrow\'s battles shall wait until morning.',
    'Everything is in order, sir. I shall dim the lights.',
    'A productive day by any measure, sir. Sleep well.',
  ];

  late final String _phrase;

  @override
  void initState() {
    super.initState();
    _phrase = _phrases[Random().nextInt(_phrases.length)];
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _slideY = Tween<double>(begin: 64, end: 0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _fade = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
    );
    _controller.forward();
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) SystemNavigator.pop();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      body: SafeArea(
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return Opacity(
                opacity: _fade.value,
                child: Transform.translate(
                  offset: Offset(0, _slideY.value),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.nightlight_round,
                          size: 88,
                          color: Color(0xFFE2C97E),
                        ),
                        const SizedBox(height: 36),
                        Text(
                          _phrase,
                          style: const TextStyle(
                            fontSize: 20,
                            color: Colors.white,
                            fontWeight: FontWeight.w300,
                            fontStyle: FontStyle.italic,
                            height: 1.6,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
