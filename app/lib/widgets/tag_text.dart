/// Shared tag renderer: plain text, `@`-prefixed, colored with the tag's
/// stored color (or a deterministic palette fallback when color is null).
///
/// This is the single source-of-truth for how a tag looks across the app —
/// nav drawer, task detail, list items, clarify flow, etc.  No background,
/// no border, no chip shape — except a selected tag, which renders as a
/// badge (see `docs/DESIGN.md` § Tag cloud).
library;

import 'package:flutter/material.dart';

import '../database/gtd_database.dart';
import '../utils/tag_colors.dart';

/// Renders [tag] as `@name` text in the tag's stored color.
///
/// [selected] renders the tag as a badge: the same text at weight 700 on a
/// tinted background, and no ✓ prefix.  [trailingCount] appends ` (n)` when
/// non-null and > 0.  [onDismiss] adds a small × hit-target to the right.
/// [onTap] / [onLongPress] wire up gesture handling.
class TagText extends StatelessWidget {
  const TagText({
    super.key,
    required this.tag,
    this.selected = false,
    this.trailingCount,
    this.fontSize = 13,
    this.fontWeight = FontWeight.w600,
    this.onTap,
    this.onLongPress,
    this.onDismiss,
  });

  final Tag tag;
  final bool selected;
  final int? trailingCount;
  final double fontSize;
  final FontWeight fontWeight;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final color = resolvedTagColor(name: tag.name, storedHex: tag.color);
    final effectiveWeight = selected ? FontWeight.w700 : fontWeight;

    final label = StringBuffer();
    label.write('@${tag.name}');
    if (trailingCount != null && trailingCount! > 0) {
      label.write(' ($trailingCount)');
    }

    Widget content = Text(
      label.toString(),
      style: TextStyle(fontSize: fontSize, fontWeight: effectiveWeight, color: color),
    );

    if (selected) {
      content = Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
        ),
        child: content,
      );
    }

    if (onDismiss != null) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          content,
          const SizedBox(width: 2),
          GestureDetector(
            onTap: onDismiss,
            child: Icon(Icons.close, size: 12, color: color),
          ),
        ],
      );
    }

    if (onTap != null || onLongPress != null) {
      content = GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: content,
      );
    }

    if (selected) {
      content = Semantics(selected: true, child: content);
    }

    return content;
  }
}
