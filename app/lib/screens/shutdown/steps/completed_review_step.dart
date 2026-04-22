library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/evening_shutdown_provider.dart';

/// Step 0 of the shutdown ritual: review tasks completed today.
///
/// Shows each completed task alongside its time estimate and actual time spent,
/// letting the user reflect on the day's work before proceeding.
class CompletedReviewStep extends ConsumerWidget {
  const CompletedReviewStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncCompleted = ref.watch(completedTodayProvider);

    if (asyncCompleted.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final completed = asyncCompleted.asData?.value ?? [];

    if (completed.isEmpty) {
      return const _EmptyCompleted();
    }

    final totalEstimated =
        completed.fold<int>(0, (sum, t) => sum + (t.timeEstimate ?? 0));
    final totalActual =
        completed.fold<int>(0, (sum, t) => sum + t.timeSpentMinutes);

    return Column(
      children: [
        _SummaryBar(
          completedCount: completed.length,
          totalEstimated: totalEstimated,
          totalActual: totalActual,
        ),
        const Divider(height: 1, color: Color(0xFFF3F4F6)),
        Expanded(
          child: ScrollConfiguration(
            behavior:
                ScrollConfiguration.of(context).copyWith(overscroll: false),
            child: ListView(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _SectionLabel(
                    'COMPLETED TODAY (${completed.length})'),
                const SizedBox(height: 8),
                ...completed.map((t) => _CompletedTaskCard(todo: t)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyCompleted extends StatelessWidget {
  const _EmptyCompleted();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                size: 56, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              'No completed tasks today',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.grey[500],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tasks you complete during the day will appear here.',
              style: TextStyle(fontSize: 13, color: Colors.grey[400]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryBar extends StatelessWidget {
  const _SummaryBar({
    required this.completedCount,
    required this.totalEstimated,
    required this.totalActual,
  });

  final int completedCount;
  final int totalEstimated;
  final int totalActual;

  @override
  Widget build(BuildContext context) {
    final accuracy = totalEstimated > 0
        ? (totalActual / totalEstimated * 100).round()
        : null;

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          _StatChip(
            label: 'Done',
            value: '$completedCount',
            color: const Color(0xFF16A34A),
          ),
          const SizedBox(width: 12),
          _StatChip(
            label: 'Estimated',
            value: _fmtMinutes(totalEstimated),
            color: const Color(0xFF2563EB),
          ),
          const SizedBox(width: 12),
          _StatChip(
            label: 'Actual',
            value: _fmtMinutes(totalActual),
            color: const Color(0xFF7C3AED),
          ),
          if (accuracy != null) ...[
            const SizedBox(width: 12),
            _StatChip(
              label: 'Accuracy',
              value: '$accuracy%',
              color: _accuracyColor(accuracy),
            ),
          ],
        ],
      ),
    );
  }

  Color _accuracyColor(int accuracy) {
    if (accuracy >= 80 && accuracy <= 120) return const Color(0xFF16A34A);
    if (accuracy >= 60 && accuracy <= 140) return const Color(0xFFF59E0B);
    return const Color(0xFFDC2626);
  }

  String _fmtMinutes(int m) {
    if (m == 0) return '—';
    if (m < 60) return '${m}m';
    if (m % 60 == 0) return '${m ~/ 60}h';
    return '${m ~/ 60}h ${m % 60}m';
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip(
      {required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.8,
            color: Color(0xFF9CA3AF),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _CompletedTaskCard extends StatelessWidget {
  const _CompletedTaskCard({required this.todo});

  final Todo todo;

  @override
  Widget build(BuildContext context) {
    final estimated = todo.timeEstimate;
    final actual = todo.timeSpentMinutes;
    final hasTimeData = estimated != null || actual > 0;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFD1FAE5)),
      ),
      color: const Color(0xFFF0FDF4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.check_circle,
                size: 20, color: Color(0xFF16A34A)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    todo.title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  if (hasTimeData) ...[
                    const SizedBox(height: 4),
                    _TimeComparison(
                        estimated: estimated, actual: actual),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeComparison extends StatelessWidget {
  const _TimeComparison({required this.estimated, required this.actual});

  final int? estimated;
  final int actual;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      children: [
        if (estimated != null)
          _TimeChip(
            icon: Icons.timer_outlined,
            label: 'Est ${_fmt(estimated!)}',
            color: const Color(0xFF2563EB),
          ),
        if (actual > 0)
          _TimeChip(
            icon: Icons.access_time,
            label: 'Actual ${_fmt(actual)}',
            color: _actualColor(estimated, actual),
          ),
      ],
    );
  }

  Color _actualColor(int? estimated, int actual) {
    if (estimated == null || estimated == 0) return const Color(0xFF7C3AED);
    final ratio = actual / estimated;
    if (ratio <= 1.2) return const Color(0xFF16A34A);
    if (ratio <= 1.5) return const Color(0xFFF59E0B);
    return const Color(0xFFDC2626);
  }

  String _fmt(int m) {
    if (m < 60) return '${m}m';
    if (m % 60 == 0) return '${m ~/ 60}h';
    return '${m ~/ 60}h ${m % 60}m';
  }
}

class _TimeChip extends StatelessWidget {
  const _TimeChip(
      {required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(
              fontSize: 12, color: color, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
        color: Color(0xFF9CA3AF),
      ),
    );
  }
}
