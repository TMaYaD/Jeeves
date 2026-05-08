/// Step 0 of the daily planning ritual: Clarify Inbox.
///
/// Works through each inbox item one at a time using a fixed snapshot of
/// **IDs** loaded at step start (oldest-first order). Navigation is
/// index-based; the snapshot pins the order, while per-item attributes are
/// read live from Drift via [taskDetailTodoProvider]. Edits autosave on
/// change so they survive Skip and Back without any draft layer in the
/// planning state.
///
/// Renders the shared [InboxClarifyCard] for each item; this step is
/// responsible only for advancing the snapshot cursor and routing each pick
/// through the planning notifier (which records routing history for the
/// "previously selected" affordance and revert-on-re-route).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/database_provider.dart';
import '../../../providers/focus_session_planning_provider.dart';
import '../../../widgets/inbox_clarify_card.dart';

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
    final priorKind = _kindFromString(inboxRoutings[nav.index]?.kind);
    return InboxClarifyCard(
      key: ValueKey(id),
      todoId: id,
      lastRouting: priorKind,
      onRoute: (kind) async {
        final notifier = ref.read(focusSessionPlanningProvider.notifier);
        // Pull the latest title from the live row so the recorded
        // next_action_text matches whatever autosave most recently committed.
        final db = ref.read(databaseProvider);
        final todo = await db.todoDao.getTodo(id);
        final title = todo?.title ?? '';
        switch (kind) {
          case InboxClarifyKind.nextAction:
            await notifier.processInboxItem(id, title: title);
          case InboxClarifyKind.waitingFor:
            await notifier.processInboxItemToWaitingFor(id, title: title);
          case InboxClarifyKind.maybe:
            await notifier.processInboxItemToMaybe(id);
          case InboxClarifyKind.done:
            await notifier.processInboxItemToDone(id);
          case InboxClarifyKind.trash:
            await notifier.processInboxItemToTrash(id);
        }
      },
    );
  }
}

/// Maps the persisted routing-record [kind] string back to the enum used by
/// the shared card to render the "previously selected" affordance.
InboxClarifyKind? _kindFromString(String? kind) {
  switch (kind) {
    case 'next_action':
      return InboxClarifyKind.nextAction;
    case 'waiting_for':
      return InboxClarifyKind.waitingFor;
    case 'maybe':
      return InboxClarifyKind.maybe;
    case 'done':
      return InboxClarifyKind.done;
    case 'trash':
      return InboxClarifyKind.trash;
    default:
      return null;
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
