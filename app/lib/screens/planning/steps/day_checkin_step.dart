/// Step 1 of the daily planning ritual: Day Check-in.
///
/// Two questions before queueing work:
/// - "How are you feeling today?" — energy level selector (low / medium / high).
/// - "How much time do you have today?" — hours + minutes input.
///
/// Both fields are optional; the Next button is always enabled for this step.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/daily_planning_provider.dart';

class DayCheckinStep extends ConsumerStatefulWidget {
  const DayCheckinStep({super.key});

  @override
  ConsumerState<DayCheckinStep> createState() => _DayCheckinStepState();
}

class _DayCheckinStepState extends ConsumerState<DayCheckinStep> {
  late TextEditingController _hoursCtrl;
  late TextEditingController _minutesCtrl;

  @override
  void initState() {
    super.initState();
    final available = ref.read(dailyPlanningProvider).availableMinutes;
    _hoursCtrl = TextEditingController(text: (available ~/ 60).toString());
    _minutesCtrl = TextEditingController(text: (available % 60).toString());
  }

  @override
  void dispose() {
    _hoursCtrl.dispose();
    _minutesCtrl.dispose();
    super.dispose();
  }

  void _onTimeChanged() {
    final h = int.tryParse(_hoursCtrl.text) ?? 0;
    final m = int.tryParse(_minutesCtrl.text) ?? 0;
    final totalMinutes = h * 60 + m;
    if (totalMinutes == 0) return;
    ref
        .read(dailyPlanningProvider.notifier)
        .setAvailableTime(totalMinutes.clamp(1, 1440));
  }

  @override
  Widget build(BuildContext context) {
    final energyLevel =
        ref.watch(dailyPlanningProvider.select((s) => s.energyLevel));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      children: [
        // --- Energy level ---
        _SectionHeader('How are you feeling today?'),
        const SizedBox(height: 4),
        Text(
          'This helps prioritise tasks that match your energy.',
          style: TextStyle(fontSize: 13, color: Colors.grey[500]),
        ),
        const SizedBox(height: 16),
        _EnergyLevelPicker(
          selected: energyLevel,
          onSelect: (level) =>
              ref.read(dailyPlanningProvider.notifier).setEnergyLevel(level),
        ),

        const SizedBox(height: 36),
        const Divider(height: 1, color: Color(0xFFF3F4F6)),
        const SizedBox(height: 36),

        // --- Available time ---
        _SectionHeader('How much time do you have today?'),
        const SizedBox(height: 4),
        Text(
          'We\'ll warn you if your plan exceeds this.',
          style: TextStyle(fontSize: 13, color: Colors.grey[500]),
        ),
        const SizedBox(height: 16),
        _TimeInputRow(
          hoursCtrl: _hoursCtrl,
          minutesCtrl: _minutesCtrl,
          onChanged: _onTimeChanged,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------

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

class _TimeInputRow extends StatelessWidget {
  const _TimeInputRow({
    required this.hoursCtrl,
    required this.minutesCtrl,
    required this.onChanged,
  });

  final TextEditingController hoursCtrl;
  final TextEditingController minutesCtrl;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final inputDeco = InputDecoration(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      isDense: true,
    );

    return Row(
      children: [
        SizedBox(
          width: 72,
          child: TextField(
            controller: hoursCtrl,
            decoration: inputDeco.copyWith(suffixText: 'h'),
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              _MaxValueFormatter(23),
            ],
            onChanged: (_) => onChanged(),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 72,
          child: TextField(
            controller: minutesCtrl,
            decoration: inputDeco.copyWith(suffixText: 'm'),
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              _MaxValueFormatter(59),
            ],
            onChanged: (_) => onChanged(),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          'available today',
          style: TextStyle(fontSize: 14, color: Colors.grey[500]),
        ),
      ],
    );
  }
}

class _MaxValueFormatter extends TextInputFormatter {
  const _MaxValueFormatter(this.max);
  final int max;

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue old, TextEditingValue current) {
    if (current.text.isEmpty) return current;
    final value = int.tryParse(current.text);
    if (value == null || value > max) return old;
    return current;
  }
}
