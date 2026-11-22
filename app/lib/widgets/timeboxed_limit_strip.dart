/// The strip that states a Timeboxed limit that has been passed (issue #923).
///
/// Red is the right colour here and not a flourish: red means "a limit has
/// been passed" (docs/DESIGN.md § Colour Palette), and this strip says
/// exactly that. Amber is spent on three other things, and none of them is
/// this, so the strip is red-bordered on a red tint.
library;

import 'package:flutter/material.dart';

/// The red limit strip: how far past the limit, and what it means.
class TimeboxedLimitStrip extends StatelessWidget {
  const TimeboxedLimitStrip({
    super.key,
    required this.headline,
    required this.detail,
  });

  /// The bold line — how far past the limit, or what has happened.
  final String headline;

  /// The quieter line under it; may be empty.
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFDEAEA),
        border: Border.all(color: const Color(0xFFDC2626)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Icons.error_outline,
              size: 16,
              color: Color(0xFFDC2626),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  headline,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFDC2626),
                    height: 1.3,
                  ),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF4A5568),
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
