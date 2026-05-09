/// Step 3 of the Weekly Review wizard: review each project-tagged next
/// action. Reflection step — the user manually presses Next; empty list does
/// not auto-skip.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/todo.dart' show RoutingKind;
import '../../../providers/database_provider.dart';
import '../../../providers/periodic_review_provider.dart';
import '_review_card.dart';

class ProjectsStep extends ConsumerWidget {
  const ProjectsStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav =
        ref.watch(periodicReviewProvider.select((s) => s.projectsNav));
    final loadError = ref.watch(
        periodicReviewProvider.select((s) => s.projectsLoadError));

    if (loadError != null) {
      return ReviewLoadError(
        title: "Couldn't load projects",
        message: loadError,
        onRetry: () =>
            ref.read(periodicReviewProvider.notifier).loadProjectsSnapshot(),
      );
    }

    if (!nav.isLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (nav.isEmpty || nav.isComplete) {
      return const ReviewEmptyState(
        icon: Icons.folder_outlined,
        title: 'No active project tasks',
        subtitle: 'Tap Next to continue.',
      );
    }

    final todo = nav.current!;
    final db = ref.read(databaseProvider);
    final notifier = ref.read(periodicReviewProvider.notifier);

    return ReviewItemCard(
      key: ValueKey(todo.id),
      todo: todo,
      headline: 'Is this still your next move?',
      actions: [
        ReviewAction(
          label: 'Keep',
          icon: Icons.check_circle_outline,
          color: const Color(0xFF2563EB),
          onTap: () async {
            await db.todoDao.stampLastClarifiedAt(todo.id);
            notifier.advanceProjects();
          },
        ),
        // Route through applyRouting to keep transitions consistent with the
        // canonical write path (planning ritual + inbox-clarify both go
        // through it via the planning notifier).
        ReviewAction(
          label: 'Move to Maybe',
          icon: Icons.star_border,
          color: const Color(0xFF6B7280),
          onTap: () async {
            await db.todoDao.applyRouting(
              todo.id,
              from: RoutingKind.nextAction,
              to: RoutingKind.maybe,
            );
            notifier.advanceProjects();
          },
        ),
        ReviewAction(
          label: 'Discard',
          icon: Icons.delete_outline,
          color: const Color(0xFFDC2626),
          onTap: () async {
            await db.todoDao.applyRouting(
              todo.id,
              from: RoutingKind.nextAction,
              to: RoutingKind.trash,
            );
            notifier.advanceProjects();
          },
        ),
      ],
    );
  }
}
