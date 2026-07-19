/// Step 0 of the Weekly Review wizard: Clarify Inbox.
///
/// Delegates the per-item / loading / completion branching to the shared
/// [ClarifyStep] widget — the exact same class used by DPR's
/// InboxClarificationStep. Passing:
///
/// - [nav] — the WR inbox snapshot cursor.
/// - [routings] — in-session routing history keyed by cursor index
///   ([PeriodicReviewState.inboxRoutings] already carries [RoutingKind] values
///   directly).
/// - [onAfterRoute] — records the routing in WR state and advances the inbox
///   cursor.
/// - [onLoad] — kicks [PeriodicReviewNotifier.loadInboxSnapshot] on the first
///   frame the snapshot is not yet loaded (mirrors the original lazy-load
///   postFrameCallback pattern).
///
/// The completion widget is owned by [ClarifyStep] (same copy for both
/// ceremonies). Load-error rendering is delegated separately via the [loadError]
/// guard below.
///
/// The card delegates routing buttons to [ProcessToHandlers]; this step only
/// advances the wizard's snapshot cursor and records the routing for the
/// "previously selected" affordance.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/periodic_review_provider.dart';
import '../../../widgets/ceremony/clarify_step.dart';
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

    return ClarifyStep(
      nav: nav,
      routings: routings,
      onAfterRoute: (action) async {
        final notifier = ref.read(periodicReviewProvider.notifier);
        final index = nav.index;
        final kind = action.toRoutingKind();
        if (kind == null) return;
        notifier.recordInboxRouting(index, kind);
        notifier.advanceInbox();
      },
      onAfterComplete: () async =>
          ref.read(periodicReviewProvider.notifier).advanceInbox(),
      onLoad: () =>
          ref.read(periodicReviewProvider.notifier).loadInboxSnapshot(),
    );
  }
}
