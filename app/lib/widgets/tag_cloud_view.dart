import 'package:flutter/material.dart';

import '../database/gtd_database.dart' show Tag;
import '../database/daos/tag_dao.dart' show TagWithCount;
import 'tag_list.dart';

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

/// Cleans a find query for matching: trims, drops one leading `@`, trims again
/// (so `@ Home` matches `home`), lower-cases. Shares [typedTagName] with the
/// creation path so the Add offer and the created name can never disagree.
String cleanTagCloudQuery(String query) => typedTagName(query).toLowerCase();

/// The name a user typed, trimmed with one leading `@` removed, casing kept.
String typedTagName(String query) =>
    query.trim().replaceFirst(RegExp(r'^@'), '').trim();

/// Orders, filters and sizes a tag cloud.
///
/// Selected tags come first, then the rest by active count (highest first),
/// ties by name ignoring case. A non-empty [query] (case-insensitive, leading
/// `@` ignored) lifts the cap. Font size steps 15 / 13 / 12 sp by count
/// relative to the busiest visible tag. Tags with no active count are dropped
/// unless selected, or unless [includeUnusedTags] is set.
TagCloudLayout organiseTagCloud({
  required List<TagWithCount> tags,
  required Set<String> selectedIds,
  required String query,
  required bool expanded,
  int cap = tagCloudCollapsedCap,
  bool includeUnusedTags = false,
}) {
  final eligible = tags
      .where((t) =>
          includeUnusedTags || t.count > 0 || selectedIds.contains(t.tag.id))
      .toList()
    ..sort((a, b) {
      final aSelected = selectedIds.contains(a.tag.id);
      final bSelected = selectedIds.contains(b.tag.id);
      if (aSelected != bSelected) return aSelected ? -1 : 1;
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      return a.tag.name.toLowerCase().compareTo(b.tag.name.toLowerCase());
    });

  final needle = cleanTagCloudQuery(query);
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

/// Presentational tag cloud shared by the navigation drawer and the Outcome
/// context-tag editor. Owns the find query and the show-more state; takes its
/// data and callbacks from the host and reads no providers.
class TagCloudView extends StatefulWidget {
  const TagCloudView({
    super.key,
    required this.tags,
    required this.selectedIds,
    this.onTap,
    this.onLongPress,
    this.includeUnusedTags = false,
    this.alwaysOfferFindField = false,
    this.onCreateTag,
  });

  final List<TagWithCount> tags;
  final Set<String> selectedIds;
  final void Function(Tag tag)? onTap;
  final void Function(Tag tag)? onLongPress;

  /// Show tags no active Outcome carries (the editor needs them; the drawer
  /// filter does not).
  final bool includeUnusedTags;

  /// Show `Find…` even when the cloud fits under the cap.
  final bool alwaysOfferFindField;

  /// When set, a search naming no existing tag offers `Add "<name>"`, which
  /// calls this. Null keeps a plain "No matches".
  final Future<void> Function(String name)? onCreateTag;

  @override
  State<TagCloudView> createState() => _TagCloudViewState();
}

class _TagCloudViewState extends State<TagCloudView> {
  final _queryController = TextEditingController();
  bool _expanded = false;
  bool _creating = false;

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _queryController.text;
    final layout = organiseTagCloud(
      tags: widget.tags,
      selectedIds: widget.selectedIds,
      query: query,
      expanded: _expanded,
      includeUnusedTags: widget.includeUnusedTags,
    );
    final visible = layout.visibleTags;
    final needle = cleanTagCloudQuery(query);
    final searching = needle.isNotEmpty;
    final offerFind = layout.offerFindField || widget.alwaysOfferFindField;
    final canAdd = widget.onCreateTag != null &&
        searching &&
        !widget.tags.any((t) => t.tag.name.toLowerCase() == needle);
    const mutedStyle = TextStyle(fontSize: 11, color: Color(0xFF6B7280));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (offerFind)
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
          selectedIds: widget.selectedIds,
          counts: {for (final t in visible) t.tag.id: t.count},
          fontSizes: layout.fontSizes,
          spacing: 12,
          runSpacing: 8,
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
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
            offerFind)
          TextButton(
            key: const Key('tag_cloud_show_more'),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => setState(() => _expanded = !_expanded),
            child: Text(
              _expanded ? 'Show fewer' : 'Show ${layout.hiddenTagCount} more',
              style: mutedStyle,
            ),
          ),
        if (canAdd)
          TextButton.icon(
            key: const Key('tag_cloud_add_tag'),
            onPressed: _creating ? null : () => _create(typedTagName(query)),
            icon: const Icon(Icons.add, size: 18),
            label: Text('Add "${typedTagName(query)}"'),
          ),
      ],
    );
  }

  Future<void> _create(String name) async {
    if (_creating || name.isEmpty) return;
    setState(() => _creating = true);
    try {
      await widget.onCreateTag!(name);
      if (!mounted) return;
      setState(_queryController.clear);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Failed to create tag. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }
}
