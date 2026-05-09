/// Step 0 of the Weekly Review wizard: clarify the inbox using the shared
/// [InboxClarifyCard]. Routes each pick directly to the relevant DAO and
/// advances the wizard's nav cursor.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/todo.dart' show RoutingKind;
import '../../../providers/database_provider.dart';
import '../../../providers/periodic_review_provider.dart';
import '../../../widgets/inbox_clarify_card.dart';

class ZeroInboxStep extends ConsumerWidget {
  const ZeroInboxStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav =
        ref.watch(periodicReviewProvider.select((s) => s.inboxNav));
    final loadError = ref.watch(
        periodicReviewProvider.select((s) => s.inboxLoadError));

    if (loadError != null) {
      return _LoadError(
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
        notifier.advanceInbox();
      },
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 56, color: Colors.red[300]),
            const SizedBox(height: 16),
            Text(
              "Couldn't load the inbox",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.grey[800],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
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
