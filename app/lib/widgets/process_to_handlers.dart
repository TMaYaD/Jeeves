/// Single canonical "process to" action bar for a Todo.
///
/// Replaces the four near-parallel button strips that used to live inline in
/// [ClarifyCard], the planning ritual's task-review card, and three
/// periodic-review steps (Waiting For, Projects, Someday/Maybe). Owns its DAO
/// writes; callsites configure presentation only and never see [RoutingKind].
///
/// API surface lives on [ProcessAction]. Callsites that already hold a
/// [RoutingKind] (e.g. from a session record) translate via the co-located
/// [RoutingKindToProcessAction] extension.
library;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../models/todo.dart' show RoutingKind;
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import 'clarify_card.dart';
import 'next_action_dialog.dart';
import 'person_tag_picker.dart';

export '../models/todo.dart' show RoutingKind;

/// User-visible "process to" actions.
///
/// Five real routes (`next`, `waitingFor`, `someday`, `done`, `trash`) map to
/// [TodoDao.applyRouting] internally; `keep` stamps `last_clarified_at` only;
/// `nextActionDialog` is a modifier on the `next` button (not a standalone
/// button) — it is on by default, so tapping Next opens [NextActionDialog]
/// before invoking the `next` mapping unless a callsite removes it via
/// [ProcessToHandlers.except]; `reclarify` is a non-routing entry that opens
/// the [ClarifyCard] sub-flow as a full-page route, distinct from
/// `nextActionDialog` because it renders its own button rather than modifying
/// an existing one.
enum ProcessAction {
  keep,
  next,
  waitingFor,
  someday,
  done,
  trash,
  nextActionDialog,
  reclarify,
}

/// Co-located translation: callsites holding a [RoutingKind] from a session
/// record convert at the read site so the widget never sees [RoutingKind].
extension RoutingKindToProcessAction on RoutingKind {
  ProcessAction toProcessAction() => switch (this) {
        RoutingKind.nextAction => ProcessAction.next,
        RoutingKind.waitingFor => ProcessAction.waitingFor,
        RoutingKind.maybe => ProcessAction.someday,
        RoutingKind.done => ProcessAction.done,
        RoutingKind.trash => ProcessAction.trash,
      };
}

/// Inverse of [RoutingKindToProcessAction]. Callsites that need to persist a
/// routed [ProcessAction] as a [RoutingKind] (e.g. wizard step records) use
/// this to translate at the write site. [ProcessAction.keep] and
/// [ProcessAction.reclarify] have no [RoutingKind] equivalent and return
/// null (`reclarify` opens a sub-flow rather than committing a routing —
/// the inner card's own [ProcessToHandlers] performs any routing it
/// produces and the sub-flow result bubbles back as the routed action).
/// [ProcessAction.nextActionDialog] collapses onto [RoutingKind.nextAction]
/// (it's a UI modifier, not a distinct route).
extension ProcessActionToRoutingKind on ProcessAction {
  RoutingKind? toRoutingKind() => switch (this) {
        ProcessAction.next ||
        ProcessAction.nextActionDialog =>
          RoutingKind.nextAction,
        ProcessAction.waitingFor => RoutingKind.waitingFor,
        ProcessAction.someday => RoutingKind.maybe,
        ProcessAction.done => RoutingKind.done,
        ProcessAction.trash => RoutingKind.trash,
        ProcessAction.keep || ProcessAction.reclarify => null,
      };
}

/// Default actions (and modifiers) active when neither
/// [ProcessToHandlers.include] nor [ProcessToHandlers.except] override the
/// set. `nextActionDialog` is in here as a default-on modifier: promoting to
/// Next always captures a phrase unless a callsite opts out via `except`.
const _kDefaultActions = <ProcessAction>{
  ProcessAction.next,
  ProcessAction.waitingFor,
  ProcessAction.someday,
  ProcessAction.done,
  ProcessAction.trash,
  ProcessAction.nextActionDialog,
};

/// Button-rendering order for the action bar. Modifier-only actions
/// (`nextActionDialog`) don't render their own button. `reclarify` sits
/// next to `keep` because both are "soft" non-routing entries — `keep`
/// stays put, `reclarify` opens the sub-flow.
const _kRenderOrder = <ProcessAction>[
  ProcessAction.keep,
  ProcessAction.reclarify,
  ProcessAction.next,
  ProcessAction.waitingFor,
  ProcessAction.someday,
  ProcessAction.done,
  ProcessAction.trash,
];

/// Default user-visible labels for each renderable action.
const _kDefaultLabels = <ProcessAction, String>{
  ProcessAction.keep: 'Keep',
  ProcessAction.reclarify: 'Re-clarify…',
  ProcessAction.next: 'Next Action',
  ProcessAction.waitingFor: 'Waiting For',
  ProcessAction.someday: 'Someday',
  ProcessAction.done: 'Done',
  ProcessAction.trash: 'Trash',
};

