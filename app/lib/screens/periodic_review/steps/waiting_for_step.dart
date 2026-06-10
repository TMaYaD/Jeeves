/// Step 2 of the Weekly Review wizard: review each Waiting For item one at
/// a time. Routing actions are delegated to the canonical
/// [ProcessToHandlers] action bar; this step only records the routing for
/// the "previously selected" affordance and advances the snapshot cursor.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/database_provider.dart';
import '../../../providers/periodic_review_provider.dart';
import '../../../widgets/process_to_handlers.dart';
import '_review_card.dart';

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
    final personTags = ref.watch(
        periodicReviewProvider.select((s) => s.waitingForPersonTags));

    if (loadError != null) {
      return ReviewLoadError(
        title: "Couldn't load Waiting For",
        message: loadError,
        onRetry: () => ref
            .read(periodicReviewProvider.notifier)
            .loadWaitingForSnapshot(),
      );
    }

    if (!nav.isLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (nav.isEmpty || nav.isComplete) {
      return const ReviewEmptyState(
        icon: Icons.hourglass_empty,
        title: 'No waiting-for items',
        subtitle: 'Tap Next to continue.',
      );
    }

    final index = nav.index;
    final todo = nav.current!;
    final notifier = ref.read(periodicReviewProvider.notifier);
    return ReviewItemCard(
      key: ValueKey(todo.id),
      todo: todo,
      headline: 'Still waiting on this?',
      personTags: personTags[todo.id] ?? const [],
      // Hide Waiting For — re-confirming is the Keep button.
      // Keep gets a callsite-specific label so the user knows what state is
      // being preserved. Promoting to Next uses the default-on
      // `nextActionDialog` modifier so the freshly-promoted task lands on
      // the Next list with a defined action — the ellipsis label signals it.
      process: ProcessToHandlers(
        todo: todo,
        include: const {ProcessAction.keep, ProcessAction.reclarify},
        except: const {ProcessAction.waitingFor},
        labels: const {
          ProcessAction.keep: 'Keep waiting',
          ProcessAction.next: 'Next Action…',
        },
        lastAction: routings[index]?.toProcessAction(),
        onAfterRoute: (action) async {
          if (action == ProcessAction.keep) {
            notifier.advanceWaitingFor();
            return;
          }
          if (action == ProcessAction.nextActionDialog) {
            // A blank save does not route (the widget skips the write), so
            // the row still has no next action — stay on the item rather
            // than recording a routing or advancing the cursor.
            final updated =
                await ref.read(databaseProvider).todoDao.getTodo(todo.id);
            final txt = updated?.nextActionText?.trim() ?? '';
            if (txt.isEmpty) return;
            notifier.recordWaitingForRouting(index, RoutingKind.nextAction);
            notifier.advanceWaitingFor();
            return;
          }
          final kind = action.toRoutingKind();
          if (kind == null) return;
          notifier.recordWaitingForRouting(index, kind);
          notifier.advanceWaitingFor();
        },
      ),
    );
  }
}
