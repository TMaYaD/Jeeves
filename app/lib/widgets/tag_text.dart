/// Shared tag renderer: plain text, `@`-prefixed, colored with the tag's
/// stored color (or a deterministic palette fallback when color is null).
///
/// This is the single source-of-truth for how a tag looks across the app —
/// nav drawer, task detail, list items, clarify flow, etc.  No background,
/// no border, no chip shape.
library;

import 'package:flutter/material.dart';

import '../database/gtd_database.dart';
import '../utils/tag_colors.dart';

/// Renders [tag] as `@name` text in the tag's stored color.
///
/// [fontSize] and [fontWeight] can be tuned per call-site but the color
/// is always derived from [tag.color] (falling back to the palette).
class TagText extends StatelessWidget {
  const TagText({
    super.key,
    required this.tag,
    this.fontSize = 13,
    this.fontWeight = FontWeight.w600,
  });

  final Tag tag;
  final double fontSize;
  final FontWeight fontWeight;

  @override
  Widget build(BuildContext context) {
    final color = resolvedTagColor(name: tag.name, storedHex: tag.color);
    return Text(
      '@${tag.name}',
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
      ),
    );
  }
}
