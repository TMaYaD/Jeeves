/// Step 0 of the Weekly Review wizard: clarify the inbox using the shared
/// [InboxClarifyCard]. The card delegates its routing buttons to
/// [ProcessToHandlers] which owns the DAO write; this step only advances the
/// wizard's snapshot cursor and records the routing for the
/// "previously selected" affordance.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/periodic_review_provider.dart';
import '../../../widgets/inbox_clarify_card.dart';
import '../../../widgets/process_to_handlers.dart';
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
      lastAction: routings[index]?.toProcessAction(),
      onAfterRoute: (action) async {
        final notifier = ref.read(periodicReviewProvider.notifier);
        final kind = action.toRoutingKind();
        if (kind == null) return;
        notifier.recordInboxRouting(index, kind);
        notifier.advanceInbox();
      },
    );
  }
}
