/// Weekly Review step "Decide Bypassed Outcomes", between Process Inbox and
/// Review Waiting For (CONTEXT.md § Engagement, Bypassed). Shown only when the
/// session holds a Bypassed Outcome.
///
/// One decision per Outcome — Someday/Maybe or Trash — and no Skip: the footer
/// offers only Back until every Outcome in the step is decided.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/bypassed_outcomes_provider.dart';
import '../../../providers/periodic_review_provider.dart';
import '../../../widgets/outcome_review_card.dart';
import '_review_card.dart';

class BypassedStep extends ConsumerWidget {
  const BypassedStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav = ref.watch(periodicReviewProvider.select((s) => s.bypassedNav));
    final todo =
        ref.watch(periodicReviewProvider.select((s) => s.bypassedNextUndecided));
    final decisionPending = ref
        .watch(periodicReviewProvider.select((s) => s.bypassedDecisionPending));
    final loadError =
        ref.watch(periodicReviewProvider.select((s) => s.bypassedLoadError));
    final passCounts =
        ref.watch(periodicReviewProvider.select((s) => s.bypassedPassCounts));
    final actionTexts =
        ref.watch(periodicReviewProvider.select((s) => s.actionTexts));
    final deferredCount = ref
        .watch(periodicReviewProvider.select((s) => s.bypassedDeferredCount));
    final notifier = ref.read(periodicReviewProvider.notifier);

    if (loadError != null) {
      return ReviewLoadError(
        title: "Couldn't load Bypassed Outcomes",
        message: loadError,
        onRetry: notifier.loadBypassedSnapshot,
      );
    }
    if (!nav.isLoaded) return const Center(child: CircularProgressIndicator());
    if (nav.isEmpty || todo == null) {
      return ReviewEmptyState(
        icon: Icons.task_alt_outlined,
        title: 'All Bypassed Outcomes decided',
        subtitle: deferredCount == 0
            ? 'Tap Next step to continue.'
            : '$deferredCount more wait for a longer session. '
                'Tap Next step to continue.',
      );
    }

    final passCount = passCounts[todo.id] ?? 0;
    final actions = ref.read(bypassActionsProvider);

    final todoId = todo.id;
    // The messenger is resolved while this step is mounted and handed down the
    // retry chain: the snackbar outlives the step (Back unmounts it), so Retry
    // must not look it up through this widget's context again.
    Future<void> run(
      ScaffoldMessengerState messenger,
      Future<bool> Function(String id) decision,
    ) async {
      try {
        await notifier.decideBypassed(todoId, decision);
      } catch (_) {
        // The Outcome stays undecided, so the same buttons retry it.
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: const Text("Couldn't save that decision. Try again."),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => unawaited(run(messenger, decision)),
            ),
          ));
      }
    }

    VoidCallback? decide(Future<bool> Function(String id) decision) =>
        decisionPending
            ? null
            : () => unawaited(run(ScaffoldMessenger.of(context), decision));

    return OutcomeReviewCard(
      key: ValueKey(todo.id),
      todo: todo,
      banner: OutcomeReviewBanner(
        icon: Icons.low_priority_outlined,
        text: 'Bypassed $passCount ${passCount == 1 ? 'time' : 'times'} '
            'in Daily Planning',
      ),
      currentActionText: actionTexts[todo.id],
      actions: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            key: const Key('bypassed_someday_maybe'),
            onPressed: decide(actions.moveToSomedayMaybe),
            icon: const Icon(Icons.inbox_outlined, size: 18),
            label: const Text('Someday/Maybe'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('bypassed_trash'),
            onPressed: decide(actions.trash),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Trash'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Trash can be restored.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          ),
        ],
      ),
    );
  }
}
