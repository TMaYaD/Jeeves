import 'package:flutter/material.dart';

import '../../providers/gtd_lists_provider.dart';
import '../common/gtd_list_screen.dart';

/// The Done record surface: completed, non-trashed Outcomes, most recently
/// completed first (issue #408).
///
/// Completed-then-trashed Outcomes surface in Trash instead — Done and
/// Trash are disjoint (CONTEXT.md § Done).
class DoneScreen extends StatelessWidget {
  const DoneScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GtdListScreen(
      title: 'Done',
      provider: doneProvider,
      showFilterBar: false,
      emptyIcon: Icons.task_alt,
      emptyTitle: 'Nothing in Done',
      emptySubtitle: 'Completed Outcomes appear here.',
    );
  }
}
