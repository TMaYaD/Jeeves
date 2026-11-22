import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/models/habit_progress.dart' show HabitTodayState;
import 'package:jeeves/widgets/habit_check_in_mark.dart';

Future<int> _pump(WidgetTester tester, HabitCheckInMarkState state,
    {ThemeData? theme}) async {
  var taps = 0;
  await tester.pumpWidget(MaterialApp(
    theme: theme,
    home: Scaffold(
      body: Center(
        child: HabitCheckInMark(state: state, onTap: () => taps++),
      ),
    ),
  ));
  await tester.tap(find.byType(HabitCheckInMark));
  return taps;
}

void main() {
  const expectedIcons = {
    HabitCheckInMarkState.open: null,
    HabitCheckInMarkState.done: Icons.check,
    HabitCheckInMarkState.addAmount: Icons.add,
    HabitCheckInMarkState.notDue: Icons.remove,
    HabitCheckInMarkState.paused: Icons.pause,
  };

  for (final entry in expectedIcons.entries) {
    testWidgets('${entry.key.name} renders its icon', (tester) async {
      await _pump(tester, entry.key);
      if (entry.value == null) {
        expect(find.byType(Icon), findsNothing);
      } else {
        expect(find.byIcon(entry.value!), findsOneWidget);
      }
      expect(tester.getSize(find.byType(HabitCheckInMark)),
          const Size(48, 48));
    });
  }

  for (final state in HabitCheckInMarkState.values) {
    final tappable = state != HabitCheckInMarkState.notDue &&
        state != HabitCheckInMarkState.paused;
    testWidgets('${state.name} ${tappable ? 'takes' : 'ignores'} taps',
        (tester) async {
      final taps = await _pump(tester, state);
      expect(taps, tappable ? 1 : 0);
    });
  }

  test('habitMarkState covers all four HabitTodayStates', () {
    expect(habitMarkState(HabitTodayState.done, false),
        HabitCheckInMarkState.done);
    expect(habitMarkState(HabitTodayState.done, true),
        HabitCheckInMarkState.done);
    expect(habitMarkState(HabitTodayState.notYet, false),
        HabitCheckInMarkState.open);
    expect(habitMarkState(HabitTodayState.notYet, true),
        HabitCheckInMarkState.addAmount);
    expect(habitMarkState(HabitTodayState.notDue, true),
        HabitCheckInMarkState.notDue);
    expect(habitMarkState(HabitTodayState.paused, false),
        HabitCheckInMarkState.paused);
  });

  testWidgets('under a dark theme the filled mark takes colorScheme.primary',
      (tester) async {
    final theme = ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal, brightness: Brightness.dark));
    await _pump(tester, HabitCheckInMarkState.done, theme: theme);

    final paint = tester.widget<CustomPaint>(find
        .descendant(
            of: find.byType(HabitCheckInMark),
            matching: find.byType(CustomPaint))
        .first);
    final painter = paint.painter! as dynamic;
    expect(painter.fill, theme.colorScheme.primary);
    expect(tester.widget<Icon>(find.byIcon(Icons.check)).color,
        theme.colorScheme.onPrimary);
  });
}