const _kDefaultIcons = <ProcessAction, IconData>{
  // `keep` is intentionally distinct from `next` so it doesn't collide
  // visually with the filled `Icons.check_circle` overlay drawn on the
  // `isPreviouslySelected` button — and so a future callsite surfacing
  // both (Keep + Next) reads unambiguously.
  ProcessAction.keep: Icons.bookmark_outline,
  ProcessAction.reclarify: Icons.tune,
  ProcessAction.next: Icons.check_circle_outline,
  ProcessAction.waitingFor: Icons.person_outlined,
  ProcessAction.someday: Icons.star_border,
  ProcessAction.done: Icons.task_alt_outlined,
  ProcessAction.trash: Icons.delete_outline,
};

const _kDefaultColors = <ProcessAction, Color>{
  ProcessAction.keep: Color(0xFF2563EB),
  ProcessAction.reclarify: Color(0xFF6B7280),
  ProcessAction.next: Color(0xFF2563EB),
  ProcessAction.waitingFor: Color(0xFF7C3AED),
  ProcessAction.someday: Color(0xFF6B7280),
  ProcessAction.done: Color(0xFF16A34A),
  ProcessAction.trash: Color(0xFFDC2626),
};

class ProcessToHandlers extends ConsumerStatefulWidget {
  const ProcessToHandlers({
    super.key,
    required this.todo,
    this.include = const <ProcessAction>{},
    this.except = const <ProcessAction>{},
    this.disabled = const <ProcessAction>{},
    this.labels = const <ProcessAction, String>{},
    this.lastAction,
    this.onAfterRoute,
  });

  final Todo todo;

  /// Surfaces non-default actions (e.g. `keep`). The `nextActionDialog`
  /// modifier is on by default — remove it via [except], don't add it here.
  final Set<ProcessAction> include;

  /// Hides default actions, including the default-on `nextActionDialog`
  /// modifier — add `nextActionDialog` here to make Next route immediately
  /// without opening [NextActionDialog].
  final Set<ProcessAction> except;

  /// Renders these actions but disables their tap. Parent-owned validation
  /// (e.g. inbox card disables routes while title is empty).
  final Set<ProcessAction> disabled;

  /// Per-callsite label overrides keyed by [ProcessAction].
  ///
  /// **Use sparingly.** The default labels are the canonical vocabulary; the
  /// whole point of this widget is to collapse the pre-extraction drift
  /// ("Discard"/"Trash", "Maybe"/"Send to Someday"/"Move to Maybe",
  /// "Promote to Next Action(s)"/"Next") into one set of names. An override
  /// is only justified when the surface needs context the canonical label
  /// can't carry — e.g. `keep` becoming "Keep waiting" / "Keep on Someday" /
  /// "Still relevant" because plain "Keep" is ambiguous, or `next` becoming
  /// "Update next action…" to signal that [ProcessAction.nextActionDialog]
  /// is included and the button opens a dialog.
  ///
  /// Verb-prefixed synonyms of a canonical destination ("Promote to Next",
  /// "Send to Someday", "Mark done") are drift, not context — drop them.
  final Map<ProcessAction, String> labels;

  /// The action most recently applied to this item — drives the
  /// "previously selected" affordance on the matching button.
  final ProcessAction? lastAction;

  /// Called once after a successful write (or after `keep` stamps
  /// `last_clarified_at`). Not called when the user cancels a sub-dialog.
  ///
  /// Callsites that want to couple a route to a `next_action_text` write
  /// (e.g. inbox-clarify treating the title as the next action) own that
  /// write here — the routing call itself is intent-only for plain
  /// `next` / `waitingFor`, and only the [ProcessAction.nextActionDialog]
  /// modifier writes `next_action_text` from inside the widget.
  final Future<void> Function(ProcessAction)? onAfterRoute;

  @override
  ConsumerState<ProcessToHandlers> createState() => _ProcessToHandlersState();
}

class _ProcessToHandlersState extends ConsumerState<ProcessToHandlers> {
  bool _processing = false;

  /// Cached result of [_computeResolvedActions]: the default actions plus
  /// [ProcessToHandlers.include], minus [ProcessToHandlers.except]. Recomputed
  /// only when `include` / `except` change (see [didUpdateWidget]) so build
  /// doesn't reallocate the set on every frame.
  late Set<ProcessAction> _resolvedActions;

  @override
  void initState() {
    super.initState();
    _resolvedActions = _computeResolvedActions();
  }

