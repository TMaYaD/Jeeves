import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:jeeves/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Inbox processing E2E', () {
    testWidgets('app launches and shows Inbox screen', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      expect(find.text('Inbox'), findsOneWidget);
    });

    testWidgets('bottom navigation has four tabs', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      expect(find.byType(NavigationDestination), findsNWidgets(4));
    });

    testWidgets('add item to inbox then tap to open detail view', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Add a task via quick add.
      await tester.enterText(
        find.byType(TextField).first,
        'Process this task',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // Tap the item to open detail.
      await tester.tap(find.text('Process this task'));
      await tester.pumpAndSettle();

      // Detail screen should be visible.
      expect(find.text('Edit task'), findsOneWidget);
      expect(find.text('Move to…'), findsOneWidget);
    });

    testWidgets('invalid transition (Inbox → In Progress) not offered in sheet',
        (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Add and open a task.
      await tester.enterText(find.byType(TextField).first, 'Check invalid transitions');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Check invalid transitions'));
      await tester.pumpAndSettle();

      // Open "Move to" sheet.
      await tester.tap(find.text('Move to…'));
      await tester.pumpAndSettle();

      // In Progress and Scheduled should NOT appear.
      expect(find.text('In Progress'), findsNothing);
      expect(find.text('Scheduled'), findsNothing);
    });

    testWidgets('moving item to Next Actions removes it from inbox',
        (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      await tester.enterText(find.byType(TextField).first, 'GTD candidate');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      await tester.tap(find.text('GTD candidate'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Move to…'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Actions'));
      await tester.pumpAndSettle();

      // Back on inbox — item should be gone.
      expect(find.text('GTD candidate'), findsNothing);

      // Navigate to Next Actions — item should be there.
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(find.text('GTD candidate'), findsOneWidget);
    });
  });
}
