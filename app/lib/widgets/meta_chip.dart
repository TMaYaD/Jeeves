import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// User-facing label for an energy level. Falls back to the raw value so an
/// unknown level from a newer client renders as itself rather than vanishing.
String energyLevelLabel(String level) => switch (level) {
  'low' => 'Low',
  'medium' => 'Medium',
  'high' => 'High',
  _ => level,
};

/// User-facing label for a duration in minutes: `45m`, `2h`, `1h 30m`.
String formatMinutesLabel(int minutes) {
  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  if (hours == 0) return '${remainder}m';
  if (remainder == 0) return '${hours}h';
  return '${hours}h ${remainder}m';
}

/// The due date's local calendar day, in the shared display format.
String formatDueDateLabel(DateTime dueDate) =>
    DateFormat('MMM d, y').format(dueDate.toLocal());

/// Read-only Outcome attributes in energy, estimate, logged, due order.
/// Omit an attribute by leaving its value null; zero is a present duration.
class OutcomeMetaLine extends StatelessWidget {
  const OutcomeMetaLine({
    super.key,
    this.energyLevel,
    this.timeEstimateMinutes,
    this.timeLoggedMinutes,
    this.dueDate,
  });

  final String? energyLevel;
  final int? timeEstimateMinutes;
  final int? timeLoggedMinutes;
  final DateTime? dueDate;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      if (energyLevel != null)
        MetaChip(
          icon: Icons.bolt_outlined,
          label: energyLevelLabel(energyLevel!),
          color: const Color(0xFF7C3AED),
        ),
      if (timeEstimateMinutes != null)
        MetaChip(
          icon: Icons.timer_outlined,
          label: formatMinutesLabel(timeEstimateMinutes!),
          color: const Color(0xFF2563EB),
        ),
      if (timeLoggedMinutes != null)
        MetaChip(
          icon: Icons.history_toggle_off_outlined,
          label: formatMinutesLabel(timeLoggedMinutes!),
          color: const Color(0xFF16A34A),
        ),
      if (dueDate != null)
        MetaChip(
          icon: Icons.event_outlined,
          label: formatDueDateLabel(dueDate!),
          color: const Color(0xFFDC2626),
        ),
    ],
  );
}

/// A small read-only attribute chip: an icon, a label, and a tinted background
/// in the attribute's colour.
///
/// **Read-only by construction.** It contains no [GestureDetector], [InkWell],
/// [IconButton] or [TextField], so a chip can never become an accidental tap
/// target. Surfaces that want the chip to be tappable put the gesture on an
/// *ancestor* covering the whole row, which is what keeps the affordance
/// obvious — the row is the target, not the chip.
///
/// Used by the Outcome peek sheet's attribute strip and the Plan section's
/// planned rows.
class MetaChip extends StatelessWidget {
  const MetaChip({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        // Chips sit at 4px on the canonical 2/4/6 scale (DESIGN.md §Roundedness).
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
