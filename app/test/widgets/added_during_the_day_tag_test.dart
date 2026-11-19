import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/widgets/added_during_the_day_tag.dart';

void main() {
  // The tag's shape is a design decision, not behaviour: docs/DESIGN.md §
  // Roundedness puts tags at 4px on the canonical 2/4/6 scale and rules pills
  // out, and docs/TESTING.md § Core Testing Principles bars asserts on corner
  // radii. What is asserted here is the tag's wiring — it carries its label
  // and owns no gesture of its own (docs/DESIGN.md: the containing surface
  // owns the tap target).
  testWidgets('the tag carries its label and owns no gesture', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AddedDuringTheDayTag())),
    );

    expect(find.text(AddedDuringTheDayTag.label), findsOneWidget);
    expect(find.byType(GestureDetector), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });
}