  @override
  void didUpdateWidget(ProcessToHandlers oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!setEquals(oldWidget.include, widget.include) ||
        !setEquals(oldWidget.except, widget.except)) {
      _resolvedActions = _computeResolvedActions();
    }
  }

  /// The default actions plus [ProcessToHandlers.include], minus
  /// [ProcessToHandlers.except]. Includes `nextActionDialog` when active.
  Set<ProcessAction> _computeResolvedActions() => <ProcessAction>{
        ..._kDefaultActions,
        ...widget.include,
      }..removeAll(widget.except);

  /// Renderable buttons: the resolved set minus modifier-only actions.
  /// `nextActionDialog` never renders its own button. Returns a fresh copy so
  /// the cached [_resolvedActions] set is never mutated.
  Set<ProcessAction> _renderableActions() =>
      Set<ProcessAction>.of(_resolvedActions)
        ..remove(ProcessAction.nextActionDialog);

  /// Whether the `nextActionDialog` modifier is active for this callsite —
  /// on by default, removed via [ProcessToHandlers.except]. When active,
  /// tapping Next opens [NextActionDialog] before routing.
  bool _dialogModifierActive() =>
      _resolvedActions.contains(ProcessAction.nextActionDialog);

  Future<void> _runOnce(Future<void> Function() action) async {
    if (_processing) return;
    setState(() => _processing = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _onTap(ProcessAction action) async {
    switch (action) {
      case ProcessAction.keep:
        await _runOnce(_keep);
      case ProcessAction.reclarify:
        await _runOnce(_reclarify);
      case ProcessAction.next:
        if (_dialogModifierActive()) {
          await _runOnce(_nextWithDialog);
        } else {
          await _runOnce(_next);
        }
      case ProcessAction.waitingFor:
        await _runOnce(_waitingFor);
      case ProcessAction.someday:
        await _runOnce(() => _route(ProcessAction.someday));
      case ProcessAction.done:
        await _runOnce(() => _route(ProcessAction.done));
      case ProcessAction.trash:
        await _runOnce(() => _route(ProcessAction.trash));
      case ProcessAction.nextActionDialog:
        // Modifier — never rendered as a standalone button. Defensive no-op.
        return;
    }
  }

  /// Snapshot-based callsites (inbox-clarify, periodic review) can lose a
  /// row between render and tap — sync or another device may hard-delete it.
  /// PowerSync exposes `todos` as a SQLite VIEW with INSTEAD OF triggers, so
  /// the affected-rows count for an UPDATE is always 0; we can't tell from
  /// the write whether anything happened. Pre-check existence here so we
  /// don't fire [onAfterRoute] (which advances the snapshot cursor and
  /// records a phantom routing record) for a row that no longer exists.
  Future<bool> _todoExists() async {
    final db = ref.read(databaseProvider);
    return await db.todoDao.getTodo(widget.todo.id) != null;
  }

  Future<void> _keep() async {
    if (!await _todoExists()) return;
    final db = ref.read(databaseProvider);
    await db.todoDao.stampLastClarifiedAt(widget.todo.id);
    await widget.onAfterRoute?.call(ProcessAction.keep);
  }

  /// Opens the [ClarifyCard] sub-flow as a full-page route. The pushed
  /// card owns its own [ProcessToHandlers], so any routing performed
  /// inside is committed by that inner widget — this outer call only
  /// bubbles the chosen action through [onAfterRoute] for callsite
  /// bookkeeping (record routing, advance cursor). Backing out without
  /// routing maps to [ProcessAction.keep] so the review step advances
  /// without recording a routing.
  Future<void> _reclarify() async {
    if (!await _todoExists()) return;
    if (!mounted) return;
    final routed = await Navigator.of(context).push<ProcessAction>(
      MaterialPageRoute<ProcessAction>(
        builder: (routeContext) => Scaffold(
          appBar: AppBar(title: const Text('Re-clarify')),
          body: ClarifyCard(
            todoId: widget.todo.id,
            mode: ClarifyMode.reclarify,
            onAfterRoute: (action) async {
              if (Navigator.of(routeContext).canPop()) {
                Navigator.of(routeContext).pop(action);
              }
            },
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (routed == null) {
      await _keep();
      return;
    }
    await widget.onAfterRoute?.call(routed);
  }

  Future<void> _next() async {
    if (!await _todoExists()) return;
    final db = ref.read(databaseProvider);
    await db.todoDao.applyRouting(
      widget.todo.id,
      to: RoutingKind.nextAction,
    );
    await widget.onAfterRoute?.call(ProcessAction.next);
  }

  Future<void> _nextWithDialog() async {
    // Edit-existing semantics: prefer the row's stored value so the user
    // sees what's currently saved.
    final initial = widget.todo.nextActionText ?? '';
    final result = await showNextActionDialog(
      context,
      initial: initial,
      taskTitle: widget.todo.title,
    );
    if (result == null) return; // user cancelled
    if (!mounted) return;
    if (!await _todoExists()) return;
    if (result.isNotEmpty) {
      // A blank save must not route: promoting to Next with no phrase
      // would land the item actionless on the Next list — the exact
      // outcome the dialog modifier exists to prevent. Skip the write but
      // still notify the callsite so it can react (e.g. clear a stale
      // action record); its handler re-reads the row and sees the
      // unchanged value.
      final db = ref.read(databaseProvider);
      await db.todoDao.applyRouting(
        widget.todo.id,
        to: RoutingKind.nextAction,
        nextActionText: result,
      );
    }
    await widget.onAfterRoute?.call(ProcessAction.nextActionDialog);
  }

  Future<void> _waitingFor() async {
    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    final currentTagIds =
        await db.todoDao.getPersonTagIdsForTodo(widget.todo.id);
    if (!mounted) return;
    var confirmed = false;
    await showPersonTagPicker(
      context,
      todoId: widget.todo.id,
      assignedPersonTagIds: currentTagIds,
      requireSelection: true,
      onAfterConfirm: () async {
        if (!await _todoExists()) return;
        confirmed = true;
        final selected =
            await db.todoDao.getPersonTagIdsForTodo(widget.todo.id);
        // Routing to waitingFor is intent-only — `next_action_text` is on
        // the orthogonal "what's the action?" axis and is not touched here.
        // Callsites that want to couple a phrase write own it via
        // `onAfterRoute` (or the `nextActionDialog` modifier when editing
        // an existing phrase).
        await db.todoDao.applyRouting(
          widget.todo.id,
          to: RoutingKind.waitingFor,
          personTagIds: selected,
          userId: userId,
        );
      },
    );
    if (!confirmed) return;
    await widget.onAfterRoute?.call(ProcessAction.waitingFor);
  }

  Future<void> _route(ProcessAction action) async {
    if (!await _todoExists()) return;
    final db = ref.read(databaseProvider);
    final to = switch (action) {
      ProcessAction.someday => RoutingKind.maybe,
      ProcessAction.done => RoutingKind.done,
      ProcessAction.trash => RoutingKind.trash,
      _ => throw StateError('Unexpected route action: $action'),
    };
    // Person tags are orthogonal to intent: a delegated task can become
    // `someday` / `done` / `trash` without losing its delegate. The picker
    // is the only path that mutates person tags.
    await db.todoDao.applyRouting(widget.todo.id, to: to);
    await widget.onAfterRoute?.call(action);
  }

  @override
  Widget build(BuildContext context) {
    final renderable = _renderableActions();
    final ordered = _kRenderOrder.where(renderable.contains).toList();

    return AnimatedOpacity(
      opacity: _processing ? 0.4 : 1.0,
      duration: const Duration(milliseconds: 150),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < ordered.length; i++) ...[
            _ActionButton(
              label: widget.labels[ordered[i]] ?? _kDefaultLabels[ordered[i]]!,
              icon: _kDefaultIcons[ordered[i]]!,
              color: _kDefaultColors[ordered[i]]!,
              enabled: !_processing && !widget.disabled.contains(ordered[i]),
              isPreviouslySelected: widget.lastAction == ordered[i] ||
                  // Tapping Next with the dialog modifier records
                  // `nextActionDialog` in callsite state; highlight Next.
                  (ordered[i] == ProcessAction.next &&
                      widget.lastAction == ProcessAction.nextActionDialog),
              onTap: () => _onTap(ordered[i]),
            ),
            if (i < ordered.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

/// Outlined button used for each action. Mirrors the styling of the existing
/// `_ActionButton` in `_review_card.dart` so visual parity is preserved
/// across the migrated callsites.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.enabled,
    required this.isPreviouslySelected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool enabled;
  final bool isPreviouslySelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final iconColor = enabled ? color : color.withValues(alpha: 0.38);
    return OutlinedButton.icon(
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, size: 18, color: iconColor),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (isPreviouslySelected) ...[
            const SizedBox(width: 8),
            Icon(Icons.check_circle, size: 16, color: iconColor),
          ],
        ],
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        backgroundColor:
            isPreviouslySelected ? color.withValues(alpha: 0.08) : null,
        side: BorderSide(
          color: color.withValues(
            alpha: !enabled
                ? 0.2
                : isPreviouslySelected
                    ? 0.85
                    : 0.4,
          ),
          width: isPreviouslySelected ? 1.5 : 1.0,
        ),
        alignment: Alignment.centerLeft,
        minimumSize: const Size.fromHeight(44),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
