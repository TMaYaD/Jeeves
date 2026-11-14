import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/widgets/meta_chip.dart';
import 'package:jeeves/widgets/outcome_attribute_strip.dart';

void main() {
  testWidgets('editable chips dispatch separately; logged time is read-only', (
    tester,
  ) async {
    final taps = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OutcomeAttributeStrip(
            energyLevel: 'high',
            timeEstimateMinutes: 125,
            timeLoggedMinutes: const AsyncData(30),
            dueDate: DateTime(2030, 3, 15),
            onEnergyTap: () => taps.add('energy'),
            onEstimateTap: () => taps.add('estimate'),
            onDueTap: () => taps.add('due'),
            onClearDue: () => taps.add('clear'),
          ),
        ),
      ),
    );
    expect(
      tester
          .widgetList<MetaChip>(find.byType(MetaChip))
          .map((chip) => chip.label),
      ['High', '2h 5m', '30m', 'Mar 15, 2030'],
    );
    for (final label in ['High', '2h 5m', '30m', 'Mar 15, 2030']) {
      await tester.tap(find.text(label));
    }
    await tester.tap(find.byTooltip('Clear date'));
    expect(taps, ['energy', 'estimate', 'due', 'clear']);
  });

  testWidgets(
    'unset attributes keep edit prompts without a clear-date action',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OutcomeAttributeStrip(
              onEnergyTap: () {},
              onEstimateTap: () {},
              onDueTap: () {},
              onClearDue: () {},
            ),
          ),
        ),
      );
      expect(
        tester
            .widgetList<MetaChip>(find.byType(MetaChip))
            .map((chip) => chip.label),
        ['Energy', 'Time', 'Due'],
      );
      expect(find.byTooltip('Clear date'), findsNothing);
    },
  );
}
