/// Step 1 of the daily planning ritual: Clarify Inbox.
///
/// Delegates the per-item / loading / completion branching to the shared
/// [ClarifyStep] widget, passing:
///
/// - [nav] — the DPR inbox snapshot cursor.
/// - [routings] — in-session routing history keyed by cursor index
///   ([FocusSessionPlanningState.inboxRoutings] carries [RoutingKind] values
///   directly — no projection needed).
/// - [onAfterRoute] — records the routing in DPR state and advances the
///   cursor via [FocusSessionPlanningNotifier.recordInboxRoutingAndAdvance].
/// - [onLoad] — kicks [FocusSessionPlanningNotifier.loadInboxSnapshot] on the
///   first frame the snapshot is not yet loaded.
///
/// Navigation is index-based; the snapshot pins the order, while per-item
/// attributes are read live from Drift via [ClarifyCard]. Edits autosave on
/// change so they survive Skip and Back without any draft layer in the
/// planning state.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/focus_session_planning_provider.dart';
import '../../../widgets/ceremony/clarify_step.dart';
import '../../../widgets/process_to_handlers.dart';

class InboxClarificationStep extends ConsumerWidget {
  const InboxClarificationStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav =
        ref.watch(focusSessionPlanningProvider.select((s) => s.inboxNav));
    final routings = ref.watch(
        focusSessionPlanningProvider.select((s) => s.inboxRoutings));

    return ClarifyStep(
      nav: nav,
      routings: routings,
      onAfterRoute: (action) async {
        // [ClarifyCard] does not include `keep` or the `nextActionDialog`
        // modifier, so neither action can actually arrive here. The shared
        // extension returns null for `keep` (no routing recorded) and
        // collapses `nextActionDialog` onto the `next` route — the same
        // target it would land on if the modifier ever were enabled at this
        // surface.
        final kind = action.toRoutingKind();
        if (kind == null) return;
        ref
            .read(focusSessionPlanningProvider.notifier)
            .recordInboxRoutingAndAdvance(kind);
      },
      // The n-m verdict picked no destination, so there is no routing to
      // record — only the cursor advance, which is what [skipInboxItem]
      // already is (advance, write nothing, record nothing).
      onAfterComplete: () async =>
          ref.read(focusSessionPlanningProvider.notifier).skipInboxItem(),
      onLoad: () =>
          ref.read(focusSessionPlanningProvider.notifier).loadInboxSnapshot(),
    );
  }
}
