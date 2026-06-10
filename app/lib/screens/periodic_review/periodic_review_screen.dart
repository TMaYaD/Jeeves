/// Weekly Review wizard — outer container screen (Issue #54).
///
/// Composes four list-driven [WizardStep]s against the shared [Wizard]
/// widget (Inbox, Waiting For, Next Actions, Someday/Maybe). The final
/// "Review Complete" summary screen is rendered outside the wizard — it
/// is a post-ritual confirmation, not a step the user walks through.
/// Wizard chrome — header, segmented progress — is owned by [Wizard] per
/// issue #322; each step owns its own footer widget through
/// [WizardStep.footer].
///
/// There is no separate brain-dump step — capture happens through the
/// inbox throughout the week, not as a wizard ceremony.
///
/// The footer follows DPR's contract: Skip (secondary) while the
/// step's per-item cursor still points at a real item (`!nav.isComplete`),
/// swapping to Next step (primary, in the Weekly Review accent) only once
/// the cursor has advanced past the last item and the step body shows its
/// completion placeholder. "Skip" is anchored in the current item
/// ("dismiss this one"); "Next step" appears only after all items are
/// processed.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/periodic_review_provider.dart';
import '../../utils/snapshot_nav.dart' show SnapshotNav;
import '../../widgets/ceremony/wizard.dart';
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
  static const _ceremonyId = 'periodic_review';
  static const _accent = Color(0xFF059669);
  static const _stepTitles = [
    'Process Inbox',
    'Review Waiting For',
    'Review Next Actions',
    'Review Someday/Maybe',
  ];

  /// Four user-driven steps in the wizard. The "Review Complete" summary
  /// is rendered outside the wizard once `currentStep == _kSummaryStepIndex`.
  static const int _kProgressSegmentCount = 4;
  static const int _kSummaryStepIndex = 4;

  @override
  void initState() {
    super.initState();
    // Pre-load every step's snapshot before the user can interact with
    // the wizard. Loading lazily on step entry let items routed in an
    // earlier step (e.g. inbox → maybe) leak into the matching later
    // step (Someday/Maybe), where the user already decided what to do
    // with them.
    Future.microtask(() async {
      if (!mounted) return;
      final notifier = ref.read(periodicReviewProvider.notifier);
      await notifier.loadAllSnapshots();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(periodicReviewProvider);
    final notifier = ref.read(periodicReviewProvider.notifier);
    final step = state.currentStep;

    // Completion screen lives outside the wizard — it is a post-ritual
    // confirmation, not a step the user walks through.
    if (step >= _kSummaryStepIndex) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(child: SummaryStep()),
      );
    }

    final steps = <WizardStep>[
      _listStep(
        title: _stepTitles[0],
        body: const ZeroInboxStep(),
        nav: state.inboxNav,
        verb: 'processed',
        stepIndex: 0,
        currentStep: step,
        skip: notifier.advanceInbox,
        previous: notifier.previousInbox,
        notifier: notifier,
      ),
      _listStep(
        title: _stepTitles[1],
        body: const WaitingForStep(),
        nav: state.waitingForNav,
        verb: 'reviewed',
        stepIndex: 1,
        currentStep: step,
        skip: notifier.advanceWaitingFor,
        previous: notifier.previousWaitingFor,
        notifier: notifier,
      ),
      _listStep(
        title: _stepTitles[2],
        body: const NextActionsStep(),
        nav: state.nextActionsNav,
        verb: 'reviewed',
        stepIndex: 2,
        currentStep: step,
        skip: notifier.advanceNextActions,
        previous: notifier.previousNextActions,
        notifier: notifier,
      ),
      _listStep(
        title: _stepTitles[3],
        body: const SomedayMaybeStep(),
        nav: state.somedayNav,
        verb: 'reviewed',
        stepIndex: 3,
        currentStep: step,
        skip: notifier.advanceSomeday,
        previous: notifier.previousSomeday,
        notifier: notifier,
      ),
    ];

    return Wizard(
      ceremonyLabel: 'Weekly Review',
      ceremonyIcon: Icons.refresh,
      accentColor: _accent,
      currentStep: step,
      steps: steps,
      progressSegmentCount: _kProgressSegmentCount,
    );
  }

  /// Builds a list-driven step (Inbox / Waiting For / Next Actions /
  /// Someday-Maybe). Skip advances the per-item cursor while items
  /// remain; Next step crosses once the cursor is on the last item.
  ///
  /// Back retreats the cursor while past item 0; from item 0 of any
  /// non-first list-driven step it falls through to `goToStep(currentStep - 1)`.
  /// Inbox's first item leaves Back null (the footer hides it).
  WizardStep _listStep({
    required String title,
    required Widget body,
    required SnapshotNav<dynamic> nav,
    required String verb,
    required int stepIndex,
    required int currentStep,
    required VoidCallback skip,
    required VoidCallback previous,
    required PeriodicReviewNotifier notifier,
  }) {
    final hasMore = _hasMoreItems(nav);
    final activeFraction = nav.isLoaded && !nav.isEmpty
        ? (nav.index / nav.length).clamp(0.0, 1.0)
        : 0.0;

    return WizardStep(
      title: title,
      body: body,
      activeFraction: activeFraction,
      subtitle: _subtitle(nav, stepIndex, verb),
      footer: ListItemFooter(
        ceremonyId: _ceremonyId,
        accentColor: _accent,
        onBack: nav.canGoBack
            ? previous
            : (stepIndex == 0
                ? null
                : () => unawaited(notifier.goToStep(currentStep - 1))),
        onSkip: skip,
        // Next step is disabled while the snapshot is still loading;
        // notifier methods are Future-returning so the discard is
        // explicit.
        onNext: nav.isLoaded
            ? () => unawaited(notifier.advanceStep())
            : null,
        hasMoreItems: hasMore,
      ),
    );
  }

  /// Header subtitle for a list-driven step: "Step N of M · X / Y verb",
  /// or a loading / empty placeholder.
  String _subtitle(SnapshotNav<dynamic> nav, int stepIndex, String verb) {
    final stepLabel = 'Step ${stepIndex + 1} of $_kProgressSegmentCount';
    if (!nav.isLoaded) return '$stepLabel · Loading…';
    if (nav.isEmpty) return '$stepLabel · Nothing to review';
    final consumed = nav.index.clamp(0, nav.length);
    return '$stepLabel · $consumed / ${nav.length} $verb';
  }

  /// True when the cursor is still pointing at a real item — i.e. the
  /// snapshot is loaded and the cursor has not yet reached the end.
  /// Skip is shown while this is true; Next step appears only once the
  /// cursor has advanced past the last item ([nav.isComplete]) and the
  /// step body shows its completion placeholder.
  static bool _hasMoreItems<T>(SnapshotNav<T> nav) =>
      nav.isLoaded && !nav.isComplete;
}
