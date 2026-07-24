/// Step 4 of the Weekly Review wizard: review each Someday/Maybe item one
/// at a time. The shared per-item-cursor body lives in [ListReviewStep] —
/// this file is a thin composition: provider slice + filters + empty-state
/// copy.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/periodic_review_provider.dart';
import '../../../widgets/process_to_handlers.dart';
import 'list_review_step.dart';

class SomedayMaybeStep extends ConsumerWidget {
  const SomedayMaybeStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav =
        ref.watch(periodicReviewProvider.select((s) => s.somedayNav));
    final loadError = ref.watch(
        periodicReviewProvider.select((s) => s.somedayLoadError));
    final routings = ref.watch(
        periodicReviewProvider.select((s) => s.somedayRoutings));
    final notifier = ref.read(periodicReviewProvider.notifier);

    return ListReviewStep<Todo>(
      nav: nav,
      loadError: loadError,
      routings: routings,
      headline: 'Worth pursuing now?',
      // The user can Keep on Someday, Re-clarify…, promote to Next Actions,
      // mark Done, or Trash. Waiting For / Someday stay excluded because they
      // change little for an item already on Someday. Done stays offered
      // because a deferred Outcome that turns out to be achieved belongs on
      // the Done List: routing to Done stamps the Outcome's Completion and
      // moves it off Someday/Maybe (Completion ⊥ Intent, so intent stays
      // `maybe`). Promoting to Next uses the default-on `nextActionDialog`
      // modifier (left active by omitting it from `processExcept`) so the
      // item lands on the Next list with a defined action — the ellipsis
      // label signals it.
      processInclude: const {ProcessAction.keep, ProcessAction.reclarify},
      processExcept: const {
        ProcessAction.waitingFor,
        ProcessAction.someday,
      },
      processLabels: const {
        ProcessAction.keep: 'Keep on Someday',
        ProcessAction.next: 'Next Action…',
      },
      emptyState: const ListReviewEmpty(
        icon: Icons.star_border,
        title: 'Someday/Maybe is empty',
        subtitle: 'Tap Next to continue.',
      ),
      loadErrorTitle: "Couldn't load Someday/Maybe",
      onRetry: () => notifier.loadSomedaySnapshot(),
      onRecordRouting: notifier.recordSomedayRouting,
      onAdvance: notifier.advanceSomeday,
    );
  }
}
