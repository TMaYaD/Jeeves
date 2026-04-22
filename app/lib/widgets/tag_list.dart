/// Collection renderer for tags — the only permitted way to display a list
/// of tags in the app.  Every tag is rendered exclusively via [TagText].
library;

import 'package:flutter/material.dart';

import '../database/gtd_database.dart';
import 'tag_text.dart';

/// Renders [tags] as a [Wrap] of [TagText] widgets.
///
/// All interaction (tap, long-press, dismiss) is forwarded to the tag-level
/// callbacks so call-sites never construct chip widgets directly.
class TagList extends StatelessWidget {
  const TagList({
    super.key,
    required this.tags,
    this.selectedIds = const {},
    this.counts,
    this.onTap,
    this.onLongPress,
    this.onDismiss,
    this.trailing,
    this.spacing = 6,
    this.runSpacing = 4,
  });

  final List<Tag> tags;

  /// IDs of tags to render in selected state (✓ prefix + bold).
  final Set<String> selectedIds;

  /// Optional per-tag count displayed as ` (n)` suffix when > 0.
  final Map<String, int>? counts;

  final void Function(Tag tag)? onTap;
  final void Function(Tag tag)? onLongPress;

  /// When provided, each tag renders a × dismiss button.
  final void Function(Tag tag)? onDismiss;

  /// Optional widget appended after all tag items (e.g. an add button).
  final Widget? trailing;

  final double spacing;
  final double runSpacing;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: spacing,
      runSpacing: runSpacing,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final tag in tags)
          TagText(
            key: Key('tag_chip_${tag.id}'),
            tag: tag,
            selected: selectedIds.contains(tag.id),
            trailingCount: counts?[tag.id],
            onTap: onTap != null ? () => onTap!(tag) : null,
            onLongPress: onLongPress != null ? () => onLongPress!(tag) : null,
            onDismiss: onDismiss != null ? () => onDismiss!(tag) : null,
          ),
        ?trailing,
      ],
    );
  }
}
