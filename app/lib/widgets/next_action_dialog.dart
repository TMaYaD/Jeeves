/// Modal dialog for capturing or editing an Outcome's current Action text.
///
/// Returns the trimmed text via `Navigator.pop`; the caller decides what to do
/// with it (write it as the `current` Action, leave the Outcome Actionless,
/// etc.). Returns `null` on cancel.
library;

import 'package:flutter/material.dart';

class NextActionDialog extends StatefulWidget {
  const NextActionDialog({
    super.key,
    required this.initial,
    required this.taskTitle,
    required this.editingExistingAction,
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
    return AlertDialog(
      title: Text(
        widget.editingExistingAction
            ? 'Update next action'
            : 'Set next action',
      ),
      content: Column(
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
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Next action',
              hintText: "What's the next physical action?",
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            maxLines: 2,
            minLines: 1,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Shows [NextActionDialog] and resolves to the trimmed text on save, or
/// `null` on cancel.
Future<String?> showNextActionDialog(
  BuildContext context, {
  required String initial,
  required String taskTitle,
  required bool editingExistingAction,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => NextActionDialog(
      initial: initial,
      taskTitle: taskTitle,
      editingExistingAction: editingExistingAction,
    ),
  );
}
