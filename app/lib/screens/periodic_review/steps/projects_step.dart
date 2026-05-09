/// Step 3 of the Weekly Review wizard: review each project-tagged next
/// action one at a time. The user-visible step title is "Review Next
/// Actions" — these items are next-actions filtered by project tag.
///
/// Action set mirrors the daily-planning re-clarification surface: Keep,
/// Mark Done, Waiting For, Move to Maybe, Discard. Routing decisions go
/// through [TodoDao.applyRouting] for consistency with the canonical
/// write path; the in-session [PeriodicReviewState.projectsRoutings] map
/// drives the "previously selected" highlight on revisit.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/auth_provider.dart';
import '../../../providers/database_provider.dart';
import '../../../providers/periodic_review_provider.dart';
import '../../../widgets/person_tag_picker.dart';
import '_review_card.dart';

class ProjectsStep extends ConsumerWidget {
  const ProjectsStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav =
        ref.watch(periodicReviewProvider.select((s) => s.projectsNav));
    final loadError = ref.watch(
        periodicReviewProvider.select((s) => s.projectsLoadError));
    final routings = ref.watch(
        periodicReviewProvider.select((s) => s.projectsRoutings));

    if (loadError != null) {
      return ReviewLoadError(
        title: "Couldn't load Next Actions",
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

    final index = nav.index;
    final todo = nav.current!;
    final db = ref.read(databaseProvider);
    final notifier = ref.read(periodicReviewProvider.notifier);
    final userId = ref.read(currentUserIdProvider);

    Future<void> route(RoutingKind to) async {
      await db.todoDao.applyRouting(
        todo.id,
        from: RoutingKind.nextAction,
        to: to,
        userId: userId,
      );
      notifier.recordProjectsRouting(index, to);
      notifier.advanceProjects();
    }

    Future<void> routeWaitingFor() async {
      // Waiting For requires at least one person tag — open the picker
      // first; only after the user confirms a delegate do we run the
      // routing write and advance the cursor.
      final currentTagIds =
          await db.todoDao.getPersonTagIdsForTodo(todo.id);
      if (!context.mounted) return;
      await showPersonTagPicker(
        context,
        todoId: todo.id,
        assignedPersonTagIds: currentTagIds,
        requireSelection: true,
        onAfterConfirm: () async => route(RoutingKind.waitingFor),
      );
    }

    return ReviewItemCard(
      key: ValueKey(todo.id),
      todo: todo,
      headline: 'Is this still your next move?',
      lastRouting: routings[index],
      // Surface the persisted next-action text so the reviewer sees the
      // concrete commitment they made, not just the project title.
      subtext: todo.nextActionText,
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
        ReviewAction(
          label: 'Mark Done',
          icon: Icons.task_alt_outlined,
          color: const Color(0xFF16A34A),
          routing: RoutingKind.done,
          onTap: () => route(RoutingKind.done),
        ),
        ReviewAction(
          label: 'Waiting For',
          icon: Icons.person_outlined,
          color: const Color(0xFF7C3AED),
          routing: RoutingKind.waitingFor,
          onTap: routeWaitingFor,
        ),
        ReviewAction(
          label: 'Move to Maybe',
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
