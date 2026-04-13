import 'package:flutter/material.dart';

/// Indicator shown in the AppBar when the device is offline.
class OfflineChip extends StatelessWidget {
  const OfflineChip({super.key});

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: const Icon(Icons.cloud_off_outlined, size: 16),
      label: const Text('Offline'),
      backgroundColor: Theme.of(context).colorScheme.errorContainer,
      labelStyle: TextStyle(
        color: Theme.of(context).colorScheme.onErrorContainer,
        fontSize: 12,
      ),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }
}
