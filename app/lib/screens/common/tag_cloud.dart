import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/gtd_database.dart' show Tag;
import '../../providers/tag_filter_provider.dart';
import '../../providers/tags_provider.dart';
import 'tag_management_sheet.dart';

/// Interactive tag cloud rendered in the navigation drawer.
///
/// Each chip shows the tag name and its active-task count.  Chip size and
/// opacity scale linearly with the count relative to the maximum in the set,
/// so high-use tags stand out visually.  Tapping a chip toggles it in the
/// sticky [tagFilterProvider] filter; long-pressing opens [TagManagementSheet].
class TagCloud extends ConsumerWidget {
  const TagCloud({super.key});

  static const double _minFontSize = 11.0;
  static const double _maxFontSize = 16.0;
  static const double _minOpacity = 0.55;
  static const double _maxOpacity = 1.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tagsAsync = ref.watch(contextTagsWithCountProvider);
    final selectedIds = ref.watch(tagFilterProvider);
    final notifier = ref.read(tagFilterProvider.notifier);

    return tagsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, s) => const SizedBox.shrink(),
      data: (tagsWithCount) {
        // Show tags that have active tasks OR are currently selected (so a
        // selected tag doesn't vanish when all its tasks are completed).
        final visible = tagsWithCount
            .where((t) => t.count > 0 || selectedIds.contains(t.tag.id))
            .toList();

        if (visible.isEmpty) return const SizedBox.shrink();

        final maxCount =
            visible.map((t) => t.count).reduce(max).clamp(1, 1 << 30);

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
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: visible.map((twc) {
                  final isSelected = selectedIds.contains(twc.tag.id);
                  final weight = twc.count / maxCount;
                  final fontSize =
                      _minFontSize + weight * (_maxFontSize - _minFontSize);
                  final opacity =
                      isSelected ? 1.0 : _minOpacity + weight * (_maxOpacity - _minOpacity);

                  return Opacity(
                    opacity: opacity,
                    child: GestureDetector(
                      onLongPress: () =>
                          _openManagement(context, ref, twc.tag),
                      child: FilterChip(
                        key: Key('tag_chip_${twc.tag.id}'),
                        label: Text(
                          twc.count > 0
                              ? '${twc.tag.name} (${twc.count})'
                              : twc.tag.name,
                          style: TextStyle(fontSize: fontSize),
                        ),
                        selected: isSelected,
                        onSelected: (_) => notifier.toggle(twc.tag.id),
                        selectedColor: const Color(0xFFDBEAFE),
                        checkmarkColor: const Color(0xFF1D4ED8),
                        side: BorderSide(
                          color: isSelected
                              ? const Color(0xFF1D4ED8)
                              : const Color(0xFFD1D5DB),
                        ),
                        labelStyle: TextStyle(
                          color: isSelected
                              ? const Color(0xFF1D4ED8)
                              : const Color(0xFF374151),
                          fontSize: fontSize,
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 0),
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  );
                }).toList(),
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
