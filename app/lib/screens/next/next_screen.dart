import 'package:flutter/material.dart';

import '../../providers/gtd_lists_provider.dart';
import '../../widgets/location_unknown_line.dart';
import '../common/gtd_list_screen.dart';

class NextScreen extends StatelessWidget {
  const NextScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GtdListScreen(
      provider: nextProvider,
      emptyIcon: Icons.task_alt,
      emptyTitle: 'Nothing on Next',
      emptySubtitle: 'Clarify an inbox item to add one.',
      // Each row names the Place its Outcome is at, and the list says so
      // when Jeeves does not know where the user is (issue #55).
      showPlaceName: true,
      header: const LocationUnknownLine(),
    );
  }
}
