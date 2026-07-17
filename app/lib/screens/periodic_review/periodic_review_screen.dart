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

import '../../models/ritual.dart';
import '../../providers/ceremony_in_progress_provider.dart';
import '../../providers/periodic_review_provider.dart';
import '../../utils/snapshot_nav.dart' show SnapshotNav;
import '../../widgets/ceremony/ceremony_pop_scope.dart';
import '../../widgets/ceremony/wizard.dart';
import 'steps/next_step.dart';
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
  late final CeremonyInProgressNotifier _ceremonyNotifier;

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
    // Capture the notifier now so dispose() can call exit() without
    // touching `ref` after the widget has been unmounted.
    _ceremonyNotifier = ref.read(ceremonyInProgressProvider.notifier);
    // ADR-0009: hold the Nudge while this Ceremony performance is in progress.
    // Defer `enter()` to the post-frame callback — Riverpod 3.x forbids
    // notifier mutation during the build phase, which initState is part of.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ceremonyNotifier.enter(RitualId.weeklyReview);
    });
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
  void dispose() {
    // Defer `exit()` to a microtask — unmount runs while the widget tree is
    // locked, and Riverpod forbids notifier mutation during that phase (the
    // mirror of the deferred `enter()` above). The notifier guards against
    // the container being torn down before the microtask fires.
    final notifier = _ceremonyNotifier;
    Future.microtask(() => notifier.exit(RitualId.weeklyReview));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(periodicReviewProvider);
    final notifier = ref.read(periodicReviewProvider.notifier);
    final step = state.currentStep;

    // Completion screen lives outside the wizard — it is a post-ritual
    // confirmation, not a step the user walks through.
    if (step >= _kSummaryStepIndex) {
      return const CeremonyPopScope(
        onBack: null,
        child: Scaffold(
          backgroundColor: Colors.white,
          body: SafeArea(child: SummaryStep()),
        ),
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
        body: const NextStep(),
        nav: state.nextNav,
        verb: 'reviewed',
        stepIndex: 2,
        currentStep: step,
        skip: notifier.advanceNext,
        previous: notifier.previousNext,
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

    return CeremonyPopScope(
      // System back mirrors the active step's footer Back; when that is
      // unavailable (step 0, first item) it exits to the execution home.
      onBack: _backForCurrentStep(state, notifier),
      child: Wizard(
        ceremonyLabel: 'Weekly Review',
        ceremonyIcon: Icons.refresh,
        accentColor: _accent,
        currentStep: step,
        steps: steps,
        progressSegmentCount: _kProgressSegmentCount,
      ),
    );
  }

  /// The Back callback for the active step — the same callback its footer
  /// renders (see [_listStep]). Null when Back is unavailable (step 0,
  /// first item), which [CeremonyPopScope] translates into a ceremony exit.
  VoidCallback? _backForCurrentStep(
    PeriodicReviewState state,
    PeriodicReviewNotifier notifier,
  ) {
    final step = state.currentStep;
    final nav = switch (step) {
      0 => state.inboxNav,
      1 => state.waitingForNav,
      2 => state.nextNav,
      _ => state.somedayNav,
    };
    final VoidCallback previous = switch (step) {
      0 => notifier.previousInbox,
      1 => notifier.previousWaitingFor,
      2 => notifier.previousNext,
      _ => notifier.previousSomeday,
    };
    return _backFor(
      nav: nav,
      previous: previous,
      stepIndex: step,
      currentStep: step,
      notifier: notifier,
    );
  }

  /// Back routing shared by the footers and the system-back handler:
  /// retreat the per-item cursor while past item 0; from item 0 of any
  /// non-first step, cross to the previous step. Step 0's first item has
  /// no Back.
  VoidCallback? _backFor({
    required SnapshotNav<dynamic> nav,
    required VoidCallback previous,
    required int stepIndex,
    required int currentStep,
    required PeriodicReviewNotifier notifier,
  }) {
    if (nav.canGoBack) return previous;
    if (stepIndex == 0) return null;
    return () => unawaited(notifier.goToStep(currentStep - 1));
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
        onBack: _backFor(
          nav: nav,
          previous: previous,
          stepIndex: stepIndex,
          currentStep: currentStep,
          notifier: notifier,
        ),
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
