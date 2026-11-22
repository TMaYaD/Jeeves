/// The Sprint ring and its dots — shared by the Outcome Focus screen and the
/// Focus screen of a Habit. Moved out of `active_focus_screen.dart` unchanged
/// (only made public), so both screens draw the same ring.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../providers/sprint_timer_provider.dart';
import '../models/timeboxed.dart';

// ---------------------------------------------------------------------------
// Sprint ring — countdown (full→empty) or overtime (empty→full, amber→red)
// ---------------------------------------------------------------------------

class SprintRing extends StatefulWidget {
  const SprintRing({
    super.key,
    required this.timer,
    required this.size,
    required this.color,
    this.onPhaseSkip,
  });
  final SprintTimerState timer;
  final double size;
  final Color color;
  final VoidCallback? onPhaseSkip;

  @override
  State<SprintRing> createState() => SprintRingState();
}

class SprintRingState extends State<SprintRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _syncPulse();
  }

  @override
  void didUpdateWidget(SprintRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  void _syncPulse() {
    final suggest = widget.timer.isNearPhaseEnd;
    if (suggest && !_pulseCtrl.isAnimating) {
      _pulseCtrl.repeat();
    } else if (!suggest && _pulseCtrl.isAnimating) {
      _pulseCtrl.stop();
      _pulseCtrl.reset();
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool overtime = widget.timer.isOvertime;

    final Color ringColor;
    final Color trackColor;
    final double progress;
    final Duration displayTime;

    if (overtime) {
      final p = widget.timer.overtimeProgress;
      ringColor = Color.lerp(
            const Color(0xFFF59E0B),
            const Color(0xFFDC2626),
            p,
          ) ??
          const Color(0xFFDC2626);
      trackColor = const Color(0xFFFEF3C7);
      progress = p;
      displayTime = widget.timer.overtime;
    } else {
      ringColor = widget.color;
      trackColor = widget.timer.isBreak
          ? const Color(0xFFD1FAE5)
          : const Color(0xFFDBEAFE);
      progress = widget.timer.progress;
      displayTime = widget.timer.remaining;
    }

    final minutes =
        displayTime.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds =
        displayTime.inSeconds.remainder(60).toString().padLeft(2, '0');

    final phaseLabel =
        widget.timer.isBreak ? 'Start sprint' : 'Start break';
    final phaseIcon = widget.timer.isBreak
        ? Icons.play_arrow_rounded
        : Icons.coffee_outlined;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: CustomPaint(
        painter: RingPainter(
          progress: progress,
          ringColor: ringColor,
          trackColor: trackColor,
          clockwise: widget.timer.isOvertime != widget.timer.isBreak,
        ),
        child: Padding(
          // Keep the column's bounds inside the ring's stroke, with room for
          // the Sprint number above the countdown — the ring shrinks to 160px
          // on a small screen, and the column has to hold both.
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Spacer(),
              // The number of the Sprint being worked, and nothing else: no
              // total to match it against, so the count never reads as a
              // target. A Break is not a Sprint, so it carries no number.
              if (widget.timer.isFocus) ...[
                Text(
                  'Sprint ${widget.timer.sprintNumber}',
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.15,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF6B7280),
                  ),
                ),
                const SizedBox(height: 2),
              ],
              Text(
                '$minutes:$seconds',
                style: TextStyle(
                  fontSize: widget.size * 0.17,
                  fontWeight: FontWeight.bold,
                  color: ringColor,
                  letterSpacing: -1,
                ),
              ),
              const Spacer(),
              AnimatedBuilder(
                animation: _pulseCtrl,
                builder: (context, child) {
                  final scale =
                      1.0 + math.sin(_pulseCtrl.value * math.pi) * 0.12;
                  return Transform.scale(scale: scale, child: child);
                },
                child: IconButton(
                  onPressed: widget.onPhaseSkip,
                  tooltip: phaseLabel,
                  icon: Icon(phaseIcon, color: ringColor),
                  iconSize: 36,
                  style: IconButton.styleFrom(
                    backgroundColor: ringColor.withValues(alpha: 0.07),
                    shape: const StadiumBorder(),
                  ),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sprint dots column — vertical progress indicator
// ---------------------------------------------------------------------------

class SprintDotsColumn extends StatelessWidget {
  const SprintDotsColumn({
    super.key,
    required this.timer,
    required this.pulseCtrl,
    this.limit,
  });
  final SprintTimerState timer;
  final AnimationController pulseCtrl;

  /// The limit status of the Outcome's current Action, when it is Timeboxed.
  final TimeboxedLimitStatus? limit;

  @override
  Widget build(BuildContext context) {
    final total = timer.totalSprints;
    final completedCount =
        timer.isBreak ? timer.sprintNumber : timer.sprintNumber - 1;
    // The first recorded Sprint that started at or after the limit: from
    // there on, the dots are red (issue #923). The dots and the recorded
    // Sprints count alike — the Action's Sprints, oldest first — so the dot
    // for the k-th Sprint is the k-th recorded start.
    final starts = limit?.sprintStarts ?? const <DateTime>[];
    final passedAt = limit?.limitPassedAt;
    var firstPast = starts.length;
    if (passedAt != null) {
      for (var i = 0; i < starts.length; i++) {
        if (!starts[i].isBefore(passedAt)) {
          firstPast = i;
          break;
        }
      }
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (i) {
        final isCompleted = i < completedCount;
        final isCurrent = !timer.isBreak && i == timer.sprintNumber - 1;
        final isFilled = isCompleted || isCurrent;
        // Red means a limit has been passed (docs/DESIGN.md § Colour).
        final isPastLimit = limit != null && isFilled && i >= firstPast;

        Widget dot = Container(
          key: ValueKey('sprint_dot_$i'),
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isPastLimit
                ? const Color(0xFFDC2626)
                : isFilled
                    ? const Color(0xFF2563EB)
                    : Colors.transparent,
            border: isFilled
                ? null
                : Border.all(color: const Color(0xFFBFDBFE), width: 2),
          ),
        );

        if (isCurrent) {
          dot = ScaleTransition(
            scale: Tween<double>(begin: 0.82, end: 1.18).animate(
              CurvedAnimation(parent: pulseCtrl, curve: Curves.easeInOut),
            ),
            child: dot,
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: dot,
        );
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// Ring painter
// ---------------------------------------------------------------------------

class RingPainter extends CustomPainter {
  const RingPainter({
    required this.progress,
    required this.ringColor,
    required this.trackColor,
    this.clockwise = true,
  });

  final double progress;
  final Color ringColor;
  final Color trackColor;
  final bool clockwise;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide / 2) - 10;
    const strokeWidth = 11.0;
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
      final sweep = (clockwise ? 1 : -1) * math.pi * 2 * progress;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweep,
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
  bool shouldRepaint(RingPainter old) =>
      old.progress != progress ||
      old.ringColor != ringColor ||
      old.trackColor != trackColor ||
      old.clockwise != clockwise;
}
