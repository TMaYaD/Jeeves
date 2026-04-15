import 'package:flutter/material.dart';

import '../database/gtd_database.dart' show Todo;

/// Picker for selecting a blocking task.
class BlockedByPickerWidget extends StatelessWidget {
  const BlockedByPickerWidget({
    super.key,
    required this.potentialBlockers,
    required this.currentBlockerId,
    required this.onChanged,
  });

  final List<Todo> potentialBlockers;
  final String? currentBlockerId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String?>(
      decoration: const InputDecoration(
        labelText: 'Blocked by',
        prefixIcon: Icon(Icons.lock_outline),
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      initialValue: currentBlockerId,
      items: [
        const DropdownMenuItem<String?>(
          value: null,
          child: Text('None'),
        ),
        for (final t in potentialBlockers)
          DropdownMenuItem<String?>(
            value: t.id,
            child: Text(
              t.title,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}
