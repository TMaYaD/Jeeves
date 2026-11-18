/// The energy and estimate sheets, driven by callbacks (#402).
///
/// The sheets used to write through an Outcome's notifier. They now report
/// every change to the caller, so any surface can offer them.
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

  testWidgets('the estimate sheet reports a duration and a clear',
      (tester) async {
    final chosen = <int>[];
    var cleared = false;

    // The estimate ladder is a list of nine rows, and on the default test
    // surface the sheet is taller than the viewport — so the lower rows are
    // never built and cannot be tapped. A tall surface puts the whole
    // ladder on screen.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showOutcomeTimeEstimateSheet(
              context,
              onSet: (minutes) => chosen.add(minutes),
              onClear: () => cleared = true,
              current: 30,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Time Estimate'), findsOneWidget);

    await tester.tap(find.text('1h'));
    await tester.pumpAndSettle();
    expect(chosen, [60]);
    expect(cleared, isFalse);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('None'));
    await tester.pumpAndSettle();
    expect(cleared, isTrue);
    expect(chosen, [60]);
  });
}
