import 'package:flutter/material.dart';

import '../../providers/gtd_lists_provider.dart';
import '../common/gtd_list_screen.dart';

/// The Trash record surface: all Outcomes with `intent = 'trash'`,
/// newest-trashed first (issue #408).
///
/// Rows navigate to task detail, where the status sheet offers restore to
/// Next or Someday/Maybe. There is deliberately no purge action — rows
/// persist; Intent expresses the discard stance (CONTEXT.md § Trash).
class TrashScreen extends StatelessWidget {
  const TrashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GtdListScreen(
      title: 'Trash',
      provider: trashProvider,
      showFilterBar: false,
      emptyIcon: Icons.delete_outline,
      emptyTitle: 'Trash is empty',
      emptySubtitle:
          'Discarded Outcomes land here — nothing is ever deleted.',
    );
  }
}
