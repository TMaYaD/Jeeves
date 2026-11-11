import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/widgets/meta_chip.dart';
import 'package:jeeves/widgets/outcome_review_card.dart';

Todo outcome({String? notes}) => Todo(
  id: 'outcome',
  title: 'Renew passport',
  clarified: true,
  intent: 'next',
  notes: notes,
  userId: 'local',
  createdAt: DateTime(2030),
  updatedAt: DateTime(2030),
);

void main() {
  testWidgets('renders context slots and invokes the injected action', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OutcomeReviewCard(
            todo: outcome(notes: 'Bring documents'),
            banner: const OutcomeReviewBanner(
              icon: Icons.refresh,
              text: 'Review this Outcome',
            ),
            personTags: [
              Tag(id: 'person', name: 'Trixy', type: 'person', userId: 'local'),
            ],
            currentActionText: 'Call the office',
            meta: const OutcomeMetaLine(timeEstimateMinutes: 125),
            actions: TextButton(
              onPressed: () => taps++,
              child: const Text('Continue'),
            ),
          ),
        ),
      ),
    );
    for (final text in [
      'Review this Outcome',
      'Trixy',
      'Renew passport',
      'Call the office',
      'Bring documents',
      '2h 5m',
    ]) {
      expect(find.text(text), findsOneWidget);
    }
    await tester.tap(find.text('Continue'));
    expect(taps, 1);
  });

  testWidgets('omits absent or blank Action and notes', (tester) async {
    for (final value in <String?>[null, '  ']) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OutcomeReviewCard(
              todo: outcome(notes: value),
              currentActionText: value,
              actions: const Text('Actions'),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.arrow_forward), findsNothing);
      expect(
        tester.widgetList<Text>(find.byType(Text)).map((text) => text.data),
        ['Renew passport', 'Actions'],
      );
    }
  });
}
