/// Step 4 of the daily planning ritual: summary and commit.
///
/// Shows:
/// - An editable "available time" field (defaults to 480 min / 8 h).
/// - The full list of tasks selected for today with their estimates.
/// - A colour-coded capacity bar (green ≤ 80 %, amber ≤ 100 %, red > 100 %).
/// - An over-capacity warning with a "Review Selections" back-link.
/// - A "Start Day" button that finalises the plan and unlocks execution.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../providers/daily_planning_provider.dart';

class PlanSummaryStep extends ConsumerStatefulWidget {
  const PlanSummaryStep({super.key});

  @override
  ConsumerState<PlanSummaryStep> createState() => _PlanSummaryStepState();
}

class _PlanSummaryStepState extends ConsumerState<PlanSummaryStep> {
  late TextEditingController _hoursCtrl;
  late TextEditingController _minutesCtrl;

  @override
  void initState() {
    super.initState();
    final available =
        ref.read(dailyPlanningProvider).availableMinutes;
    _hoursCtrl =
        TextEditingController(text: (available ~/ 60).toString());
    _minutesCtrl =
        TextEditingController(text: (available % 60).toString());
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
    // Both fields empty / zero — preserve the current provider value rather
    // than clamping 0 to 1 which would be unintended.
    if (totalMinutes == 0) return;
    ref
        .read(dailyPlanningProvider.notifier)
        .setAvailableTime(totalMinutes.clamp(1, 1440));
  }

  @override
  Widget build(BuildContext context) {
    final planningState = ref.watch(dailyPlanningProvider);
    final availableMinutes = planningState.availableMinutes;
    final asyncSelected = ref.watch(todaySelectedTasksProvider);

    return asyncSelected.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (tasks) {
        final totalMinutes =
            tasks.fold<int>(0, (sum, t) => sum + (t.timeEstimate ?? 0));
        final ratio = availableMinutes > 0
            ? totalMinutes / availableMinutes
            : double.infinity;
        final overCapacity = ratio > 1.0;

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // --- Available time ---
            _SectionLabel('Available time today'),
            const SizedBox(height: 8),
            _AvailableTimeRow(
              hoursCtrl: _hoursCtrl,
              minutesCtrl: _minutesCtrl,
              onChanged: _onTimeChanged,
            ),
            const SizedBox(height: 20),

            // --- Capacity bar ---
            _SectionLabel('Capacity'),
            const SizedBox(height: 8),
            _CapacityBar(ratio: ratio.clamp(0.0, 2.0)),
            const SizedBox(height: 6),
            Text(
              _capacitySummary(tasks.length, totalMinutes),
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
            if (overCapacity) ...[
              const SizedBox(height: 10),
              _OverCapacityWarning(
                onReview: () =>
                    ref.read(dailyPlanningProvider.notifier).goToStep(0),
              ),
            ],
            const SizedBox(height: 20),

            // --- Task list ---
            _SectionLabel('Selected tasks (${tasks.length})'),
            const SizedBox(height: 8),
            if (tasks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No tasks selected — go back and select some!',
                  style: TextStyle(fontSize: 14, color: Colors.grey[400]),
                  textAlign: TextAlign.center,
                ),
              )
            else
              ...tasks.map((t) => _SelectedTaskRow(todo: t)),

            const SizedBox(height: 28),

            // --- Start Day button ---
            FilledButton(
              onPressed: () => _startDay(context),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text(
                'Start Day',
                style:
                    TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _startDay(BuildContext context) async {
    await ref.read(dailyPlanningProvider.notifier).startDay();
    if (!mounted) return;
    // ignore: use_build_context_synchronously
    context.go('/next-actions');
  }

  String _capacitySummary(int count, int totalMinutes) {
    final h = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    final timeStr = h > 0 ? '${h}h ${m}m' : '${m}m';
    return '$count task${count == 1 ? '' : 's'} · $timeStr planned';
  }
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
        color: Color(0xFF9CA3AF),
      ),
    );
  }
}

class _AvailableTimeRow extends StatelessWidget {
  const _AvailableTimeRow({
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
              _MaxValueFormatter(24),
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
        Text('available',
            style: TextStyle(fontSize: 14, color: Colors.grey[500])),
      ],
    );
  }
}

class _CapacityBar extends StatelessWidget {
  const _CapacityBar({required this.ratio});

  final double ratio;

  @override
  Widget build(BuildContext context) {
    final Color barColor;
    if (ratio <= 0.8) {
      barColor = const Color(0xFF16A34A);
    } else if (ratio <= 1.0) {
      barColor = const Color(0xFFF59E0B);
    } else {
      barColor = const Color(0xFFDC2626);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: ratio.clamp(0.0, 1.0),
        minHeight: 10,
        backgroundColor: const Color(0xFFE5E7EB),
        valueColor: AlwaysStoppedAnimation<Color>(barColor),
      ),
    );
  }
}

class _OverCapacityWarning extends StatelessWidget {
  const _OverCapacityWarning({required this.onReview});
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFCA5A5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Color(0xFFDC2626), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'You\'re over capacity. Consider deferring some tasks.',
              style: const TextStyle(
                  fontSize: 13, color: Color(0xFFB91C1C)),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onReview,
            style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFDC2626),
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            child: const Text('Review',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

class _SelectedTaskRow extends StatelessWidget {
  const _SelectedTaskRow({required this.todo});
  final Todo todo;

  @override
  Widget build(BuildContext context) {
    final estimate = todo.timeEstimate;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline,
              size: 18, color: Color(0xFF16A34A)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              todo.title,
              style: const TextStyle(
                  fontSize: 14, color: Color(0xFF1A1A2E)),
            ),
          ),
          if (estimate != null)
            Text(
              estimate < 60 ? '${estimate}m' : '${estimate ~/ 60}h',
              style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[500],
                  fontWeight: FontWeight.w500),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Input formatter helpers
// ---------------------------------------------------------------------------

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
