/// The round mark of one Habit day, and a Monday-first grid of them painted
/// with one `CustomPainter`, so a month is one paint object, not 31 widgets.
///
/// Every state differs by shape, not by colour alone, and no state is red.
/// Colours come from the theme's `ColorScheme`.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/habit_day_marks.dart';

/// What is drawn for a day, apart from its colour.
enum HabitDayMarkShape {
  /// Filled circle with a check: the day was done.
  filled,

  /// Open ring with an arc for the part done.
  partialRing,

  /// Open ring: due and not done.
  ring,

  /// Small centre dot: nothing is asked of the Habit.
  dot,

  /// Ring with a pause bar: the Habit was paused or archived.
  pauseRing,

  /// Nothing: before the Habit, or after today.
  none,
}

/// The shape of the mark for [state].
HabitDayMarkShape habitDayMarkShapeFor(HabitDayState state) => switch (state) {
  HabitDayState.done => HabitDayMarkShape.filled,
  HabitDayState.partial => HabitDayMarkShape.partialRing,
  HabitDayState.missed || HabitDayState.openToday => HabitDayMarkShape.ring,
  HabitDayState.notDue => HabitDayMarkShape.dot,
  HabitDayState.paused || HabitDayState.archived => HabitDayMarkShape.pauseRing,
  HabitDayState.beforeHabit || HabitDayState.future => HabitDayMarkShape.none,
};

/// The colours of a mark, all taken from a [ColorScheme].
@immutable
class HabitDayMarkColors {
  const HabitDayMarkColors({
    required this.ink,
    required this.onInk,
    required this.neutral,
    required this.todayOutline,
  });

  factory HabitDayMarkColors.of(ColorScheme scheme) => HabitDayMarkColors(
    ink: scheme.primary,
    onInk: scheme.onPrimary,
    neutral: scheme.outline,
    todayOutline: scheme.onSurface,
  );

  /// Done marks and the progress arc.
  final Color ink;

  /// The check on a done mark.
  final Color onInk;

  /// Open rings, dots and the pause bar.
  final Color neutral;

  /// The outline around today's cell.
  final Color todayOutline;

  @override
  bool operator ==(Object other) =>
      other is HabitDayMarkColors &&
      other.ink == ink &&
      other.onInk == onInk &&
      other.neutral == neutral &&
      other.todayOutline == todayOutline;

  @override
  int get hashCode => Object.hash(ink, onInk, neutral, todayOutline);
}

/// Draws one mark of [shape] centred on [center].
///
/// [partFraction] is how much of the target a [HabitDayMarkShape.partialRing]
/// shows, from 0 to 1.
void paintHabitDayMark(
  Canvas canvas,
  Offset center,
  double radius,
  HabitDayMarkShape shape,
  HabitDayMarkColors colors, {
  double partFraction = 0.5,
}) {
  final ring = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5
    ..color = colors.neutral;
  switch (shape) {
    case HabitDayMarkShape.none:
      return;
    case HabitDayMarkShape.filled:
      canvas.drawCircle(center, radius, Paint()..color = colors.ink);
      final check = Path()
        ..moveTo(center.dx - radius * 0.45, center.dy)
        ..lineTo(center.dx - radius * 0.1, center.dy + radius * 0.4)
        ..lineTo(center.dx + radius * 0.5, center.dy - radius * 0.35);
      canvas.drawPath(
        check,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = colors.onInk,
      );
    case HabitDayMarkShape.partialRing:
      canvas.drawCircle(center, radius, ring);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * partFraction.clamp(0.0, 1.0),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = colors.ink,
      );
    case HabitDayMarkShape.ring:
      canvas.drawCircle(center, radius, ring);
    case HabitDayMarkShape.dot:
      canvas.drawCircle(center, 2.5, Paint()..color = colors.neutral);
    case HabitDayMarkShape.pauseRing:
      canvas.drawCircle(center, radius, ring);
      final bar = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = colors.neutral;
      for (final dx in [-radius * 0.22, radius * 0.22]) {
        canvas.drawLine(
          Offset(center.dx + dx, center.dy - radius * 0.38),
          Offset(center.dx + dx, center.dy + radius * 0.38),
          bar,
        );
      }
  }
}

