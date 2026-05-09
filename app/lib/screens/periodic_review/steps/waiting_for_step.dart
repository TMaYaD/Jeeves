/// Step 2 of the Weekly Review wizard: review each Waiting For item one at
/// a time. Inline actions write directly to the relevant DAOs and advance
/// the snapshot cursor.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/todo.dart' show RoutingKind;
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

    final todo = nav.current!;
    final db = ref.read(databaseProvider);
    final notifier = ref.read(periodicReviewProvider.notifier);
    final userId = ref.read(currentUserIdProvider);

    return ReviewItemCard(
      key: ValueKey(todo.id),
      todo: todo,
      headline: 'Still waiting on this?',
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
        // Route Done/Maybe/Discard through applyRouting so person-tag
        // associations attached to the waitingFor item are cleared as a
        // side-effect of leaving the kind — see TodoDao.applyRouting.
        ReviewAction(
          label: 'Mark Done',
          icon: Icons.task_alt_outlined,
          color: const Color(0xFF16A34A),
          onTap: () async {
            await db.todoDao.applyRouting(
              todo.id,
              from: RoutingKind.waitingFor,
              to: RoutingKind.done,
              userId: userId,
            );
            notifier.advanceWaitingFor();
          },
        ),
        ReviewAction(
          label: 'Send to Maybe',
          icon: Icons.star_border,
          color: const Color(0xFF6B7280),
          onTap: () async {
            await db.todoDao.applyRouting(
              todo.id,
              from: RoutingKind.waitingFor,
              to: RoutingKind.maybe,
              userId: userId,
            );
            notifier.advanceWaitingFor();
          },
        ),
        ReviewAction(
          label: 'Discard',
          icon: Icons.delete_outline,
          color: const Color(0xFFDC2626),
          onTap: () async {
            await db.todoDao.applyRouting(
              todo.id,
              from: RoutingKind.waitingFor,
              to: RoutingKind.trash,
              userId: userId,
            );
            notifier.advanceWaitingFor();
          },
        ),
      ],
    );
  }
}
