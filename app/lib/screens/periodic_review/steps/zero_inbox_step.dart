/// Step 0 of the Weekly Review wizard: clarify the inbox using the shared
/// [InboxClarifyCard]. Routes each pick directly to the relevant DAO and
/// advances the wizard's nav cursor.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/todo.dart' as todo_model show Intent;
import '../../../providers/database_provider.dart';
import '../../../providers/periodic_review_provider.dart';
import '../../../widgets/inbox_clarify_card.dart';

class ZeroInboxStep extends ConsumerStatefulWidget {
  const ZeroInboxStep({super.key});

  @override
  ConsumerState<ZeroInboxStep> createState() => _ZeroInboxStepState();
}

class _ZeroInboxStepState extends ConsumerState<ZeroInboxStep> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      // Lazy-load: only triggers a fetch the first time the step is shown.
      final nav = ref.read(periodicReviewProvider).inboxNav;
      if (!nav.isLoaded) {
        ref
            .read(periodicReviewProvider.notifier)
            .loadInboxSnapshot()
            .catchError((Object e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to load inbox: $e')),
          );
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final nav =
        ref.watch(periodicReviewProvider.select((s) => s.inboxNav));

    if (!nav.isLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (nav.isEmpty || nav.isComplete) {
      return _EmptyState(
        icon: Icons.inbox_outlined,
        title: 'Inbox is clear',
        subtitle: 'Tap Next to continue.',
      );
    }

    final id = nav.current!;
    return InboxClarifyCard(
      key: ValueKey(id),
      todoId: id,
      onRoute: (kind) async {
        final db = ref.read(databaseProvider);
        final notifier = ref.read(periodicReviewProvider.notifier);
        switch (kind) {
          case InboxClarifyKind.nextAction:
          case InboxClarifyKind.waitingFor:
            await db.inboxDao.processInboxItem(id);
            final todo = await db.todoDao.getTodo(id);
            if (todo != null) {
              await db.todoDao.setNextActionText(id, todo.title);
            }
          case InboxClarifyKind.maybe:
            await db.inboxDao
                .processInboxItem(id, intent: todo_model.Intent.maybe.value);
          case InboxClarifyKind.done:
            await db.todoDao.markDone(id);
          case InboxClarifyKind.trash:
            await db.inboxDao
                .processInboxItem(id, intent: todo_model.Intent.trash.value);
        }
        notifier.advanceInbox();
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(fontSize: 14, color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }
}