/// How far into its target a partial [mark] is, from 0 to 1.
double _partFraction(HabitDayMark mark) {
  final total = mark.totalAmount;
  final target = mark.targetAmount;
  if (total == null || target == null || target <= 0) return 0.5;
  return (total / target).clamp(0.0, 1.0);
}

/// Paints the marks of a Monday-first grid: [cells] in reading order, null for
/// a blank cell, [columns] to a row.
class HabitDayMarkPainter extends CustomPainter {
  const HabitDayMarkPainter({
    required this.cells,
    required this.colors,
    required this.cellHeight,
    required this.markRadius,
    required this.markCenterY,
    this.todayDay,
    this.columns = 7,
  });

  final List<HabitDayMark?> cells;
  final HabitDayMarkColors colors;
  final double cellHeight;
  final double markRadius;

  /// Where the mark's centre sits in a cell, from the cell's top.
  final double markCenterY;

  /// The day that gets the today outline.
  final DateTime? todayDay;
  final int columns;

  @override
  void paint(Canvas canvas, Size size) {
    final cellWidth = size.width / columns;
    for (var i = 0; i < cells.length; i++) {
      final mark = cells[i];
      if (mark == null) continue;
      final left = (i % columns) * cellWidth;
      final top = (i ~/ columns) * cellHeight;
      paintHabitDayMark(
        canvas,
        Offset(left + cellWidth / 2, top + markCenterY),
        markRadius,
        habitDayMarkShapeFor(mark.state),
        colors,
        partFraction: _partFraction(mark),
      );
      if (todayDay != null && mark.day == todayDay) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(left + 1, top + 1, cellWidth - 2, cellHeight - 2),
            const Radius.circular(8),
          ),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = colors.todayOutline,
        );
      }
    }
  }

  @override
  bool shouldRepaint(HabitDayMarkPainter old) =>
      old.cells != cells ||
      old.colors != colors ||
      old.todayDay != todayDay ||
      old.cellHeight != cellHeight ||
      old.markRadius != markRadius ||
      old.markCenterY != markCenterY;
}

/// A grid of day marks, as wide as its parent, [rowCount] rows of
/// [cellHeight].
class HabitDayMarkGrid extends StatelessWidget {
  const HabitDayMarkGrid({
    super.key,
    required this.cells,
    required this.cellHeight,
    this.markRadius = 11,
    this.markCenterY = 34,
    this.todayDay,
  });

  final List<HabitDayMark?> cells;
  final double cellHeight;
  final double markRadius;
  final double markCenterY;
  final DateTime? todayDay;

  @override
  Widget build(BuildContext context) {
    final rows = (cells.length / 7).ceil();
    return CustomPaint(
      painter: HabitDayMarkPainter(
        cells: cells,
        colors: HabitDayMarkColors.of(Theme.of(context).colorScheme),
        cellHeight: cellHeight,
        markRadius: markRadius,
        markCenterY: markCenterY,
        todayDay: todayDay,
      ),
      child: SizedBox(width: double.infinity, height: rows * cellHeight),
    );
  }
}

/// One mark of [shape] on its own, for a legend.
class HabitDayMarkSwatch extends StatelessWidget {
  const HabitDayMarkSwatch({super.key, required this.shape, this.size = 24});

  final HabitDayMarkShape shape;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = HabitDayMarkColors.of(Theme.of(context).colorScheme);
    return CustomPaint(
      size: Size.square(size),
      painter: _SwatchPainter(shape, colors),
    );
  }
}

class _SwatchPainter extends CustomPainter {
  const _SwatchPainter(this.shape, this.colors);
  final HabitDayMarkShape shape;
  final HabitDayMarkColors colors;

  @override
  void paint(Canvas canvas, Size size) => paintHabitDayMark(
    canvas,
    size.center(Offset.zero),
    size.width / 2 - 1.5,
    shape,
    colors,
  );

  @override
  bool shouldRepaint(_SwatchPainter old) =>
      old.shape != shape || old.colors != colors;
}
