library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/evening_shutdown_provider.dart';

/// Step 2 of the shutdown ritual: daily summary stats and "Close Day".
///
/// Displays completion counts, total focus time, and estimation accuracy so
/// the user can reflect on the day before finalising. The "Close Day" button
/// persists completion state and triggers [onCloseDay].
class ShutdownSummaryStep extends ConsumerWidget {
  const ShutdownSummaryStep({super.key, required this.onCloseDay});

  final VoidCallback onCloseDay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncCompleted = ref.watch(completedTodayProvider);

    if (asyncCompleted.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (asyncCompleted.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
              const SizedBox(height: 16),
              const Text(
                'Could not load today\'s summary',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                asyncCompleted.error.toString(),
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final completed = asyncCompleted.asData!.value;
    final totalEstimated =
        completed.fold<int>(0, (sum, t) => sum + (t.timeEstimate ?? 0));
    final totalActual =
        completed.fold<int>(0, (sum, t) => sum + t.timeSpentMinutes);
    final accuracy = totalEstimated > 0
        ? (totalActual / totalEstimated * 100).round()
        : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('TODAY\'S SUMMARY'),
          const SizedBox(height: 16),
          _StatsCard(
            completedCount: completed.length,
            totalEstimated: totalEstimated,
            totalActual: totalActual,
            accuracy: accuracy,
          ),
          const SizedBox(height: 32),
          _CloseDayButton(
            onTap: () async {
              await ref.read(eveningShutdownProvider.notifier).closeDay();
              if (context.mounted) onCloseDay();
            },
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'Tomorrow starts fresh — rolled-over tasks are already queued.',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[400],
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({
    required this.completedCount,
    required this.totalEstimated,
    required this.totalActual,
    required this.accuracy,
  });

  final int completedCount;
  final int totalEstimated;
  final int totalActual;
  final int? accuracy;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(16),
        border: const Border.fromBorderSide(
          BorderSide(color: Color(0xFFE5E7EB)),
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          _StatRow(
            icon: Icons.check_circle_outline,
            iconColor: const Color(0xFF16A34A),
            label: 'Tasks completed',
            value: '$completedCount',
          ),
          const Divider(height: 24, color: Color(0xFFF3F4F6)),
          _StatRow(
            icon: Icons.timer_outlined,
            iconColor: const Color(0xFF2563EB),
            label: 'Total estimated',
            value: _fmt(totalEstimated),
          ),
          const SizedBox(height: 12),
          _StatRow(
            icon: Icons.access_time,
            iconColor: const Color(0xFF7C3AED),
            label: 'Total actual',
            value: _fmt(totalActual),
          ),
          if (accuracy != null) ...[
            const Divider(height: 24, color: Color(0xFFF3F4F6)),
            _StatRow(
              icon: Icons.insights,
              iconColor: _accuracyColor(accuracy!),
              label: 'Estimation accuracy',
              value: '$accuracy%',
              valueColor: _accuracyColor(accuracy!),
            ),
            const SizedBox(height: 8),
            _AccuracyBar(accuracy: accuracy!),
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

  String _fmt(int m) {
    if (m == 0) return '—';
    if (m < 60) return '${m}m';
    if (m % 60 == 0) return '${m ~/ 60}h';
    return '${m ~/ 60}h ${m % 60}m';
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    this.valueColor = const Color(0xFF1A1A2E),
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: iconColor),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              color: Color(0xFF4B5563),
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}

class _AccuracyBar extends StatelessWidget {
  const _AccuracyBar({required this.accuracy});

  final int accuracy;

  @override
  Widget build(BuildContext context) {
    final clamped = (accuracy / 200).clamp(0.0, 1.0);
    final Color barColor;
    if (accuracy >= 80 && accuracy <= 120) {
      barColor = const Color(0xFF16A34A);
    } else if (accuracy >= 60 && accuracy <= 140) {
      barColor = const Color(0xFFF59E0B);
    } else {
      barColor = const Color(0xFFDC2626);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: clamped,
            minHeight: 8,
            backgroundColor: const Color(0xFFE5E7EB),
            valueColor: AlwaysStoppedAnimation<Color>(barColor),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          accuracy >= 80 && accuracy <= 120
              ? 'Great estimation accuracy!'
              : accuracy > 120
                  ? 'Tasks took longer than estimated.'
                  : 'Tasks were completed faster than estimated.',
          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
        ),
      ],
    );
  }
}

class _CloseDayButton extends StatelessWidget {
  const _CloseDayButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.nightlight_round, size: 20),
        label: const Text(
          'Close Day',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF1E3A5F),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
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
