/// Shared Clarify Inbox step body, used by both the Daily Planning Ritual
/// (DPR) and the Weekly Review (WR).
///
/// Both ceremonies walk through the inbox one item at a time using a
/// [SnapshotNav<String>] of todo IDs. The step body is identical in both
/// contexts: show a loading spinner while the snapshot loads, show the
/// shared [_InboxCleared] completion widget once all items have been processed
/// or the inbox is empty, and show a [ClarifyCard] for the current item
/// otherwise.
///
/// Caller responsibilities:
///
/// - Provide [nav] — the ceremony's inbox snapshot cursor.
/// - Provide [routings] — the in-session routing history keyed by cursor index
///   (used to restore the "previously selected" affordance on Back).
/// - Provide [onAfterRoute] — called once the user commits a routing decision.
///   The callee records the routing in ceremony state and advances the cursor.
/// - Provide [onSubjectMissing] — called when the user escapes a card whose
///   Capture was hard-deleted underneath them; the callee advances the cursor
///   without recording a routing.
/// - Provide [onLoad] — called on the first frame when the snapshot is not
///   yet loaded; the callee kicks the load from the relevant notifier.
///
/// The widget has **no** hard-coded Riverpod provider dependency — it takes
/// all ceremony-specific state as constructor arguments so both DPR and WR can
/// pass their respective provider slices.
///
/// The completion widget is intentionally **not** a constructor parameter —
/// both ceremonies show the same "Inbox is clear" copy per
/// CONTEXT.md ("almost no customisability" invariant). Any discrepancy between
/// ceremonies in this step is a bug, not a feature.
library;

import 'package:flutter/material.dart';

import '../../utils/snapshot_nav.dart';
import '../../widgets/clarify_card.dart';
import '../../widgets/process_to_handlers.dart';

/// Shared "Clarify Inbox" step body widget.
///
/// Used by both [FocusSessionPlanningScreen] (DPR, step 0) and
/// [PeriodicReviewScreen] (WR, step 0) so the per-item UI, load-spinner, and
/// completion-placeholder are literally the same code across both ceremonies.
class ClarifyStep extends StatefulWidget {
  const ClarifyStep({
    super.key,
    required this.nav,
    required this.routings,
    required this.onAfterRoute,
    required this.onSubjectMissing,
    this.onLoad,
  });

  /// The inbox snapshot cursor for this ceremony.
  final SnapshotNav<String> nav;

  /// In-session routing history: cursor-index → [RoutingKind] last applied at
  /// that position. Used by [ClarifyCard] to restore the "previously selected"
  /// affordance when the user navigates Back to an already-processed item.
  final Map<int, RoutingKind> routings;

  /// Called after the user commits a routing decision. The caller records the
  /// routing in ceremony state and advances the cursor.
  final Future<void> Function(ProcessAction action) onAfterRoute;

  /// Called when the user taps the escape on a card whose Capture was
  /// hard-deleted underneath them. The caller advances the cursor *without*
  /// recording a routing — there is no verdict to record for a row that no
  /// longer exists.
  final VoidCallback onSubjectMissing;

  /// Called once on the first frame when [nav] is not yet loaded, so the
  /// caller can kick the snapshot load.
  final VoidCallback? onLoad;

  @override
  State<ClarifyStep> createState() => _ClarifyStepState();
}

class _ClarifyStepState extends State<ClarifyStep> {
  bool _loadKicked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeKickLoad();
  }

  @override
  void didUpdateWidget(ClarifyStep oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reset only on loaded → unloaded transitions. A parent that rebuilds
    // while nav is still unloaded must not re-arm the kick — otherwise
    // unrelated state changes can schedule a second post-frame callback
    // before the in-flight load completes.
    if (oldWidget.nav.isLoaded && !widget.nav.isLoaded) {
      _loadKicked = false;
    }
    _maybeKickLoad();
  }

  void _maybeKickLoad() {
    if (!widget.nav.isLoaded && !_loadKicked && widget.onLoad != null) {
      _loadKicked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Re-check isLoaded inside the callback: the load may have
        // completed between scheduling and the next frame.
        if (mounted && !widget.nav.isLoaded) widget.onLoad!();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final nav = widget.nav;

    if (!nav.isLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (nav.isEmpty || nav.isComplete) {
      return const _InboxCleared();
    }

    final index = nav.index;
    // The ceremony inbox snapshots hold Capture ids since the split (ADR-0006):
    // the step clarifies Captures into Outcomes, it never edits an Outcome.
    final captureId = nav.current!;
    return ClarifyCard.forCapture(
      key: ValueKey(captureId),
      captureId: captureId,
      // The RoutingKindToProcessAction extension lives in
      // process_to_handlers.dart and is imported transitively via
      // clarify_card.dart → process_to_handlers.dart.
      lastAction: widget.routings[index]?.toProcessAction(),
      onAfterRoute: widget.onAfterRoute,
      onSubjectMissing: widget.onSubjectMissing,
    );
  }
}

/// Canonical "Inbox is clear" completion placeholder — shown by both DPR and
/// WR once the inbox snapshot is exhausted. Both ceremonies show the same
/// copy because functionally there is zero difference between them at this
/// step (same drift query, same routing choices, same next action).
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
            'Inbox is clear',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }
}
