import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/gtd_lists_provider.dart';
import '../../providers/tags_provider.dart';
import '../common/gtd_list_screen.dart';

/// A Project's page: every active Outcome tagged with the Project, whatever
/// its Intent (issue #703). Reached from the drawer's PROJECTS section.
///
/// When the Project is merged away or deleted — here or on another device —
/// the page leaves for Next Actions rather than render an empty list under a
/// blank title.
class ProjectScreen extends ConsumerWidget {
  const ProjectScreen({super.key, required this.projectTagId});

  final String projectTagId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectTagsProvider).asData?.value;
    if (projects != null && !projects.any((t) => t.id == projectTagId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go('/next-actions');
      });
    }
    return GtdListScreen(
      provider: projectOutcomesProvider(projectTagId),
      showFilterBar: false,
      emptyIcon: Icons.folder_outlined,
      emptyTitle: 'No Outcomes in this project',
      emptySubtitle: 'Tag an Outcome with this project to see it here.',
    );
  }
}
