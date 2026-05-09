/// Step 0 of the Weekly Review wizard: clarify the inbox using the shared
/// [InboxClarifyCard]. Routes each pick directly to the relevant DAO and
/// advances the wizard's nav cursor.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/database_provider.dart';
import '../../../providers/periodic_review_provider.dart';
import '../../../widgets/inbox_clarify_card.dart';
import '_review_card.dart';

class ZeroInboxStep extends ConsumerWidget {
  const ZeroInboxStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav =
        ref.watch(periodicReviewProvider.select((s) => s.inboxNav));
    final loadError = ref.watch(
        periodicReviewProvider.select((s) => s.inboxLoadError));
    final routings = ref.watch(
        periodicReviewProvider.select((s) => s.inboxRoutings));

    if (loadError != null) {
      return ReviewLoadError(
        title: "Couldn't load the inbox",
        message: loadError,
        onRetry: () =>
            ref.read(periodicReviewProvider.notifier).loadInboxSnapshot(),
      );
    }

    if (!nav.isLoaded) {
      // Mirrors the daily-planning step: kick the lazy load from a post-
      // frame callback. The notifier guards against duplicate fires.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(periodicReviewProvider.notifier).loadInboxSnapshot();
      });
      return const Center(child: CircularProgressIndicator());
    }

    if (nav.isEmpty || nav.isComplete) {
      return const ReviewEmptyState(
        icon: Icons.inbox_outlined,
        title: 'Inbox is clear',
        subtitle: 'Tap Next to continue.',
      );
    }

    final index = nav.index;
    final id = nav.current!;
    return InboxClarifyCard(
      key: ValueKey(id),
      todoId: id,
      lastRouting: routings[index],
      onRoute: (kind) async {
        final db = ref.read(databaseProvider);
        final notifier = ref.read(periodicReviewProvider.notifier);
        // Pull the latest title so the persisted next_action_text reflects
        // any in-card autosave that just landed.
        final todo = await db.todoDao.getTodo(id);
        final title = todo?.title;
        await db.todoDao.applyRouting(
          id,
          to: kind,
          nextActionText:
              kind == RoutingKind.nextAction || kind == RoutingKind.waitingFor
                  ? title
                  : null,
        );
        notifier.recordInboxRouting(index, kind);
        notifier.advanceInbox();
      },
    );
  }
}
