import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../models/focus_settings.dart';
import '../providers/focus_settings_provider.dart';
import '../providers/sprint_timer_provider.dart';

/// Full-page sprint timer for the Active Focus carousel (slide left from notes).
///
/// When idle: shows a "Start Sprint" button with configured durations.
/// When active: shows a progress ring, countdown, phase badge, and controls.
class SprintTimerWidget extends ConsumerWidget {
  const SprintTimerWidget({super.key, required this.todo});

  final Todo todo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timer = ref.watch(sprintTimerProvider);
    final settings = ref.watch(focusSettingsProvider);

    if (!timer.isActive) {
      return _IdleView(todo: todo, settings: settings);
    }

    final color =
        timer.isBreak ? const Color(0xFF10B981) : const Color(0xFF2563EB);
    final bgColor =
        timer.isBreak ? const Color(0xFFECFDF5) : const Color(0xFFEFF6FF);
    final borderColor =
        timer.isBreak ? const Color(0xFF6EE7B7) : const Color(0xFFBFDBFE);

    return Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _ProgressRing(timer: timer, color: color),
          const SizedBox(height: 24),
          _TimerInfo(timer: timer),
          const SizedBox(height: 28),
          _Controls(timer: timer),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Idle view — shown when no sprint is active
// ---------------------------------------------------------------------------

class _IdleView extends ConsumerWidget {
  const _IdleView({required this.todo, required this.settings});
  final Todo todo;
  final FocusSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(sprintTimerProvider.notifier);
    final isProcessing = ref.watch(sprintTimerProvider).isProcessing;

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.timer_outlined,
              size: 64, color: Color(0xFF2563EB)),
          const SizedBox(height: 16),
          const Text(
            'Sprint Timer',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Focus for ${settings.sprintDurationMinutes} min, '
            'then take a ${settings.breakDurationMinutes} min break.',
            style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: isProcessing ? null : () => notifier.startSprint(todo),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              minimumSize: const Size(200, 48),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              textStyle: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600),
            ),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Start Sprint'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Progress ring
// ---------------------------------------------------------------------------

class _ProgressRing extends StatelessWidget {
  const _ProgressRing({required this.timer, required this.color});
  final SprintTimerState timer;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final bgColor = timer.isBreak
        ? const Color(0xFFD1FAE5)
        : const Color(0xFFDBEAFE);

    final minutes =
        timer.remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds =
        timer.remaining.inSeconds.remainder(60).toString().padLeft(2, '0');

    return SizedBox(
      width: 120,
      height: 120,
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
              fontSize: 26,
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

// ---------------------------------------------------------------------------
// Timer info (phase badge, task title, sprint dots)
// ---------------------------------------------------------------------------

class _TimerInfo extends StatelessWidget {
  const _TimerInfo({required this.timer});
  final SprintTimerState timer;

  @override
  Widget build(BuildContext context) {
    final phaseLabel = timer.isBreak ? 'Break' : 'Focus Sprint';
    final phaseColor =
        timer.isBreak ? const Color(0xFF059669) : const Color(0xFF2563EB);

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: phaseColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                phaseLabel,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: phaseColor,
                ),
              ),
            ),
            if (!timer.isBreak && timer.totalSprints > 1) ...[
              const SizedBox(width: 10),
              Text(
                'Sprint ${timer.sprintNumber} of ${timer.totalSprints}',
                style: const TextStyle(
                    fontSize: 13, color: Color(0xFF6B7280)),
              ),
            ],
          ],
        ),
        if (timer.activeTaskTitle != null) ...[
          const SizedBox(height: 10),
          Text(
            timer.activeTaskTitle!,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1A1A2E),
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (!timer.isBreak && timer.totalSprints > 1) ...[
          const SizedBox(height: 12),
          _SprintDots(
              total: timer.totalSprints, current: timer.sprintNumber),
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
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (i) {
        final done = i < current - 1;
        final active = i == current - 1;
        return Container(
          width: 9,
          height: 9,
          margin: const EdgeInsets.symmetric(horizontal: 3),
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

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

class _Controls extends ConsumerWidget {
  const _Controls({required this.timer});
  final SprintTimerState timer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(sprintTimerProvider.notifier);
    final disabled = timer.isProcessing;

    if (timer.isBreak) {
      return FilledButton(
        onPressed: disabled ? null : notifier.skipBreak,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF10B981),
          minimumSize: const Size(double.infinity, 44),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: const Text('Skip Break',
            style: TextStyle(fontWeight: FontWeight.w600)),
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
                : (timer.isPaused
                    ? notifier.resumeSprint
                    : notifier.pauseSprint),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF2563EB),
              side: const BorderSide(color: Color(0xFFBFDBFE)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              minimumSize: const Size(48, 44),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            child: Icon(
              timer.isPaused
                  ? Icons.play_arrow_rounded
                  : Icons.pause_rounded,
              size: 22,
            ),
          ),
        ),
        const SizedBox(width: 10),
        // Complete
        Expanded(
          child: FilledButton(
            onPressed: disabled ? null : notifier.completeSprint,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Done',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(width: 10),
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
              minimumSize: const Size(48, 44),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            child: const Icon(Icons.stop_rounded, size: 22),
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
    final radius = (size.shortestSide / 2) - 7;
    const strokeWidth = 8.0;
    const startAngle = -math.pi / 2;

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
