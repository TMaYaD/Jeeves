import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/inbox/inbox_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Inbox capture E2E', () {
    testWidgets('app launches and shows Inbox screen', (tester) async {
      final db = GtdDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: const MaterialApp(home: InboxScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Inbox'), findsOneWidget);
    });

    testWidgets('type title and tap Add — item appears in list', (tester) async {
      final db = GtdDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: const MaterialApp(home: InboxScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Integration test task');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.text('Integration test task'), findsOneWidget);
    });

    testWidgets('inbox count badge matches list length', (tester) async {
      final db = GtdDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: const MaterialApp(home: InboxScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Task A');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Task B');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      // Two items in the list → badge shows "2".
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Task A'), findsOneWidget);
      expect(find.text('Task B'), findsOneWidget);
    });
  });
}
