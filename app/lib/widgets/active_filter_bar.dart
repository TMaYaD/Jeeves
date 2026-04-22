/// Shared active-filter strip shown below screen headers when a tag filter
/// is active.  Displays each selected tag as a dismissible [TagText] with a
/// "Clear all" link; renders nothing when the filter set is empty.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/tag_filter_provider.dart';
import '../providers/tags_provider.dart';
import 'tag_list.dart';

class ActiveFilterBar extends ConsumerWidget {
  const ActiveFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedIds = ref.watch(tagFilterProvider);
    if (selectedIds.isEmpty) return const SizedBox.shrink();

    final notifier = ref.read(tagFilterProvider.notifier);
    final allTags = ref.watch(contextTagsProvider).asData?.value ?? [];
    final selectedTags =
        allTags.where((t) => selectedIds.contains(t.id)).toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFF3F4F6))),
      ),
      child: TagList(
        tags: selectedTags,
        onDismiss: (tag) => notifier.toggle(tag.id),
        trailing: GestureDetector(
          key: const Key('active_filter_clear_all'),
          onTap: notifier.clear,
          child: const Text(
            'Clear all',
            style: TextStyle(
              fontSize: 11,
              color: Color(0xFF9CA3AF),
              decoration: TextDecoration.underline,
              decorationColor: Color(0xFF9CA3AF),
            ),
          ),
        ),
      ),
    );
  }
}
