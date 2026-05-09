/// Step 2 of the Weekly Review wizard: review each Waiting For item one at
/// a time. Inline actions write directly to the relevant DAOs and advance
/// the snapshot cursor.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/auth_provider.dart';
import '../../../providers/database_provider.dart';
import '../../../providers/periodic_review_provider.dart';
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
    final db = ref.read(databaseProvider);
    final notifier = ref.read(periodicReviewProvider.notifier);
    final userId = ref.read(currentUserIdProvider);

    Future<void> route(RoutingKind to) async {
      await db.todoDao.applyRouting(
        todo.id,
        from: RoutingKind.waitingFor,
        to: to,
        userId: userId,
      );
      notifier.recordWaitingForRouting(index, to);
      notifier.advanceWaitingFor();
    }

    return ReviewItemCard(
      key: ValueKey(todo.id),
      todo: todo,
      headline: 'Still waiting on this?',
      lastRouting: routings[index],
      personTags: personTags[todo.id] ?? const [],
      actions: [
        ReviewAction(
          label: 'Keep waiting',
          icon: Icons.check_circle_outline,
          color: const Color(0xFF2563EB),
          onTap: () async {
            await db.todoDao.stampLastClarifiedAt(todo.id);
            notifier.advanceWaitingFor();
          },
        ),
        // Promoting out of waitingFor clears the person-tag association
        // (handled inside applyRouting) so the item lands cleanly on the
        // Next Actions list without a phantom delegate.
        ReviewAction(
          label: 'Promote to Next Action',
          icon: Icons.arrow_upward,
          color: const Color(0xFF2563EB),
          routing: RoutingKind.nextAction,
          onTap: () => route(RoutingKind.nextAction),
        ),
        ReviewAction(
          label: 'Mark Done',
          icon: Icons.task_alt_outlined,
          color: const Color(0xFF16A34A),
          routing: RoutingKind.done,
          onTap: () => route(RoutingKind.done),
        ),
        ReviewAction(
          label: 'Send to Maybe',
          icon: Icons.star_border,
          color: const Color(0xFF6B7280),
          routing: RoutingKind.maybe,
          onTap: () => route(RoutingKind.maybe),
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
