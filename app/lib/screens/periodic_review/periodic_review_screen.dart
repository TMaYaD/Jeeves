/// Weekly Review wizard — outer container screen (Issue #54).
///
/// Renders a non-swipeable [PageView] with five children: four list-driven
/// review steps (Inbox, Waiting For, Next Actions, Someday/Maybe) and a final
/// summary. There is no separate brain-dump step — capture happens through
/// the inbox throughout the week, not as a wizard ceremony.
///
/// Step transitions go through [PeriodicReviewNotifier.advanceStep] /
/// [goToStep], which in turn drives per-step snapshot loading. The footer's
/// Next button advances the per-step item cursor first; only when the cursor
/// has nothing more to consume does it cross to the next step.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/periodic_review_provider.dart';
import '../../utils/snapshot_nav.dart' show SnapshotNav;
import 'steps/next_actions_step.dart';
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
    'Review Waiting For',
    'Review Next Actions',
    'Review Someday/Maybe',
    'Review Complete',
  ];

  // Five positions in the wizard, but the progress bar reflects only the four
  // user-driven steps before the summary screen.
  static const int _kProgressSteps = 4;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(
      initialPage: ref.read(periodicReviewProvider).currentStep,
    );
    // Pre-load every step's snapshot before the user can interact with the
    // wizard. Loading lazily on step entry let items routed in an earlier
    // step (e.g. inbox → maybe) leak into the matching later step
    // (Someday/Maybe), where the user already decided what to do with them.
    Future.microtask(() async {
      if (!mounted) return;
      final notifier = ref.read(periodicReviewProvider.notifier);
      await notifier.loadAllSnapshots();
      if (!mounted) return;
      final state = ref.read(periodicReviewProvider);
      // goToStep fires the entry hook; auto-skip on empty list-driven steps
      // still applies (the loaders are idempotent so this is a no-op for the
      // snapshots we just loaded).
      await notifier.goToStep(state.currentStep);
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
                  WaitingForStep(),
                  NextActionsStep(),
                  SomedayMaybeStep(),
                  SummaryStep(),
                ],
              ),
            ),
            if (step != PeriodicReviewNotifier.kStepSummary)
              _PeriodicReviewFooter(
                onBack: _backHandler(step, state, notifier),
                onNext: _nextHandler(step, state, notifier),
              ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Back / Next handlers
  // ---------------------------------------------------------------------------
  //
  // List-driven steps (Inbox, Waiting For, Next Actions, Someday/Maybe)
  // iterate one item at a time. The footer's Back / Next buttons drive the
  // per-step cursor first; only when the cursor has no more items to consume
  // does pressing Next cross into the next step (and Back into the prior one).

  VoidCallback? _backHandler(
    int step,
    PeriodicReviewState state,
    PeriodicReviewNotifier notifier,
  ) {
    switch (step) {
      case PeriodicReviewNotifier.kStepInbox:
        if (state.inboxNav.canGoBack) return notifier.previousInbox;
        return null;
      case PeriodicReviewNotifier.kStepWaitingFor:
        if (state.waitingForNav.canGoBack) return notifier.previousWaitingFor;
        return () => notifier.goToStep(step - 1);
      case PeriodicReviewNotifier.kStepNextActions:
        if (state.nextActionsNav.canGoBack) {
          return notifier.previousNextActions;
        }
        return () => notifier.goToStep(step - 1);
      case PeriodicReviewNotifier.kStepSomeMaybe:
        if (state.somedayNav.canGoBack) return notifier.previousSomeday;
        return () => notifier.goToStep(step - 1);
      default:
        return () => notifier.goToStep(step - 1);
    }
  }

  VoidCallback? _nextHandler(
    int step,
    PeriodicReviewState state,
    PeriodicReviewNotifier notifier,
  ) {
    switch (step) {
      case PeriodicReviewNotifier.kStepInbox:
        if (!state.inboxNav.isLoaded) return null;
        return _hasMoreItems(state.inboxNav)
            ? notifier.advanceInbox
            : notifier.advanceStep;
      case PeriodicReviewNotifier.kStepWaitingFor:
        if (!state.waitingForNav.isLoaded) return null;
        return _hasMoreItems(state.waitingForNav)
            ? notifier.advanceWaitingFor
            : notifier.advanceStep;
      case PeriodicReviewNotifier.kStepNextActions:
        if (!state.nextActionsNav.isLoaded) return null;
        return _hasMoreItems(state.nextActionsNav)
            ? notifier.advanceNextActions
            : notifier.advanceStep;
      case PeriodicReviewNotifier.kStepSomeMaybe:
        if (!state.somedayNav.isLoaded) return null;
        return _hasMoreItems(state.somedayNav)
            ? notifier.advanceSomeday
            : notifier.advanceStep;
      default:
        return notifier.advanceStep;
    }
  }

  /// True when the cursor is on an item that still has at least one item
  /// after it. On the last visible item (or already past the end) this
  /// returns false, so Next crosses into the following step instead of
  /// landing on the empty "all clear" placeholder for an extra tap.
  static bool _hasMoreItems<T>(SnapshotNav<T> nav) =>
      nav.isLoaded && nav.index < nav.length - 1;
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
      case PeriodicReviewNotifier.kStepWaitingFor:
        final nav = state.waitingForNav;
        if (!nav.isLoaded || nav.isEmpty) return 0.0;
        return (nav.index / nav.length).clamp(0.0, 1.0);
      case PeriodicReviewNotifier.kStepNextActions:
        final nav = state.nextActionsNav;
        if (!nav.isLoaded || nav.isEmpty) return 0.0;
        return (nav.index / nav.length).clamp(0.0, 1.0);
      case PeriodicReviewNotifier.kStepSomeMaybe:
        final nav = state.somedayNav;
        if (!nav.isLoaded || nav.isEmpty) return 0.0;
        return (nav.index / nav.length).clamp(0.0, 1.0);
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
            totalSteps: _PeriodicReviewScreenState._kProgressSteps,
            activeFraction: _activeFraction(),
            accent: _accent,
          ),
          const SizedBox(height: 4),
          Text(
            _subtitle(),
            style: TextStyle(fontSize: 12, color: Colors.grey[400]),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// Header subtitle. Step N of M (with a per-step item count when the step
  /// is list-driven), or "Review complete" on the final summary.
  String _subtitle() {
    if (step == PeriodicReviewNotifier.kStepSummary) return 'Review complete';
    final stepLabel =
        'Step ${step + 1} of ${_PeriodicReviewScreenState._kProgressSteps}';
    switch (step) {
      case PeriodicReviewNotifier.kStepInbox:
        return _navSubtitle(stepLabel, state.inboxNav, 'processed');
      case PeriodicReviewNotifier.kStepWaitingFor:
        return _navSubtitle(stepLabel, state.waitingForNav, 'reviewed');
      case PeriodicReviewNotifier.kStepNextActions:
        return _navSubtitle(stepLabel, state.nextActionsNav, 'reviewed');
      case PeriodicReviewNotifier.kStepSomeMaybe:
        return _navSubtitle(stepLabel, state.somedayNav, 'reviewed');
      default:
        return stepLabel;
    }
  }

  String _navSubtitle<T>(String stepLabel, SnapshotNav<T> nav, String verb) {
    if (!nav.isLoaded) return '$stepLabel · Loading…';
    if (nav.isEmpty) return '$stepLabel · Nothing to review';
    final consumed = nav.index.clamp(0, nav.length);
    return '$stepLabel · $consumed / ${nav.length} $verb';
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
    required this.onBack,
    required this.onNext,
  });

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
            key: const Key('periodic_review_next'),
            onPressed: onNext,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF059669),
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
