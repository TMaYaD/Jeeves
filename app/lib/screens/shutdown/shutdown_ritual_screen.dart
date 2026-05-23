/// Evening shutdown ritual — outer container screen (Issue #83).
///
/// Steps 0–1 are composed against the shared [Wizard] widget; Step 2
/// (Close Day) is rendered standalone — full-screen moon-rise animation
/// that commits dispositions, fades out, and exits the app. The wizard
/// chrome is owned by [Wizard] per issue #322; each [WizardStep] owns its
/// own footer widget through [WizardStep.footer].
///
/// Step 1 → Step 2 advances automatically once the user resolves the last
/// unfinished task; the screen latches onto [CloseDayStep] once reached so
/// `closeDay()` resetting `currentStep` mid fade-out cannot expose the
/// Review step underneath.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/ritual.dart';
import '../../providers/ceremony_in_progress_provider.dart';
import '../../providers/evening_shutdown_provider.dart';
import '../../widgets/ceremony/wizard.dart';
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
  late final CeremonyInProgressNotifier _ceremonyNotifier;
  int? _resolveInitialTotal;
  bool _showCloseDay = false;

  static const _ceremonyId = 'shutdown';
  static const _accent = Color(0xFF1E3A5F);
  static const _stepTitles = ['Review Your Day', 'Resolve Unfinished'];

  @override
  void initState() {
    super.initState();
    // Capture the notifier now so dispose() can call exit() without
    // touching `ref` after the widget has been unmounted.
    _ceremonyNotifier = ref.read(ceremonyInProgressProvider.notifier);
    // ADR-0009: hold the Nudge while this Ceremony performance is in progress.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ceremonyNotifier.enter(RitualId.eveningShutdown);
    });
  }

  @override
  void dispose() {
    _ceremonyNotifier.exit(RitualId.eveningShutdown);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shutdownState = ref.watch(eveningShutdownProvider);
    final notifier = ref.read(eveningShutdownProvider.notifier);
    final step = shutdownState.currentStep;

    // Lock onto CloseDayStep once reached. closeDay() resets currentStep to 0
    // mid fade-out; without this latch the parent would rebuild and unmount
    // CloseDayStep, exposing the Review step underneath.
    if (step == 2 && !_showCloseDay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_showCloseDay) {
          setState(() => _showCloseDay = true);
        }
      });
    }
    if (_showCloseDay || step == 2) return const CloseDayStep();

    // Latch the initial unfinished count once so the resolve progress fills
    // correctly. Auto-advance off step 1 whenever the list is empty — covers
    // both "resolved the last task" and "nothing to resolve to begin with".
    ref.listen<AsyncValue<List<Todo>>>(unfinishedSelectedTodayProvider,
        (prev, next) {
      final tasks = next.asData?.value;
      if (tasks == null) return;
      if (tasks.isNotEmpty && _resolveInitialTotal == null) {
        setState(() => _resolveInitialTotal = tasks.length);
      }
      if (tasks.isEmpty &&
          ref.read(eveningShutdownProvider).currentStep == 1) {
        notifier.advanceStep();
      }
    });

    // If we render step 1 with no unfinished tasks (e.g. user landed here
    // directly with an empty list, so the listener above never observed a
    // transition), skip past it on the next frame.
    if (step == 1 &&
        (ref.watch(unfinishedSelectedTodayProvider).asData?.value.isEmpty ??
            false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            ref.read(eveningShutdownProvider).currentStep == 1) {
          notifier.advanceStep();
        }
      });
    }

    double resolveProgress = 0.0;
    if (step == 1 && _resolveInitialTotal != null && _resolveInitialTotal! > 0) {
      final current =
          ref.watch(unfinishedSelectedTodayProvider).asData?.value.length;
      if (current != null) {
        final resolved = _resolveInitialTotal! - current;
        resolveProgress = (resolved / _resolveInitialTotal!).clamp(0.0, 1.0);
      }
    }

    final steps = <WizardStep>[
      WizardStep(
        title: _stepTitles[0],
        body: const CompletedReviewStep(),
        subtitle: 'Step 1 of 2',
        footer: WizardFooter(
          ceremonyId: _ceremonyId,
          accentColor: _accent,
          onBack: null,
          onNext: notifier.advanceStep,
        ),
      ),
      WizardStep(
        title: _stepTitles[1],
        body: const UnfinishedTasksStep(),
        activeFraction: resolveProgress,
        subtitle: 'Step 2 of 2',
        // Dispositions on each task drive advancement here; the footer
        // offers no forward affordance, only Back. Back retreats the
        // unfinished snapshot cursor before crossing to Step 0.
        footer: BackOnlyFooter(
          ceremonyId: _ceremonyId,
          onBack: shutdownState.unfinishedNav.canGoBack
              ? notifier.previousUnfinishedTask
              : () => notifier.goToStep(0),
        ),
      ),
    ];

    return Wizard(
      ceremonyLabel: 'Evening Shutdown',
      ceremonyIcon: Icons.nightlight_outlined,
      accentColor: _accent,
      currentStep: step,
      steps: steps,
    );
  }
}
