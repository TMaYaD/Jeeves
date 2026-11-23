import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/models/habit_day_marks.dart';
import 'package:jeeves/widgets/habit_day_mark_grid.dart';

void main() {
  group('habitDayMarkShapeFor', () {
    test(
      'done, missed, not due, paused and before the Habit differ by shape',
      () {
        final shapes = [
          habitDayMarkShapeFor(HabitDayState.done),
          habitDayMarkShapeFor(HabitDayState.missed),
          habitDayMarkShapeFor(HabitDayState.notDue),
          habitDayMarkShapeFor(HabitDayState.paused),
          habitDayMarkShapeFor(HabitDayState.beforeHabit),
        ];
        expect(shapes.toSet().length, shapes.length);
      },
    );

    test(
      'a partial day, an open day and an archived day have their shapes',
      () {
        expect(
          habitDayMarkShapeFor(HabitDayState.partial),
          HabitDayMarkShape.partialRing,
        );
        expect(
          habitDayMarkShapeFor(HabitDayState.openToday),
          habitDayMarkShapeFor(HabitDayState.missed),
        );
        expect(
          habitDayMarkShapeFor(HabitDayState.archived),
          habitDayMarkShapeFor(HabitDayState.paused),
        );
        expect(
          habitDayMarkShapeFor(HabitDayState.future),
          HabitDayMarkShape.none,
        );
      },
    );
  });

  testWidgets('the grid takes its colours from a dark theme', (tester) async {
    final dark = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF2667B7),
        brightness: Brightness.dark,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: dark,
        home: Scaffold(
          body: HabitDayMarkGrid(
            cells: [
              HabitDayMark(
                day: DateTime.utc(2026, 11, 2),
                state: HabitDayState.done,
              ),
            ],
            cellHeight: 64,
          ),
        ),
      ),
    );
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((p) => p.painter)
        .whereType<HabitDayMarkPainter>()
        .single;
    expect(painter.colors, HabitDayMarkColors.of(dark.colorScheme));
    expect(painter.colors.ink, dark.colorScheme.primary);
  });
}
