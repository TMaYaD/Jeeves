import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/widgets/meta_chip.dart';

void main() {
  testWidgets('attributes appear in energy, estimate, logged, due order', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OutcomeMetaLine(
            energyLevel: 'medium',
            timeEstimateMinutes: 125,
            timeLoggedMinutes: 60,
            dueDate: DateTime(2030, 3, 15),
          ),
        ),
      ),
    );
    expect(
      tester
          .widgetList<MetaChip>(find.byType(MetaChip))
          .map((chip) => chip.label),
      ['Medium', '2h 5m', '1h', 'Mar 15, 2030'],
    );
    expect(find.byType(InkWell), findsNothing);
    expect(find.byType(GestureDetector), findsNothing);
  });

  testWidgets('unset attributes are omitted', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: OutcomeMetaLine())),
    );
    expect(find.byType(MetaChip), findsNothing);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: OutcomeMetaLine(timeEstimateMinutes: 0)),
      ),
    );
    expect(find.byType(MetaChip), findsOneWidget);
    expect(find.text('0m'), findsOneWidget);
  });

  test('due date uses the local calendar day across UTC midnight', () {
    // Run with TZ=America/Los_Angeles to exercise the UTC day boundary.
    final localDate = DateTime(2030, 3, 15, 23, 30);
    expect(formatDueDateLabel(localDate.toUtc()), 'Mar 15, 2030');
    expect(formatDueDateLabel(localDate), 'Mar 15, 2030');
  });

  test('duration and unknown energy labels retain their values', () {
    expect(formatMinutesLabel(125), '2h 5m');
    expect(energyLevelLabel('future-level'), 'future-level');
  });
}
