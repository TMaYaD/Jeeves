import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/tags_provider.dart';
import '../../widgets/app_title_bar/app_title_bar.dart';
import '../../widgets/capture/capture_action.dart';
import '../common/tag_management_sheet.dart';

/// The three kinds of entry the user can manage from Settings. Each maps to a
/// `tags.type` value: Tags are `context` rows, Projects `project`, People
/// `person`.
enum TagManagementKind {
  tags(
    type: 'context',
    routePath: '/manage/tags',
    title: 'Tags',
    emptyText: 'No tags yet.',
  ),
  projects(
    type: 'project',
    routePath: '/manage/projects',
    title: 'Projects',
    emptyText: 'No projects yet.',
  ),
  people(
    type: 'person',
    routePath: '/manage/people',
    title: 'People',
    emptyText: 'No people yet.',
  );

  const TagManagementKind({
    required this.type,
    required this.routePath,
    required this.title,
    required this.emptyText,
  });

  final String type;
  final String routePath;
  final String title;
  final String emptyText;
}

/// A list of every entry of one [TagManagementKind], each with its active
/// Outcome count. Tapping a row opens [TagManagementSheet] — rename, merge into
/// another entry of the same kind, or delete.
class TagManagementScreen extends ConsumerWidget {
  const TagManagementScreen({super.key, required this.kind});

  final TagManagementKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(tagsWithCountByTypeProvider(kind.type));
    return Scaffold(
      appBar: AppTitleBar(
        title: kind.title,
        pinnedAction: captureAction(context),
      ),
      backgroundColor: Colors.white,
      body: entries.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(child: Text('Could not load ${kind.title.toLowerCase()}')),
        data: (rows) {
          if (rows.isEmpty) {
            return Center(
              child: Text(
                kind.emptyText,
                key: const Key('tag_management_empty'),
                style: const TextStyle(color: Color(0xFF9CA3AF)),
              ),
            );
          }
          return ListView.builder(
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final row = rows[i];
              return ListTile(
                key: Key('tag_management_row_${row.tag.id}'),
                title: Text(
                  row.tag.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w500, color: Color(0xFF374151)),
                ),
                trailing: Text(
                  '${row.count}',
                  style: const TextStyle(color: Color(0xFF9CA3AF)),
                ),
                onTap: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  shape: const RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(16)),
                  ),
                  builder: (_) => TagManagementSheet(tag: row.tag),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
