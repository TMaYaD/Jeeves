/// Modal dialog for capturing or editing a Todo's `next_action_text`.
///
/// Returns the trimmed text via `Navigator.pop`; the caller decides what to do
/// with it (write to the DB, leave the cursor, etc.). Returns `null` on cancel.
library;

import 'package:flutter/material.dart';

class NextActionDialog extends StatefulWidget {
  const NextActionDialog({
    super.key,
    required this.initial,
    required this.taskTitle,
  });

  final String initial;
  final String taskTitle;

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
      title: Text(widget.initial.isEmpty ? 'Set next action' : 'Update next action'),
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
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => NextActionDialog(initial: initial, taskTitle: taskTitle),
  );
}
