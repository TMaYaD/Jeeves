/// Step 2 of the Weekly Review wizard: review each Waiting For item one at
/// a time. The shared per-item-cursor body lives in [ListReviewStep] — this
/// file is a thin composition: provider slice + filters + empty-state copy.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/periodic_review_provider.dart';
import '../../../widgets/process_to_handlers.dart';
import 'list_review_step.dart';

class WaitingForStep extends ConsumerWidget {
  const WaitingForStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav =
        ref.watch(periodicReviewProvider.select((s) => s.waitingForNav));
    final loadError = ref.watch(
        periodicReviewProvider.select((s) => s.waitingForLoadError));
    final routings = ref.watch(
        periodicReviewProvider.select((s) => s.waitingForRoutings));
    final actionTexts = ref.watch(
        periodicReviewProvider.select((s) => s.actionTexts));
    final personTags = ref.watch(
        periodicReviewProvider.select((s) => s.waitingForPersonTags));
    final notifier = ref.read(periodicReviewProvider.notifier);

    return ListReviewStep<Todo>(
      nav: nav,
      loadError: loadError,
      routings: routings,
      // Prefills the "Update next action" dialog from the Outcome's current
      // Action (ADR-0001 story 3).
      currentActionTextFor: (todo) => actionTexts[todo.id],
      headline: 'Still waiting on this?',
      // Hide Waiting For — re-confirming is the Keep button. Keep gets a
      // callsite-specific label so the user knows what state is being
      // preserved. Promoting to Next uses the default-on `nextActionDialog`
      // modifier (left active by omitting it from `processExcept`) so the
      // freshly-promoted task lands on the Next list with a defined
      // action — the ellipsis label signals it.
      processInclude: const {ProcessAction.keep, ProcessAction.reclarify},
      processExcept: const {ProcessAction.waitingFor},
      processLabels: const {
        ProcessAction.keep: 'Keep waiting',
        ProcessAction.next: 'Next Action…',
      },
      emptyState: const ListReviewEmpty(
        icon: Icons.hourglass_empty,
        title: 'No waiting-for items',
        subtitle: 'Tap Next to continue.',
      ),
      loadErrorTitle: "Couldn't load Waiting For",
      personTagsFor: (todo) => personTags[todo.id] ?? const [],
      onRetry: () => notifier.loadWaitingForSnapshot(),
      onRecordRouting: notifier.recordWaitingForRouting,
      onAdvance: notifier.advanceWaitingFor,
    );
  }
}
