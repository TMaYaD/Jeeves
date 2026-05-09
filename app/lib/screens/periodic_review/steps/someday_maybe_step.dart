/// Step 4 of the Weekly Review wizard: review each Someday/Maybe item one
/// at a time. Reflection step — the user manually presses Next; empty list
/// does not auto-skip.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/todo.dart' as todo_model show Intent;
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

    final todo = nav.current!;
    final db = ref.read(databaseProvider);
    final notifier = ref.read(periodicReviewProvider.notifier);

    return ReviewItemCard(
      key: ValueKey(todo.id),
      todo: todo,
      headline: 'Worth pursuing now?',
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
          onTap: () async {
            await db.todoDao.setIntent(todo.id, todo_model.Intent.next);
            notifier.advanceSomeday();
          },
        ),
        ReviewAction(
          label: 'Discard',
          icon: Icons.delete_outline,
          color: const Color(0xFFDC2626),
          onTap: () async {
            await db.todoDao.setIntent(todo.id, todo_model.Intent.trash);
            notifier.advanceSomeday();
          },
        ),
      ],
    );
  }
}
