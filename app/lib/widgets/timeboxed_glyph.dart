/// The Timeboxed glyph: a clock standing on a hard line.
///
/// An estimate that is a limit is not a guess, and the line under the clock
/// is the whole of the difference. Drawn rather than taken from the icon
/// font, because no stock glyph carries that line — and the line is the
/// meaning, not the decoration.
library;

import 'package:flutter/material.dart';

/// The mark of a Timeboxed Action: the estimate, with a limit under it.
class TimeboxedGlyph extends StatelessWidget {
  const TimeboxedGlyph({
    super.key,
    this.size = 12,
    this.color,
    this.semanticLabel = 'Timeboxed',
  });

  /// The width and the clock's diameter, in logical pixels.
  final double size;

  /// The ink. The estimate chip's own colour by default.
  final Color? color;

  /// What a screen reader is told. Null says nothing.
  ///
  /// The mark is drawn, so without a label it is invisible to anyone who
  /// cannot see it — and "the estimate is a limit" is the whole of what the
  /// mark means.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? const Color(0xFF2563EB);
    final mark = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.timer_outlined, size: size, color: ink),
        Container(
          width: size,
          height: 2,
          decoration: BoxDecoration(color: ink),
        ),
      ],
    );
    final label = semanticLabel;
    if (label == null) return mark;
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: mark,
    );
  }
}
