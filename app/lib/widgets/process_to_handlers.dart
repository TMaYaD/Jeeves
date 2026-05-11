/// Single canonical "process to" action bar for a Todo.
///
/// Replaces the four near-parallel button strips that used to live inline in
/// [InboxClarifyCard], the planning ritual's task-review card, and three
/// periodic-review steps (Waiting For, Projects, Someday/Maybe). Owns its DAO
/// writes; callsites configure presentation only and never see [RoutingKind].
///
/// API surface lives on [ProcessAction]. Callsites that already hold a
/// [RoutingKind] (e.g. from a session record) translate via the co-located
/// [RoutingKindToProcessAction] extension.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../models/todo.dart' show RoutingKind;
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import 'next_action_dialog.dart';
import 'person_tag_picker.dart';

export '../models/todo.dart' show RoutingKind;

/// User-visible "process to" actions.
///
/// Five real routes (`next`, `waitingFor`, `someday`, `done`, `trash`) map to
/// [TodoDao.applyRouting] internally; `keep` stamps `last_clarified_at` only;
/// `nextActionDialog` is a modifier on the `next` button (not a standalone
/// button) — when included, tapping Next opens [NextActionDialog] before
/// invoking the `next` mapping.
enum ProcessAction {
  keep,
  next,
  waitingFor,
  someday,
  done,
  trash,
  nextActionDialog,
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
/// this to translate at the write site. [ProcessAction.keep] has no
/// [RoutingKind] equivalent and returns null; [ProcessAction.nextActionDialog]
/// collapses onto [RoutingKind.nextAction] (it's a UI modifier, not a
/// distinct route).
extension ProcessActionToRoutingKind on ProcessAction {
  RoutingKind? toRoutingKind() => switch (this) {
        ProcessAction.next ||
        ProcessAction.nextActionDialog =>
          RoutingKind.nextAction,
        ProcessAction.waitingFor => RoutingKind.waitingFor,
        ProcessAction.someday => RoutingKind.maybe,
        ProcessAction.done => RoutingKind.done,
        ProcessAction.trash => RoutingKind.trash,
        ProcessAction.keep => null,
      };
}

/// Default actions rendered when neither [ProcessToHandlers.include] nor
/// [ProcessToHandlers.except] override the set.
const _kDefaultActions = <ProcessAction>{
  ProcessAction.next,
  ProcessAction.waitingFor,
  ProcessAction.someday,
  ProcessAction.done,
  ProcessAction.trash,
};

/// Button-rendering order for the action bar. Modifier-only actions
/// (`nextActionDialog`) don't render their own button.
const _kRenderOrder = <ProcessAction>[
  ProcessAction.keep,
  ProcessAction.next,
  ProcessAction.waitingFor,
  ProcessAction.someday,
  ProcessAction.done,
  ProcessAction.trash,
];

/// Default user-visible labels for each renderable action.
const _kDefaultLabels = <ProcessAction, String>{
  ProcessAction.keep: 'Keep',
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
  ProcessAction.next: Icons.check_circle_outline,
  ProcessAction.waitingFor: Icons.person_outlined,
  ProcessAction.someday: Icons.star_border,
  ProcessAction.done: Icons.task_alt_outlined,
  ProcessAction.trash: Icons.delete_outline,
};

const _kDefaultColors = <ProcessAction, Color>{
  ProcessAction.keep: Color(0xFF2563EB),
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

  /// Surfaces non-default actions or modifiers (e.g. `keep`, `nextActionDialog`).
  final Set<ProcessAction> include;

  /// Hides default actions.
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

  Set<ProcessAction> _renderableActions() {
    final actions = <ProcessAction>{
      ..._kDefaultActions,
      ...widget.include,
    }..removeAll(widget.except);
    actions.remove(ProcessAction.nextActionDialog);
    return actions;
  }

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
      case ProcessAction.next:
        if (widget.include.contains(ProcessAction.nextActionDialog)) {
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

  Future<void> _keep() async {
    final db = ref.read(databaseProvider);
    await db.todoDao.stampLastClarifiedAt(widget.todo.id);
    await widget.onAfterRoute?.call(ProcessAction.keep);
  }

  Future<void> _next() async {
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
    final db = ref.read(databaseProvider);
    await db.todoDao.applyRouting(
      widget.todo.id,
      to: RoutingKind.nextAction,
      nextActionText: result,
    );
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
