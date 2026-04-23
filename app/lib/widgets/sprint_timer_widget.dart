import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/sprint_timer_provider.dart';

/// Compact sprint timer panel shown at the top of Focus Mode.
///
/// Displays a progress ring, countdown, sprint number, and controls.
class SprintTimerWidget extends ConsumerWidget {
  const SprintTimerWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timer = ref.watch(sprintTimerProvider);

    if (!timer.isActive) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: timer.isBreak
            ? const Color(0xFFECFDF5)
            : const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: timer.isBreak
              ? const Color(0xFF6EE7B7)
              : const Color(0xFFBFDBFE),
        ),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _ProgressRing(timer: timer),
              const SizedBox(width: 20),
              Expanded(
                child: _TimerInfo(timer: timer),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Controls(timer: timer),
        ],
      ),
    );
  }
}

class _ProgressRing extends StatelessWidget {
  const _ProgressRing({required this.timer});
  final SprintTimerState timer;

  @override
  Widget build(BuildContext context) {
    final color = timer.isBreak
        ? const Color(0xFF10B981)
        : const Color(0xFF2563EB);
    final bgColor = timer.isBreak
        ? const Color(0xFFD1FAE5)
        : const Color(0xFFDBEAFE);

    final minutes = timer.remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = timer.remaining.inSeconds.remainder(60).toString().padLeft(2, '0');

    return SizedBox(
      width: 88,
      height: 88,
      child: CustomPaint(
        painter: _RingPainter(
          progress: timer.progress,
          ringColor: color,
          trackColor: bgColor,
        ),
        child: Center(
          child: Text(
            '$minutes:$seconds',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: color,
              letterSpacing: -0.5,
            ),
          ),
        ),
      ),
    );
  }
}

class _TimerInfo extends StatelessWidget {
  const _TimerInfo({required this.timer});
  final SprintTimerState timer;

  @override
  Widget build(BuildContext context) {
    final phaseLabel = timer.isBreak ? 'Break' : 'Focus Sprint';
    final phaseColor = timer.isBreak
        ? const Color(0xFF059669)
        : const Color(0xFF2563EB);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: phaseColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                phaseLabel,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: phaseColor,
                ),
              ),
            ),
            if (!timer.isBreak && timer.totalSprints > 1) ...[
              const SizedBox(width: 8),
              Text(
                'Sprint ${timer.sprintNumber} of ${timer.totalSprints}',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF6B7280),
                ),
              ),
            ],
          ],
        ),
        if (timer.activeTaskTitle != null) ...[
          const SizedBox(height: 6),
          Text(
            timer.activeTaskTitle!,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1A1A2E),
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (!timer.isBreak && timer.totalSprints > 1) ...[
          const SizedBox(height: 8),
          _SprintDots(
            total: timer.totalSprints,
            current: timer.sprintNumber,
          ),
        ],
      ],
    );
  }
}

class _SprintDots extends StatelessWidget {
  const _SprintDots({required this.total, required this.current});
  final int total;
  final int current;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(total, (i) {
        final done = i < current - 1;
        final active = i == current - 1;
        return Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(right: 4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done
                ? const Color(0xFF2563EB)
                : active
                    ? const Color(0xFF93C5FD)
                    : const Color(0xFFDBEAFE),
          ),
        );
      }),
    );
  }
}

class _Controls extends ConsumerWidget {
  const _Controls({required this.timer});
  final SprintTimerState timer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(sprintTimerProvider.notifier);
    final disabled = timer.isProcessing;

    if (timer.isBreak) {
      return Row(
        children: [
          Expanded(
            child: FilledButton(
              onPressed: disabled ? null : notifier.skipBreak,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                minimumSize: const Size.fromHeight(40),
              ),
              child: const Text('Skip Break',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        // Pause / Resume
        Tooltip(
          message: timer.isPaused ? 'Resume sprint' : 'Pause sprint',
          child: OutlinedButton(
            onPressed: disabled
                ? null
                : (timer.isPaused ? notifier.resumeSprint : notifier.pauseSprint),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF2563EB),
              side: const BorderSide(color: Color(0xFFBFDBFE)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              minimumSize: const Size(44, 40),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            child: Icon(
              timer.isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
              size: 20,
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Complete
        Expanded(
          child: FilledButton(
            onPressed: disabled ? null : notifier.completeSprint,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              minimumSize: const Size.fromHeight(40),
            ),
            child: const Text('Done',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(width: 8),
        // Stop
        Tooltip(
          message: 'Stop sprint',
          child: OutlinedButton(
            onPressed: disabled ? null : notifier.stopSprint,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF6B7280),
              side: const BorderSide(color: Color(0xFFE5E7EB)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              minimumSize: const Size(44, 40),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            child: const Icon(Icons.stop_rounded, size: 20),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Custom painter for the progress ring
// ---------------------------------------------------------------------------

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.progress,
    required this.ringColor,
    required this.trackColor,
  });

  final double progress;
  final Color ringColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide / 2) - 6;
    const strokeWidth = 7.0;
    const startAngle = -math.pi / 2;

    // Track (background arc).
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      0,
      math.pi * 2,
      false,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );

    // Progress arc.
    if (progress > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        math.pi * 2 * progress,
        false,
        Paint()
          ..color = ringColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.ringColor != ringColor ||
      old.trackColor != trackColor;
}
