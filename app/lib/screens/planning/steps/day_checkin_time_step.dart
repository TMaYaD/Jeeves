library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/focus_session_planning_provider.dart';

class DayCheckinTimeStep extends ConsumerStatefulWidget {
  const DayCheckinTimeStep({super.key});

  @override
  ConsumerState<DayCheckinTimeStep> createState() => _DayCheckinTimeStepState();
}

class _DayCheckinTimeStepState extends ConsumerState<DayCheckinTimeStep> {
  late TextEditingController _hoursCtrl;
  late TextEditingController _minutesCtrl;

  @override
  void initState() {
    super.initState();
    final available = ref.read(focusSessionPlanningProvider).availableMinutes;
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
        .read(focusSessionPlanningProvider.notifier)
        .setAvailableTime(totalMinutes.clamp(1, 1440));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      children: [
        // --- Today's Calendar Agenda Placeholder ---
        const Text(
          "Today's Agenda",
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1A2E),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.grey[50],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey[200]!),
          ),
           child: const Center(
            child: Text(
               "Calendar events placeholder",
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ),
        const SizedBox(height: 36),
        const Divider(height: 1, color: Color(0xFFF3F4F6)),
        const SizedBox(height: 36),

        // --- Available time ---
        const Text(
          'How much time do you have today?',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1A2E),
          ),
        ),
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
