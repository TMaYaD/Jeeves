import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/widgets/meta_chip.dart';
import 'package:jeeves/widgets/outcome_row.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('row and its attributes share tap and long-press callbacks', (
    tester,
  ) async {
    var taps = 0;
    var longPresses = 0;
    await tester.pumpWidget(
      _host(
        OutcomeRow(
          title: 'Report',
          timeEstimateMinutes: 125,
          onTap: () => taps++,
          onLongPress: () => longPresses++,
        ),
      ),
    );
    await tester.tap(find.text('2h 5m'));
    await tester.longPress(find.text('Report'));
    expect(taps, 1);
    expect(longPresses, 1);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    final chips = find.byType(MetaChip);
    expect(
      find.descendant(of: chips, matching: find.byType(GestureDetector)),
      findsNothing,
    );
    expect(
      find.descendant(of: chips, matching: find.byType(InkWell)),
      findsNothing,
    );
  });

  testWidgets('read-only rows have no ink or chevron', (tester) async {
    await tester.pumpWidget(
      _host(const OutcomeRow(title: 'Yesterday', muted: true)),
    );
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.byType(InkWell), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets('slots render and trailing action does not trigger row tap', (
    tester,
  ) async {
    var taps = 0;
    var starts = 0;
    await tester.pumpWidget(
      _host(
        OutcomeRow(
          title: 'Report',
          framed: true,
          struck: true,
          leading: const Icon(Icons.check),
          secondary: const Text('Current Action'),
          meta: const Text('Estimate versus actual'),
          onTap: () => taps++,
          trailing: TextButton(
            onPressed: () => starts++,
            child: const Text('Start'),
          ),
        ),
      ),
    );
    expect(find.text('Current Action'), findsOneWidget);
    expect(find.text('Estimate versus actual'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.tap(find.text('Start'));
    expect(starts, 1);
    expect(taps, 0);
  });
}
