/// The screen a build shows when the local data was written by a newer
/// build.
///
/// The screen has one job and one rule. The job: say what happened, in plain
/// words, with the running build's own version so a user can tell which build
/// they are looking at. The rule: **offer no action at all.** The data is
/// intact and belongs to a newer Jeeves, and a control that offered to delete
/// it, reset it or start fresh would be the one thing on this screen that
/// could destroy it.
///
/// The journey over a real pair of stores — the gate, the providers and this
/// screen together — is `integration/store_version_journey_test.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/build_version_provider.dart';
import 'package:jeeves/screens/store_too_new/store_too_new_copy.dart';
import 'package:jeeves/screens/store_too_new/store_too_new_screen.dart';

const String _versionLabel = 'Version 1.0.0-alpha.1951 (1951)';

void main() {
  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          buildVersionLabelProvider.overrideWith((ref) async => _versionLabel),
        ],
        child: const MaterialApp(home: StoreTooNewScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('it says what happened, in plain words', (tester) async {
    await pumpScreen(tester);

    expect(find.text(storeTooNewTitle), findsOneWidget);
    expect(find.text(storeTooNewExplanation), findsOneWidget);
    expect(find.text(storeTooNewAdvice), findsOneWidget);
  });

  testWidgets('it shows the version of the build the user is looking at',
      (tester) async {
    await pumpScreen(tester);

    expect(find.text('Running version: $_versionLabel'), findsOneWidget);
  });

  testWidgets('it offers no action that could throw the data away',
      (tester) async {
    await pumpScreen(tester);

    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('nothing on the screen is tappable', (tester) async {
    await pumpScreen(tester);

    // No button and no ink response: there is nothing on this screen a user
    // can press.
    expect(find.byType(InkWell), findsNothing);
    expect(find.byType(InkResponse), findsNothing);
  });

  testWidgets('the screen fits a small phone without overflowing',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpScreen(tester);

    expect(tester.takeException(), isNull);
  });
}
