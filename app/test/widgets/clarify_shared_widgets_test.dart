/// Radii-scale regression guard for the shared clarify field widgets (#456).
///
/// `docs/DESIGN.md` § Roundedness fixes the canonical scale: 2px buttons, 4px
/// chips/tags/inputs, 6px surfaces, with pill radii ruled out. These pin the
/// migrated values so the legacy 8/10/20px roundedness cannot creep back.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/widgets/clarify_shared_widgets.dart';

/// Every rounded corner reported by [radius], as its circular radius in px.
Set<double> _corners(BorderRadius radius) => {
      radius.topLeft.x,
      radius.topRight.x,
      radius.bottomLeft.x,
      radius.bottomRight.x,
    };

void main() {
  testWidgets('ClarifyEnergyPicker level chips use the 4px chip radius',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClarifyEnergyPicker(selected: 'medium', onSelect: (_) {}),
      ),
    ));

    final containers =
        tester.widgetList<AnimatedContainer>(find.byType(AnimatedContainer));
    expect(containers, isNotEmpty);
    for (final c in containers) {
      final radius = (c.decoration as BoxDecoration).borderRadius as BorderRadius;
      expect(_corners(radius), {4.0});
    }
  });

  testWidgets('ClarifyEstimateChip uses the 4px chip radius', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClarifyEstimateChip(label: '15m', selected: true, onTap: () {}),
      ),
    ));

    final container =
        tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    final radius =
        (container.decoration as BoxDecoration).borderRadius as BorderRadius;
    expect(_corners(radius), {4.0});
  });

  testWidgets('ClarifyDestinationButton uses the 2px button radius',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClarifyDestinationButton(
          label: 'Skip',
          icon: Icons.skip_next,
          color: const Color(0xFF6B7280),
          onTap: () {},
        ),
      ),
    ));

    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    final shape =
        button.style!.shape!.resolve(const <WidgetState>{}) as RoundedRectangleBorder;
    final radius = shape.borderRadius as BorderRadius;
    expect(_corners(radius), {2.0});
  });
}
