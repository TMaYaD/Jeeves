import 'package:flutter/material.dart';

import '../../providers/gtd_lists_provider.dart';
import '../common/gtd_list_screen.dart';

class SomedayMaybeScreen extends StatelessWidget {
  const SomedayMaybeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GtdListScreen(
      provider: maybeProvider,
      emptyIcon: Icons.bedtime_outlined,
      emptyTitle: 'Nothing in Maybe',
      emptySubtitle: 'Park ideas you might revisit later here.',
    );
  }
}
