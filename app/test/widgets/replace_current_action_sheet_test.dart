/// Tests for the shared "Replace current action?" confirm sheet (issue #723).
///
/// Extracted from the Outcome detail Plan section so the re-clarification
/// surfaces can reuse it; it performs no write and returns the user's verdict
/// as a `bool` (confirm → true, dismiss → false), leaving the caller to own the
/// supersede-and-promote.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/widgets/replace_current_action_sheet.dart';

void main() {
  Future<bool?> openSheet(WidgetTester tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showReplaceCurrentActionSheet(
                    context,
                    currentText: 'Book the room',
                    newText: 'Email the guest list',
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('renders the current and new phrases', (tester) async {
    await openSheet(tester);
    expect(find.text('Replace current action?'), findsOneWidget);
    expect(find.text('Book the room'), findsOneWidget);
    expect(find.text('Email the guest list'), findsOneWidget);
    expect(find.byKey(const Key('plan_replace_confirm')), findsOneWidget);
  });

  testWidgets('confirm returns true, dismissal returns false', (tester) async {
    // Confirm path.
    bool? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  confirmed = await showReplaceCurrentActionSheet(
                    context,
                    currentText: 'a',
                    newText: 'b',
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan_replace_confirm')));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);

    // Dismissal path (system back).
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(confirmed, isFalse,
        reason: 'a barrier/back dismissal is a declined replace');
  });
}
