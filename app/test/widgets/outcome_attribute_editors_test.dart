/// The energy sheet, driven by callbacks (#402).
///
/// The sheet used to write through an Outcome's notifier. It now reports
/// every change to the caller, so any surface can offer it. The estimate sheet
/// writes the estimate and the Timeboxed switch together, so it is covered by
/// `outcome_time_estimate_sheet_test.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/widgets/outcome_attribute_editors.dart';

void main() {
  testWidgets('the energy sheet reports the chosen level', (tester) async {
    final chosen = <String>[];
    var cleared = false;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showOutcomeEnergyLevelSheet(
              context,
              onSet: (level) => chosen.add(level),
              onClear: () => cleared = true,
              current: 'low',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Energy Level'), findsOneWidget);

    await tester.tap(find.text('High'));
    await tester.pumpAndSettle();
    expect(chosen, ['high']);
    expect(cleared, isFalse);
  });
}
