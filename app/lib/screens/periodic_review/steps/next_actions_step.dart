/// Step 3 of the Weekly Review wizard: review each active next action one at
/// a time. Person-tagged items are excluded at the DAO level
/// ([TodoDao.getNextActionsExcludingPersonTagged]) because they are surfaced
/// by the prior Waiting For step — the wizard's disjointness invariant
/// guarantees each task shows up in at most one step.
///
/// Routing actions are delegated to the canonical [ProcessToHandlers]
/// action bar; this step only records the routing for the
/// "previously selected" affordance and advances the snapshot cursor.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/periodic_review_provider.dart';
import '../../../widgets/process_to_handlers.dart';
import '_review_card.dart';

class NextActionsStep extends ConsumerWidget {
  const NextActionsStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav =
        ref.watch(periodicReviewProvider.select((s) => s.nextActionsNav));
    final loadError = ref.watch(
        periodicReviewProvider.select((s) => s.nextActionsLoadError));
    final routings = ref.watch(
        periodicReviewProvider.select((s) => s.nextActionsRoutings));

    if (loadError != null) {
      return ReviewLoadError(
        title: "Couldn't load Next Actions",
        message: loadError,
        onRetry: () => ref
            .read(periodicReviewProvider.notifier)
            .loadNextActionsSnapshot(),
      );
    }

    if (!nav.isLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (nav.isEmpty || nav.isComplete) {
      return const ReviewEmptyState(
        icon: Icons.task_alt_outlined,
        title: 'No next actions to review',
        subtitle: 'Tap Next to continue.',
      );
    }

    final index = nav.index;
    final todo = nav.current!;
    final notifier = ref.read(periodicReviewProvider.notifier);

    return ReviewItemCard(
      key: ValueKey(todo.id),
      todo: todo,
      headline: 'Is this still your next move?',
      // Surface the persisted next-action text so the reviewer sees the
      // concrete commitment they made, not just the task title.
      subtext: todo.nextActionText,
      // Defaults minus Next: the item is already on the Next list, so
      // re-confirming as Next is what Keep is for. With no Next button the
      // default-on `nextActionDialog` modifier is inert; except it too so
      // the resolved action set reads cleanly.
      process: ProcessToHandlers(
        todo: todo,
        include: const {ProcessAction.keep},
        except: const {
          ProcessAction.next,
          ProcessAction.nextActionDialog,
        },
        lastAction: routings[index]?.toProcessAction(),
        onAfterRoute: (action) async {
          if (action == ProcessAction.keep) {
            notifier.advanceNextActions();
            return;
          }
          final kind = action.toRoutingKind();
          // `keep` is the only action whose toRoutingKind() returns null, and
          // it is handled above. The guard below keeps the wizard advancing
          // even if that invariant is ever violated.
          assert(kind != null,
              'ProcessAction.keep should already be handled before this point');
          if (kind != null) {
            notifier.recordNextActionsRouting(index, kind);
          }
          notifier.advanceNextActions();
        },
      ),
    );
  }
}
