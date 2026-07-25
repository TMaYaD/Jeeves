import 'package:flutter/material.dart';

import '../../providers/gtd_lists_provider.dart';
import '../common/gtd_list_screen.dart';

class NextScreen extends StatelessWidget {
  const NextScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GtdListScreen(
      provider: nextProvider,
      emptyIcon: Icons.task_alt,
      emptyTitle: 'No next actions',
      emptySubtitle: 'Clarify an inbox item to add one.',
    );
  }
}
