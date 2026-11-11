import 'package:flutter/material.dart';

import '../../providers/gtd_lists_provider.dart';
import '../common/gtd_list_screen.dart';

/// A Project's page: every active Outcome tagged with the Project, whatever
/// its Intent (issue #703). Reached from the drawer's PROJECTS section.
class ProjectScreen extends StatelessWidget {
  const ProjectScreen({super.key, required this.projectTagId});

  final String projectTagId;

  @override
  Widget build(BuildContext context) {
    return GtdListScreen(
      provider: projectOutcomesProvider(projectTagId),
      showFilterBar: false,
      emptyIcon: Icons.folder_outlined,
      emptyTitle: 'No Outcomes in this project',
      emptySubtitle: 'Tag an Outcome with this project to see it here.',
    );
  }
}
