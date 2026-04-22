import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/gtd_database.dart' show Tag;
import '../../providers/tag_filter_provider.dart';
import '../../providers/tags_provider.dart';
import '../../widgets/tag_list.dart';
import 'tag_management_sheet.dart';

/// Interactive tag cloud rendered in the navigation drawer.
///
/// Tapping a tag toggles it in the sticky [tagFilterProvider] filter;
/// long-pressing opens [TagManagementSheet].  Tags with active tasks show a
/// count suffix; tags with no active tasks are hidden unless selected.
class TagCloud extends ConsumerWidget {
  const TagCloud({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tagsAsync = ref.watch(contextTagsWithCountProvider);
    final selectedIds = ref.watch(tagFilterProvider);
    final notifier = ref.read(tagFilterProvider.notifier);

    return tagsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, s) => const SizedBox.shrink(),
      data: (tagsWithCount) {
        final visible = tagsWithCount
            .where((t) => t.count > 0 || selectedIds.contains(t.tag.id))
            .toList();

        if (visible.isEmpty && selectedIds.isEmpty) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selectedIds.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: TextButton(
                    key: const Key('tag_cloud_clear_filters'),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: notifier.clear,
                    child: const Text(
                      'Clear filters',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF6B7280),
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
              TagList(
                tags: visible.map((t) => t.tag).toList(),
                selectedIds: selectedIds,
                counts: {for (final t in visible) t.tag.id: t.count},
                onTap: (tag) => notifier.toggle(tag.id),
                onLongPress: (tag) => _openManagement(context, ref, tag),
              ),
            ],
          ),
        );
      },
    );
  }

  void _openManagement(BuildContext context, WidgetRef ref, Tag tag) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => TagManagementSheet(tag: tag),
    );
  }
}
