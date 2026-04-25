library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/focus_session_planning_provider.dart';

class DayCheckinEnergyStep extends ConsumerWidget {
  const DayCheckinEnergyStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final energyLevel = ref.watch(focusSessionPlanningProvider.select((s) => s.energyLevel));

    return ListView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      children: [
        // --- Energy level ---
        const _SectionHeader('How are you feeling today?'),
        const SizedBox(height: 4),
        Text(
          'This helps prioritise tasks that match your energy.',
          style: TextStyle(fontSize: 13, color: Colors.grey[500]),
        ),
        const SizedBox(height: 16),
        _EnergyLevelPicker(
          selected: energyLevel,
          onSelect: (level) =>
              ref.read(focusSessionPlanningProvider.notifier).setEnergyLevel(level),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: Color(0xFF1A1A2E),
      ),
    );
  }
}

class _EnergyLevelPicker extends StatelessWidget {
  const _EnergyLevelPicker({
    required this.selected,
    required this.onSelect,
  });

  final String? selected;
  final void Function(String) onSelect;

  static const _levels = [
    (
      value: 'low',
      label: 'Low',
      emoji: '🌱',
      desc: 'Routine, admin work',
      color: Color(0xFF16A34A),
    ),
    (
      value: 'medium',
      label: 'Medium',
      emoji: '⚡',
      desc: 'Focused work',
      color: Color(0xFFF59E0B),
    ),
    (
      value: 'high',
      label: 'High',
      emoji: '🔥',
      desc: 'Deep thinking, creative work',
      color: Color(0xFFDC2626),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: _levels.map((level) {
        final isSelected = selected == level.value;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GestureDetector(
            onTap: () => onSelect(level.value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: isSelected
                    ? level.color.withValues(alpha: 0.08)
                    : Colors.transparent,
                border: Border.all(
                  color: isSelected
                      ? level.color
                      : const Color(0xFFE5E7EB),
                  width: isSelected ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                   Text(level.emoji, style: const TextStyle(fontSize: 22)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          level.label,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: isSelected
                                ? level.color
                                : const Color(0xFF374151),
                          ),
                        ),
                         Text(
                          level.desc,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[500],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isSelected)
                    Icon(Icons.check_circle,
                        color: level.color, size: 20),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
