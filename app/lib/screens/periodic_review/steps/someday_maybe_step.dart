/// Step 4 of the Weekly Review wizard: review each Someday/Maybe item one
/// at a time. Routing decisions go through [TodoDao.applyRouting]; the
/// in-session [PeriodicReviewState.somedayRoutings] map drives the
/// "previously selected" highlight on revisit.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/database_provider.dart';
import '../../../providers/periodic_review_provider.dart';
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
    final db = ref.read(databaseProvider);
    final notifier = ref.read(periodicReviewProvider.notifier);

    Future<void> route(RoutingKind to) async {
      await db.todoDao.applyRouting(
        todo.id,
        from: RoutingKind.maybe,
        to: to,
      );
      notifier.recordSomedayRouting(index, to);
      notifier.advanceSomeday();
    }

    return ReviewItemCard(
      key: ValueKey(todo.id),
      todo: todo,
      headline: 'Worth pursuing now?',
      lastRouting: routings[index],
      actions: [
        ReviewAction(
          label: 'Keep on Someday',
          icon: Icons.check_circle_outline,
          color: const Color(0xFF2563EB),
          onTap: () async {
            await db.todoDao.stampLastClarifiedAt(todo.id);
            notifier.advanceSomeday();
          },
        ),
        ReviewAction(
          label: 'Promote to Next Actions',
          icon: Icons.upgrade,
          color: const Color(0xFF059669),
          routing: RoutingKind.nextAction,
          onTap: () => route(RoutingKind.nextAction),
        ),
        ReviewAction(
          label: 'Discard',
          icon: Icons.delete_outline,
          color: const Color(0xFFDC2626),
          routing: RoutingKind.trash,
          onTap: () => route(RoutingKind.trash),
        ),
      ],
    );
  }
}
