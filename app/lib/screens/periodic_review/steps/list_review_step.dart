/// Shared per-item-cursor step body for the Weekly Review wizard's three
/// list-driven steps: Waiting For, Next Actions, Someday/Maybe.
///
/// Each step iterates one item at a time over a stable [SnapshotNav<Todo>]
/// loaded when the step opens (per `REQUIREMENTS.md:72`), guards on
/// load-error / loading / empty, renders the current item via
/// [ReviewItemCard], and slots in a configured [ProcessToHandlers] action
/// bar. The post-route bookkeeping (record routing -> advance the cursor) is
/// shaped identically across all three steps; only the slice it writes to
/// and the action filters differ.
///
/// [PeriodicReviewNotifier]'s `_onStepEnter` loads the snapshot on step entry
/// but does not auto-skip — empty snapshots are shown to the user. This widget
/// renders the empty-state UI whenever the snapshot is empty, whether on first
/// entry or when the user backs into the step.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../database/gtd_database.dart';
import '../../../utils/snapshot_nav.dart';
import '../../../widgets/process_to_handlers.dart';
import '_review_card.dart';

/// Copy + iconography for the empty-state surface a list-driven step
/// renders when its snapshot is empty (or the user has consumed all items).
class ListReviewEmpty {
  const ListReviewEmpty({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;
}

/// Generic body for a per-item-cursor Weekly Review step.
///
/// The parent owns the slice projection: it watches the step-specific
/// [SnapshotNav<T>], `loadError`, `routings`, and (optionally) `personTags`
/// from [periodicReviewProvider] and passes them in. The widget itself reads
/// no provider state at all — it dispatches back to the parent via [onRetry],
/// [onRecordRouting], and [onAdvance].
///
/// Per-step axes are exposed as configuration:
/// - [processInclude] / [processExcept] / [processLabels] flow straight
///   into [ProcessToHandlers]. The default-on `nextActionDialog` modifier
///   stays active unless the parent puts it in [processExcept] (Next
///   Actions does — promoting an already-Next item back to Next is
///   nonsensical, so the dialog modifier is inert and removed for clarity).
/// - [headline] / [subtextFor] / [personTagsFor] feed [ReviewItemCard].
/// - [loadErrorTitle] / [emptyState] override the surface copy.
///
/// `T` is generic in the type signature but in practice every callsite is
/// `Todo`; keeping it parametric leaves a clean seam for a future non-Todo
/// list-driven step (e.g. project review) without re-litigating the shape.
class ListReviewStep<T extends Todo> extends ConsumerWidget {
  const ListReviewStep({
    super.key,
    required this.nav,
    required this.loadError,
    required this.routings,
    required this.headline,
    required this.processInclude,
    required this.processExcept,
    required this.processLabels,
    required this.emptyState,
    required this.loadErrorTitle,
    required this.onRetry,
    required this.onRecordRouting,
    required this.onAdvance,
    this.subtextFor,
    this.currentActionTextFor,
    this.personTagsFor,
  });

  /// Step's per-item cursor. Drives the loaded / empty / current-item
  /// branches.
  final SnapshotNav<T> nav;

  /// Non-null when the matching snapshot load failed; renders inline with
  /// a Retry affordance.
  final String? loadError;

  /// In-session record of the last [RoutingKind] applied at each cursor
  /// index. Drives the "previously selected" affordance on the matching
  /// button when the user backs up to revisit an item.
  final Map<int, RoutingKind> routings;

  /// Card headline rendered above the item title (e.g. "Still waiting on
  /// this?", "Is this still your next move?").
  final String headline;

  /// Action set flowed straight into [ProcessToHandlers.include].
  final Set<ProcessAction> processInclude;

  /// Action set flowed straight into [ProcessToHandlers.except]. Include
  /// `nextActionDialog` here to make Next route immediately without
  /// opening [NextActionDialog]; omit it to keep the default-on modifier.
  final Set<ProcessAction> processExcept;

  /// Per-callsite label overrides flowed straight into
  /// [ProcessToHandlers.labels].
  final Map<ProcessAction, String> processLabels;

  /// Copy for the loaded-and-empty / cursor-consumed surface.
  final ListReviewEmpty emptyState;

  /// Heading rendered on the error surface (e.g. "Couldn't load Next
  /// Actions"); the message itself comes from [loadError].
  final String loadErrorTitle;

  /// Tap handler for the Retry affordance on the error surface — usually
  /// the parent's per-step snapshot loader.
  final VoidCallback onRetry;

  /// Records the routing into the step's slice of the wizard state. Called
  /// before [onAdvance] for every action whose [ProcessAction.toRoutingKind]
  /// is non-null (`keep` / `reclarify` back-out skip the record).
  final void Function(int index, RoutingKind kind) onRecordRouting;

  /// Advances the per-step cursor. Always called after a successful
  /// route, after `keep`, and after a Re-clarify… sub-flow's bubbled
  /// action — regardless of whether [onRecordRouting] fired.
  final VoidCallback onAdvance;

  /// Optional per-item subtext rendered between the title and the notes
  /// (e.g. the Next Actions step surfaces the current Action's text).
  final String? Function(T todo)? subtextFor;

  /// Optional per-item current-Action text, from the step's snapshot of
  /// `actions` (ADR-0001 story 3). Prefills the "Update next action" dialog
  /// with what is actually recorded; null leaves the dialog empty.
  final String? Function(T todo)? currentActionTextFor;

  /// Optional person-tag lookup keyed by todo. Returns the delegate chip
  /// list the Waiting For card renders; non-tagged steps leave this null and
  /// the card defaults to no chips.
  final List<Tag> Function(T todo)? personTagsFor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (loadError != null) {
      return ReviewLoadError(
        title: loadErrorTitle,
        message: loadError!,
        onRetry: onRetry,
      );
    }

    if (!nav.isLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (nav.isEmpty || nav.isComplete) {
      return ReviewEmptyState(
        icon: emptyState.icon,
        title: emptyState.title,
        subtitle: emptyState.subtitle,
      );
    }

    final index = nav.index;
    final todo = nav.current!;

    return ReviewItemCard(
      key: ValueKey(todo.id),
      todo: todo,
      headline: headline,
      subtext: subtextFor?.call(todo),
      personTags: personTagsFor?.call(todo) ?? const [],
      process: ProcessToHandlers(
        subject: OutcomeSubject(
          todo,
          currentActionText: currentActionTextFor?.call(todo),
        ),
        include: processInclude,
        except: processExcept,
        labels: processLabels,
        lastAction: routings[index]?.toProcessAction(),
        onAfterRoute: (action) async {
          if (action == ProcessAction.keep) {
            onAdvance();
            return;
          }
          // `nextActionDialog` needs no branch of its own: it collapses onto
          // `RoutingKind.nextAction` below, and a route has landed whenever it
          // arrives here — a blank save falls back to the Outcome's title
          // rather than skipping the write (#691).
          final kind = action.toRoutingKind();
          // `keep` and a bare `reclarify` are the only actions whose
          // toRoutingKind() returns null; `keep` is handled above and the
          // reclarify sub-flow resolves a back-out to `keep` internally
          // (so it arrives as `keep`, advancing without a record). A null
          // here is therefore a defensive no-op, not the common path.
          if (kind == null) return;
          onRecordRouting(index, kind);
          onAdvance();
        },
      ),
    );
  }
}
