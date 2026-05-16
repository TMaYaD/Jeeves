/// Step 0 of the daily planning ritual: Clarify Inbox.
///
/// Works through each inbox item one at a time using a fixed snapshot of
/// **IDs** loaded at step start (oldest-first order). Navigation is
/// index-based; the snapshot pins the order, while per-item attributes are
/// read live from Drift via [taskDetailTodoProvider]. Edits autosave on
/// change so they survive Skip and Back without any draft layer in the
/// planning state.
///
/// Renders the shared [ClarifyCard] for each item; this step is
/// responsible only for advancing the snapshot cursor and recording each
/// pick on the planning notifier (which drives the "previously selected"
/// affordance and revert-on-re-route).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/focus_session_planning_provider.dart';
import '../../../widgets/clarify_card.dart';
import '../../../widgets/process_to_handlers.dart';

class InboxClarificationStep extends ConsumerWidget {
  const InboxClarificationStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav =
        ref.watch(focusSessionPlanningProvider.select((s) => s.inboxNav));
    final inboxRoutings = ref.watch(
        focusSessionPlanningProvider.select((s) => s.inboxRoutings));

    if (!nav.isLoaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(focusSessionPlanningProvider.notifier).loadInboxSnapshot();
      });
      return const Center(child: CircularProgressIndicator());
    }

    if (nav.isEmpty || nav.isComplete) {
      return const _InboxCleared();
    }

    final id = nav.current!;
    return ClarifyCard(
      key: ValueKey(id),
      todoId: id,
      lastAction: inboxRoutings[nav.index]?.kind.toProcessAction(),
      onAfterRoute: (action) async {
        // [ClarifyCard] does not include `keep` or the
        // `nextActionDialog` modifier, so neither action can actually
        // arrive here. The shared extension returns null for `keep`
        // (no routing recorded) and collapses `nextActionDialog` onto
        // the `next` route — the same target it would land on if the
        // modifier ever were enabled at this surface.
        final kind = action.toRoutingKind();
        if (kind == null) return;
        ref
            .read(focusSessionPlanningProvider.notifier)
            .recordInboxRoutingAndAdvance(kind);
      },
    );
  }
}

class _InboxCleared extends StatelessWidget {
  const _InboxCleared();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined, size: 56, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            'Inbox is clear!',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Tap Next to check in for the day.',
            style: TextStyle(fontSize: 14, color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }
}
