/// Step 4 of the Weekly Review wizard: review each Someday/Maybe item one
/// at a time. Routing actions are delegated to the canonical
/// [ProcessToHandlers] action bar; this step only records the routing for
/// the "previously selected" affordance and advances the snapshot cursor.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/database_provider.dart';
import '../../../providers/periodic_review_provider.dart';
import '../../../widgets/process_to_handlers.dart';
import '_review_card.dart';

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

    if (loadError != null) {
      return ReviewLoadError(
        title: "Couldn't load Someday/Maybe",
        message: loadError,
        onRetry: () =>
            ref.read(periodicReviewProvider.notifier).loadSomedaySnapshot(),
      );
    }

    if (!nav.isLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (nav.isEmpty || nav.isComplete) {
      return const ReviewEmptyState(
        icon: Icons.star_border,
        title: 'Someday/Maybe is empty',
        subtitle: 'Tap Next to continue.',
      );
    }

    final index = nav.index;
    final todo = nav.current!;
    final notifier = ref.read(periodicReviewProvider.notifier);

    return ReviewItemCard(
      key: ValueKey(todo.id),
      todo: todo,
      headline: 'Worth pursuing now?',
      // The user can Keep on Someday, promote to Next Actions, or Trash.
      // Waiting For / Someday / Done don't appear because the item is
      // already on Someday and these routes wouldn't change much; mirrors
      // the previous step's surface. Promoting to Next uses the default-on
      // `nextActionDialog` modifier so the item lands on the Next list with
      // a defined action — the ellipsis label signals it.
      process: ProcessToHandlers(
        todo: todo,
        include: const {ProcessAction.keep, ProcessAction.reclarify},
        except: const {
          ProcessAction.waitingFor,
          ProcessAction.someday,
          ProcessAction.done,
        },
        labels: const {
          ProcessAction.keep: 'Keep on Someday',
          ProcessAction.next: 'Next Action…',
        },
        lastAction: routings[index]?.toProcessAction(),
        onAfterRoute: (action) async {
          if (action == ProcessAction.keep) {
            notifier.advanceSomeday();
            return;
          }
          if (action == ProcessAction.nextActionDialog) {
            // A blank save does not route (the widget skips the write), so
            // the row stays on Someday/Maybe — stay on the item rather
            // than recording a routing or advancing the cursor.
            final updated =
                await ref.read(databaseProvider).todoDao.getTodo(todo.id);
            final txt = updated?.nextActionText?.trim() ?? '';
            if (txt.isEmpty) return;
            notifier.recordSomedayRouting(index, RoutingKind.nextAction);
            notifier.advanceSomeday();
            return;
          }
          final kind = action.toRoutingKind();
          if (kind == null) return;
          notifier.recordSomedayRouting(index, kind);
          notifier.advanceSomeday();
        },
      ),
    );
  }
}
