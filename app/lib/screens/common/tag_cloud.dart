import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/daos/tag_dao.dart' show TagWithCount;
import '../../database/gtd_database.dart' show Tag;
import '../../providers/tag_filter_provider.dart';
import '../../providers/tags_provider.dart';
import '../../widgets/tag_list.dart';
import 'tag_management_sheet.dart';

/// Number of tags the collapsed cloud shows (selected tags are never hidden).
const int tagCloudCollapsedCap = 12;

/// What [organiseTagCloud] decided to render.
class TagCloudLayout {
  const TagCloudLayout({
    required this.visibleTags,
    required this.hiddenTagCount,
    required this.offerFindField,
    required this.fontSizes,
  });

  final List<TagWithCount> visibleTags;
  final int hiddenTagCount;
  final bool offerFindField;
  final Map<String, double> fontSizes;
}

/// Orders, filters and sizes the drawer tag cloud.
///
/// Selected tags come first, then the rest by active count (highest first),
/// ties by name ignoring case. A non-empty [query] (case-insensitive, leading
/// `@` ignored) lifts the cap. Font size steps 15 / 13 / 12 sp by count
/// relative to the busiest visible tag.
TagCloudLayout organiseTagCloud({
  required List<TagWithCount> tags,
  required Set<String> selectedIds,
  required String query,
  required bool expanded,
  int cap = tagCloudCollapsedCap,
}) {
  final eligible = tags
      .where((t) => t.count > 0 || selectedIds.contains(t.tag.id))
      .toList()
    ..sort((a, b) {
      final aSelected = selectedIds.contains(a.tag.id);
      final bSelected = selectedIds.contains(b.tag.id);
      if (aSelected != bSelected) return aSelected ? -1 : 1;
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      return a.tag.name.toLowerCase().compareTo(b.tag.name.toLowerCase());
    });

  final needle = query.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
  final searching = needle.isNotEmpty;
  final matching = searching
      ? eligible
          .where((t) => t.tag.name.toLowerCase().contains(needle))
          .toList()
      : eligible;

  final selectedCount =
      eligible.where((t) => selectedIds.contains(t.tag.id)).length;
  final limit = searching || expanded
      ? matching.length
      : (selectedCount > cap ? selectedCount : cap);
  final visible = matching.take(limit).toList();

  final maxCount =
      visible.fold<int>(0, (m, t) => t.count > m ? t.count : m);
  double sizeFor(int count) {
    if (maxCount == 0 || count == 0) return 12;
    final ratio = count / maxCount;
    if (ratio >= 2 / 3) return 15;
    if (ratio >= 1 / 3) return 13;
    return 12;
  }

  return TagCloudLayout(
    visibleTags: visible,
    hiddenTagCount: matching.length - visible.length,
    offerFindField: eligible.length > cap,
    fontSizes: {for (final t in visible) t.tag.id: sizeFor(t.count)},
  );
}

/// Interactive tag cloud rendered in the navigation drawer.
///
/// Tapping a tag toggles it in the sticky [tagFilterProvider] filter;
/// long-pressing opens [TagManagementSheet].  Tags with active tasks show a
/// count suffix; tags with no active tasks are hidden unless selected.
class TagCloud extends ConsumerStatefulWidget {
  const TagCloud({super.key});

  @override
  ConsumerState<TagCloud> createState() => _TagCloudState();
}

class _TagCloudState extends ConsumerState<TagCloud> {
  final _queryController = TextEditingController();
  bool _expanded = false;

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tagsAsync = ref.watch(contextTagsWithCountProvider);
    final selectedIds = ref.watch(tagFilterProvider);
    final notifier = ref.read(tagFilterProvider.notifier);

    return tagsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, s) => const SizedBox.shrink(),
      data: (tagsWithCount) {
        final query = _queryController.text;
        final layout = organiseTagCloud(
          tags: tagsWithCount,
          selectedIds: selectedIds,
          query: query,
          expanded: _expanded,
        );
        final visible = layout.visibleTags;
        final searching = query.trim().replaceFirst('@', '').isNotEmpty;
        const mutedStyle = TextStyle(
          fontSize: 11,
          color: Color(0xFF6B7280),
        );

        if (tagsWithCount.every(
                (t) => t.count == 0 && !selectedIds.contains(t.tag.id)) &&
            selectedIds.isEmpty) {
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
              if (layout.offerFindField)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    key: const Key('tag_cloud_find_field'),
                    controller: _queryController,
                    style: const TextStyle(fontSize: 13),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Find…',
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 16),
                      suffixIcon: query.isEmpty
                          ? null
                          : IconButton(
                              key: const Key('tag_cloud_find_clear'),
                              icon: const Icon(Icons.close, size: 16),
                              onPressed: () => setState(_queryController.clear),
                            ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              TagList(
                tags: visible.map((t) => t.tag).toList(),
                selectedIds: selectedIds,
                counts: {for (final t in visible) t.tag.id: t.count},
                fontSizes: layout.fontSizes,
                spacing: 12,
                runSpacing: 8,
                onTap: (tag) => notifier.toggle(tag.id),
                onLongPress: (tag) => _openManagement(context, ref, tag),
              ),
              if (searching && visible.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'No matches',
                    key: Key('tag_cloud_no_matches'),
                    style: mutedStyle,
                  ),
                )
              else if (!searching &&
                  (layout.hiddenTagCount > 0 || _expanded) &&
                  layout.offerFindField)
                TextButton(
                  key: const Key('tag_cloud_show_more'),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(
                    _expanded
                        ? 'Show fewer'
                        : 'Show ${layout.hiddenTagCount} more',
                    style: mutedStyle,
                  ),
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
