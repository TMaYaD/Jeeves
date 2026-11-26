import 'package:flutter/material.dart';

import '../models/habit_progress.dart' show HabitTodayState;

/// What a [HabitCheckInMark] shows.
enum HabitCheckInMarkState {
  /// Due and not done: an empty Habit-blue ring.
  open,

  /// Done: a filled circle with a check.
  done,

  /// A measurable Habit below its target: a ring with a plus.
  addAmount,

  /// Nothing is asked today: a dashed faint ring.
  notDue,

  /// Paused: a faint ring on the empty fill.
  paused,
}

/// Maps a Habit's [progress] today to its mark.
HabitCheckInMarkState habitMarkState(
  HabitTodayState progress,
  bool isMeasurable,
) =>
    switch (progress) {
      HabitTodayState.done => HabitCheckInMarkState.done,
      HabitTodayState.notYet => isMeasurable
          ? HabitCheckInMarkState.addAmount
          : HabitCheckInMarkState.open,
      HabitTodayState.notDue => HabitCheckInMarkState.notDue,
      HabitTodayState.paused => HabitCheckInMarkState.paused,
    };

/// The Check-in mark: a 28×28 circle in a 48×48 tap target.
///
/// Colours come from the theme: Habit blue is `primary`.
class HabitCheckInMark extends StatelessWidget {
  const HabitCheckInMark({super.key, required this.state, this.onTap});

  final HabitCheckInMarkState state;

  /// Called on tap; ignored for [HabitCheckInMarkState.notDue] and
  /// [HabitCheckInMarkState.paused].
  final VoidCallback? onTap;

  bool get _isTappable =>
      state != HabitCheckInMarkState.notDue &&
      state != HabitCheckInMarkState.paused;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (IconData? icon, Color? iconColor) = switch (state) {
      HabitCheckInMarkState.open => (null, null),
      HabitCheckInMarkState.done => (Icons.check, colors.onPrimary),
      HabitCheckInMarkState.addAmount => (Icons.add, colors.primary),
      HabitCheckInMarkState.notDue => (Icons.remove, colors.outline),
      HabitCheckInMarkState.paused => (Icons.pause, colors.outline),
    };
    final fill = switch (state) {
      HabitCheckInMarkState.done => colors.primary,
      HabitCheckInMarkState.paused => colors.surfaceContainerHighest,
      _ => null,
    };
    final ring = switch (state) {
      HabitCheckInMarkState.open ||
      HabitCheckInMarkState.addAmount ||
      HabitCheckInMarkState.done =>
        (colors.primary, 2.0, false),
      HabitCheckInMarkState.notDue => (colors.outline, 1.5, true),
      HabitCheckInMarkState.paused => (colors.outline, 1.5, false),
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // A resting mark still takes the tap, so it never opens the row behind it.
      onTap: _isTappable ? onTap : () {},
      child: SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: CustomPaint(
            painter: _MarkPainter(
              fill: fill,
              ringColor: ring.$1,
              ringWidth: ring.$2,
              dashed: ring.$3,
            ),
            child: SizedBox(
              width: 28,
              height: 28,
              child: icon == null ? null : Icon(icon, size: 18, color: iconColor),
            ),
          ),
        ),
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  _MarkPainter({
    required this.fill,
    required this.ringColor,
    required this.ringWidth,
    required this.dashed,
  });

  final Color? fill;
  final Color ringColor;
  final double ringWidth;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - ringWidth / 2;
    if (fill != null) {
      canvas.drawCircle(center, size.width / 2, Paint()..color = fill!);
    }
    final stroke = Paint()
      ..color = ringColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = ringWidth;
    if (!dashed) {
      canvas.drawCircle(center, radius, stroke);
      return;
    }
    const dashCount = 12;
    const sweep = 2 * 3.141592653589793 / dashCount;
    final rect = Rect.fromCircle(center: center, radius: radius);
    for (var i = 0; i < dashCount; i++) {
      canvas.drawArc(rect, i * sweep, sweep / 2, false, stroke);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.fill != fill ||
      old.ringColor != ringColor ||
      old.ringWidth != ringWidth ||
      old.dashed != dashed;
}
