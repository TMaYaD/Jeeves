import 'package:flutter/material.dart';

/// Colour of the capacity-bar segment representing minutes counted at the
/// configurable default estimate (selected Outcomes that carry no time
/// estimate). Tailwind blue-300 — the literal "lighter blue" ruled on #463,
/// same family as the Daily Planning accent (`#2563EB`, blue-600).
///
/// NOTE (pending owner decision): the ruling contrasts a "standard tone" with
/// this lighter blue, but the standard tone here is the load-status colour
/// (green/amber/red), never blue — so on amber/red days this segment reads as a
/// distinct hue marking provenance rather than status. The owner may instead
/// prefer a lighter *tint of the current status colour*; that is a one-constant
/// change confined to this value. The literal blue is the ruled default.
const kDefaultCountedFillColor = Color(0xFF93C5FD);

/// Capacity progress bar with a two-tone fill.
///
/// Real-estimate minutes render in the load-status tone (green ≤ 0.8, amber
/// ≤ 1.0, red over — keyed off the *combined* ratio so the warn/over
/// thresholds are unchanged), and default-counted minutes render as a lighter
/// blue segment ([kDefaultCountedFillColor]) laid immediately after them. When
/// there are no default-counted minutes the bar is pixel-identical to a single
/// status-tone fill over the track. `LinearProgressIndicator` cannot paint two
/// segments, so the fill is drawn directly while the geometry — 10px height,
/// 4px clip, `#E5E7EB` track — is preserved exactly.
class CapacityBar extends StatelessWidget {
  const CapacityBar({
    required this.realMinutes,
    required this.defaultMinutes,
    required this.availableMinutes,
  });

  final int realMinutes;
  final int defaultMinutes;
  final int availableMinutes;

  @override
  Widget build(BuildContext context) {
    final combinedRatio = availableMinutes > 0
        ? (realMinutes + defaultMinutes) / availableMinutes
        : double.infinity;

    final Color statusColor;
    if (combinedRatio <= 0.8) {
      statusColor = const Color(0xFF16A34A);
    } else if (combinedRatio <= 1.0) {
      statusColor = const Color(0xFFF59E0B);
    } else {
      statusColor = const Color(0xFFDC2626);
    }

    // Fractional widths within the track. The real segment takes precedence;
    // the default segment fills whatever remains up to a full bar.
    double fraction(int minutes) => availableMinutes > 0
        ? minutes / availableMinutes
        : (minutes > 0 ? 1.0 : 0.0);
    final realFraction = fraction(realMinutes).clamp(0.0, 1.0);
    final defaultFraction =
        fraction(defaultMinutes).clamp(0.0, 1.0 - realFraction);

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 10,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Stack(
              children: [
                const Positioned.fill(
                  child: ColoredBox(color: Color(0xFFE5E7EB)),
                ),
                Row(
                  children: [
                    Container(
                      key: const Key('capacity_real_segment'),
                      width: width * realFraction,
                      color: statusColor,
                    ),
                    if (defaultFraction > 0)
                      Container(
                        key: const Key('capacity_default_segment'),
                        width: width * defaultFraction,
                        color: kDefaultCountedFillColor,
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
