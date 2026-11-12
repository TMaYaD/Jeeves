import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'meta_chip.dart';

/// Editable Outcome metadata in energy, estimate, logged time, due order.
/// Unset editable values retain their prompts; optional logged time is read-only.
class OutcomeAttributeStrip extends StatelessWidget {
  const OutcomeAttributeStrip({
    super.key,
    this.energyLevel,
    this.timeEstimateMinutes,
    this.timeLoggedMinutes,
    this.dueDate,
    required this.onEnergyTap,
    required this.onEstimateTap,
    required this.onDueTap,
    required this.onClearDue,
    this.keyPrefix = 'outcome_attribute',
  });

  final String? energyLevel;
  final int? timeEstimateMinutes;
  final AsyncValue<int>? timeLoggedMinutes;
  final DateTime? dueDate;
  final VoidCallback onEnergyTap;
  final VoidCallback onEstimateTap;
  final VoidCallback onDueTap;
  final VoidCallback onClearDue;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      _TapChip(
        key: Key('${keyPrefix}_energy'),
        onTap: onEnergyTap,
        child: MetaChip(
          icon: Icons.bolt_outlined,
          label: energyLevel != null
              ? energyLevelLabel(energyLevel!)
              : 'Energy',
          color: energyLevel != null
              ? const Color(0xFF7C3AED)
              : const Color(0xFF9CA3AF),
        ),
      ),
      _TapChip(
        key: Key('${keyPrefix}_time'),
        onTap: onEstimateTap,
        child: MetaChip(
          icon: Icons.timer_outlined,
          label: timeEstimateMinutes != null
              ? formatMinutesLabel(timeEstimateMinutes!)
              : 'Time',
          color: timeEstimateMinutes != null
              ? const Color(0xFF2563EB)
              : const Color(0xFF9CA3AF),
        ),
      ),
      if (timeLoggedMinutes != null) _TimeLoggedChip(value: timeLoggedMinutes!),
      _TapChip(
        key: Key('${keyPrefix}_due'),
        onTap: onDueTap,
        child: MetaChip(
          icon: Icons.event_outlined,
          label: dueDate != null ? formatDueDateLabel(dueDate!) : 'Due',
          color: dueDate != null
              ? const Color(0xFFDC2626)
              : const Color(0xFF9CA3AF),
        ),
      ),
      if (dueDate != null)
        InkResponse(
          key: Key('${keyPrefix}_due_clear'),
          onTap: onClearDue,
          radius: 16,
          child: const Tooltip(
            message: 'Clear date',
            child: Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close, size: 16, color: Color(0xFF9CA3AF)),
            ),
          ),
        ),
    ],
  );
}

class _TapChip extends StatelessWidget {
  const _TapChip({super.key, required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: child,
    );
  }
}

/// The time-logged chip. Renders a subtle placeholder while the one-shot read
/// resolves; `0` shows as "no time logged yet".
class _TimeLoggedChip extends StatelessWidget {
  const _TimeLoggedChip({required this.value});

  final AsyncValue<int> value;

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFF16A34A);
    final label = value.when(
      data: (minutes) =>
          minutes <= 0 ? 'No time logged yet' : formatMinutesLabel(minutes),
      loading: () => '…',
      error: (_, _) => '—',
    );
    return MetaChip(
      icon: Icons.history_toggle_off_outlined,
      label: label,
      color: color,
    );
  }
}
