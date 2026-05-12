/// Step 3 of the Weekly Review wizard: review each project-tagged next
/// action one at a time. The user-visible step title is "Review Next
/// Actions" — these items are next-actions filtered by project tag.
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
    final notifier = ref.read(periodicReviewProvider.notifier);

    return ReviewItemCard(
      key: ValueKey(todo.id),
      todo: todo,
      headline: 'Is this still your next move?',
      // Surface the persisted next-action text so the reviewer sees the
      // concrete commitment they made, not just the project title.
      subtext: todo.nextActionText,
      // Defaults minus Next: the item is already on the Next list, so
      // re-confirming as Next is what Keep is for.
      process: ProcessToHandlers(
        todo: todo,
        include: const {ProcessAction.keep},
        except: const {ProcessAction.next},
        lastAction: routings[index]?.toProcessAction(),
        onAfterRoute: (action) async {
          if (action == ProcessAction.keep) {
            notifier.advanceProjects();
            return;
          }
          final kind = action.toRoutingKind();
          if (kind == null) return;
          notifier.recordProjectsRouting(index, kind);
          notifier.advanceProjects();
        },
      ),
    );
  }
}
