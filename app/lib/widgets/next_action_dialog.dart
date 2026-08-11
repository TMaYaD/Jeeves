/// Modal dialog for choosing an Outcome's next Action.
///
/// It offers two moves, and returns which one the user made via
/// `Navigator.pop` as a [NextActionChoice]:
///
/// - **Promote** one of the Outcome's already-queued `planned` Actions — a
///   tappable row that pops [NextActionPromote] the instant it is tapped,
///   matching the Outcome detail view's up-arrow gesture (ADR-0004 story 5).
/// - **Set** a next-action phrase in the text field — Save pops
///   [NextActionPhrase]. An empty phrase is the blank-save title-as-action
///   fallback; the caller ([ProcessToHandlers._nextWithDialog]) keeps it apart
///   from cancel (`null`) by the result's *type*.
///
/// With an empty planned queue the dialog is identical to the pre-#723
/// text-only prompt. The caller decides what each result means; the dialog only
/// collects it.
library;

import 'package:flutter/material.dart';

/// One of the Outcome's `planned` Actions, offered for promotion — its id and
/// display text only, so no Drift `Action` row leaks into the dialog.
typedef PlannedActionOption = ({String id, String text});

/// The dialog's result. A sealed pair so the caller can tell a typed phrase
/// apart from a promotion of an existing planned Action without inspecting a
/// magic string, and so `null` (cancel) stays a third, distinct outcome.
sealed class NextActionChoice {
  const NextActionChoice();
}

/// A next-action phrase the user typed or accepted. An **empty** [text] is the
/// blank-save title-as-action fallback — deliberately distinct from cancel
/// (`null`): the caller routes on it and lets the Outcome's title stand in.
class NextActionPhrase extends NextActionChoice {
  const NextActionPhrase(this.text);
  final String text;
}

/// Promote the already-queued planned Action [actionId] to `current`, rather
/// than writing a fresh phrase.
class NextActionPromote extends NextActionChoice {
  const NextActionPromote(this.actionId);
  final String actionId;
}

class NextActionDialog extends StatefulWidget {
  const NextActionDialog({
    super.key,
    required this.initial,
    required this.taskTitle,
    required this.editingExistingAction,
    this.plannedActions = const <PlannedActionOption>[],
  });

  final String initial;
  final String taskTitle;

  /// Whether the subject already has a current Action — the one thing that
  /// decides between "Set next action" and "Update next action".
  ///
  /// Asked of the caller rather than inferred from [initial] being empty. The
  /// two agree on an Outcome, where [initial] *is* the current Action's text.
  /// They part company on a Capture, whose field is seeded with a *proposal*
  /// mirrored from the title for an Action that does not exist yet — inferring
  /// there would offer to "update" something the user has never written.
  final bool editingExistingAction;

  /// The Outcome's planned queue, offered for one-tap promotion above the text
  /// field. Empty (the default, and every Capture) renders exactly the
  /// pre-#723 text-only dialog.
  final List<PlannedActionOption> plannedActions;

  @override
  State<NextActionDialog> createState() => _NextActionDialogState();
}

class _NextActionDialogState extends State<NextActionDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasQueue = widget.plannedActions.isNotEmpty;
    return AlertDialog(
      title: Text(
        widget.editingExistingAction ? 'Update next action' : 'Set next action',
      ),
      // Scrollable so a long planned queue stays usable when the autofocus
      // keyboard shrinks the available height.
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.taskTitle,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (hasQueue) ...[
              const SizedBox(height: 16),
              Text(
                'PLANNED',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              // Each row promotes on tap — the dialog's second move, the mirror of
              // the detail view's up-arrow. Pops immediately so the caller owns
              // the write (and, when a current Action exists, the replace confirm).
              for (final option in widget.plannedActions)
                InkWell(
                  key: Key('next_action_promote_${option.id}'),
                  onTap: () =>
                      Navigator.pop(context, NextActionPromote(option.id)),
                  // At least a 48dp tap target (Material's minimum interactive
                  // dimension), so a queued row is comfortably tappable.
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: kMinInteractiveDimension,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.arrow_upward,
                            size: 16,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              option.text,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              const Divider(height: 24),
              Text(
                'OR SET A NEW ONE',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Next action',
                hintText: "What's the next physical action?",
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              maxLines: 2,
              minLines: 1,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, NextActionPhrase(_ctrl.text.trim())),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Shows [NextActionDialog] and resolves to a [NextActionChoice] on save or
/// promote, or `null` on cancel.
Future<NextActionChoice?> showNextActionDialog(
  BuildContext context, {
  required String initial,
  required String taskTitle,
  required bool editingExistingAction,
  List<PlannedActionOption> plannedActions = const <PlannedActionOption>[],
}) {
  return showDialog<NextActionChoice>(
    context: context,
    builder: (_) => NextActionDialog(
      initial: initial,
      taskTitle: taskTitle,
      editingExistingAction: editingExistingAction,
      plannedActions: plannedActions,
    ),
  );
}
