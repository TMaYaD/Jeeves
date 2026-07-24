/// Step 3 of the Weekly Review wizard: review each active next action one at
/// a time. Person-tagged items are excluded at the DAO level
/// ([TodoDao.getNextExcludingPersonTagged]) because they are surfaced
/// by the prior Waiting For step — the wizard's disjointness invariant
/// guarantees each task shows up in at most one step.
///
/// The shared per-item-cursor body lives in [ListReviewStep] — this file is
/// a thin composition: provider slice + filters + empty-state copy.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/periodic_review_provider.dart';
import '../../../widgets/process_to_handlers.dart';
import 'list_review_step.dart';

class NextStep extends ConsumerWidget {
  const NextStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav =
        ref.watch(periodicReviewProvider.select((s) => s.nextNav));
    final loadError = ref.watch(
        periodicReviewProvider.select((s) => s.nextLoadError));
    final routings = ref.watch(
        periodicReviewProvider.select((s) => s.nextRoutings));
    final actionTexts = ref.watch(
        periodicReviewProvider.select((s) => s.actionTexts));
    final notifier = ref.read(periodicReviewProvider.notifier);

    return ListReviewStep<Todo>(
      nav: nav,
      loadError: loadError,
      routings: routings,
      headline: 'Is this still your next move?',
      // Defaults minus Next: the item is already on the Next list, so
      // re-confirming as Next is what Keep is for. With no Next button the
      // default-on `nextActionDialog` modifier is inert; except it too so
      // the resolved action set reads cleanly.
      processInclude: const {ProcessAction.keep, ProcessAction.reclarify},
      processExcept: const {
        ProcessAction.next,
        ProcessAction.nextActionDialog,
      },
      processLabels: const {},
      emptyState: const ListReviewEmpty(
        icon: Icons.task_alt_outlined,
        title: 'No next actions to review',
        subtitle: 'Tap Next to continue.',
      ),
      loadErrorTitle: "Couldn't load Next Actions",
      // Surface the current Action's text so the reviewer sees the concrete
      // commitment they made, not just the Outcome title.
      subtextFor: (todo) => actionTexts[todo.id],
      currentActionTextFor: (todo) => actionTexts[todo.id],
      onRetry: () => notifier.loadNextSnapshot(),
      onRecordRouting: notifier.recordNextRouting,
      onAdvance: notifier.advanceNext,
    );
  }
}
