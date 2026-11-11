import 'package:flutter/material.dart';

import 'meta_chip.dart';

/// Compact Outcome representation. Surfaces own routing and actions; the row
/// owns the layout and the gesture covering its read-only attributes.
class OutcomeRow extends StatelessWidget {
  const OutcomeRow({
    super.key,
    required this.title,
    this.leading,
    this.secondary,
    this.meta,
    this.trailing,
    this.energyLevel,
    this.timeEstimateMinutes,
    this.timeLoggedMinutes,
    this.dueDate,
    this.muted = false,
    this.struck = false,
    this.framed = false,
    this.titleStyle,
    this.backgroundColor,
    this.borderColor,
    this.onTap,
    this.onLongPress,
  });

  final String title;
  final Widget? leading;
  final Widget? secondary;
  final Widget? meta;
  final Widget? trailing;
  final String? energyLevel;
  final int? timeEstimateMinutes;
  final int? timeLoggedMinutes;
  final DateTime? dueDate;
  final bool muted;
  final bool struck;
  final bool framed;
  final TextStyle? titleStyle;
  final Color? backgroundColor;
  final Color? borderColor;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final hasMeta =
        meta != null ||
        energyLevel != null ||
        timeEstimateMinutes != null ||
        timeLoggedMinutes != null ||
        dueDate != null;
    final end =
        trailing ??
        (onTap == null
            ? null
            : const Icon(Icons.chevron_right, color: Color(0xFF9CA3AF)));
    final titleTextStyle =
        const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: Color(0xFF1A1A2E),
            )
            .merge(titleStyle)
            .copyWith(
              color: muted || struck
                  ? const Color(0xFF9CA3AF)
                  : titleStyle?.color,
              decoration: struck
                  ? TextDecoration.lineThrough
                  : titleStyle?.decoration,
            );
    Widget content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 12)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: titleTextStyle),
                    if (secondary != null) ...[
                      const SizedBox(height: 4),
                      secondary!,
                    ],
                  ],
                ),
              ),
              if (end != null) ...[const SizedBox(width: 8), end],
            ],
          ),
          if (hasMeta) ...[
            const SizedBox(height: 4),
            meta ??
                OutcomeMetaLine(
                  energyLevel: energyLevel,
                  timeEstimateMinutes: timeEstimateMinutes,
                  timeLoggedMinutes: timeLoggedMinutes,
                  dueDate: dueDate,
                ),
          ],
        ],
      ),
    );
    if (onTap != null) {
      content = InkWell(onTap: onTap, onLongPress: onLongPress, child: content);
    } else if (onLongPress != null) {
      content = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: onLongPress,
        child: content,
      );
    }
    if (!framed) {
      return Material(type: MaterialType.transparency, child: content);
    }
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: backgroundColor ?? Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderColor ?? const Color(0xFFE5E7EB)),
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }
}
