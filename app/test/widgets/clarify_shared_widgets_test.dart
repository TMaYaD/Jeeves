import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/widgets/clarify_shared_widgets.dart';

void main() {
  testWidgets('estimate picker selects and clears the same option', (
    tester,
  ) async {
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ClarifyEstimatePicker(
              selectedMinutes: selected,
              onSelect: (minutes) => setState(() => selected = minutes),
            ),
          ),
        ),
      ),
    );
    expect(
      find.byType(ClarifyEstimateChip),
      findsNWidgets(kEstimateOptionsMinutes.length),
    );
    await tester.tap(find.text('30m'));
    await tester.pumpAndSettle();
    expect(selected, 30);
    await tester.tap(find.text('30m'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    await tester.tap(find.text('2h'));
    await tester.pumpAndSettle();
    expect(selected, 120);
  });
}
