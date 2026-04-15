import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/connectivity_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/screens/inbox/inbox_screen.dart';
import 'package:jeeves/screens/inbox/widgets/offline_chip.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A minimal [Todo] row for widget tests.
Todo _todo(String id, String title) => Todo(
      id: id,
      title: title,
      notes: null,
      completed: false,
      priority: null,
      dueDate: null,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: null,
      state: 'inbox',
      timeEstimate: null,
      energyLevel: null,
      captureSource: 'manual',
      locationId: null,
      userId: 'local',
      timeSpentMinutes: 0,
    );

/// Build the app with fully controlled provider overrides so no platform
/// channels (connectivity D-Bus, SQLite watch streams) run inside fakeAsync.
///
/// [inboxStream] is what [inboxItemsProvider] emits.
/// [isOnlineStream] is what [isOnlineProvider] emits.
/// [db] is needed only when [InboxNotifier.addTodo] must actually write.
Widget _buildApp({
  Stream<List<Todo>>? inboxStream,
  Stream<bool>? isOnlineStream,
  GtdDatabase? db,
}) {
  return ProviderScope(
    overrides: [
      isOnlineProvider.overrideWith(
        (ref) => isOnlineStream ?? Stream.value(true),
      ),
      inboxItemsProvider.overrideWith(
        (ref) => inboxStream ?? Stream.value([]),
      ),
      if (db != null) databaseProvider.overrideWithValue(db),
    ],
    child: const MaterialApp(home: InboxScreen()),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(configureSqliteForTests);

  group('InboxScreen', () {
    testWidgets('empty state shows "No items yet" message', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      expect(find.textContaining('No items yet'), findsOneWidget);
    });

    testWidgets('items are rendered in the list', (tester) async {
      final items = [_todo('a', 'Buy milk'), _todo('b', 'Call dentist')];
      await tester.pumpWidget(_buildApp(inboxStream: Stream.value(items)));
      await tester.pump();

      expect(find.text('Buy milk'), findsOneWidget);
      expect(find.text('Call dentist'), findsOneWidget);
    });

    testWidgets('quick add bar has placeholder text', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      expect(find.text("What's on your mind?"), findsOneWidget);
    });

    testWidgets('quick add bar has camera and mic icons', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      expect(find.byIcon(Icons.camera_alt_outlined), findsOneWidget);
      expect(find.byIcon(Icons.mic_none), findsOneWidget);
    });

    testWidgets('submitting text field clears the input', (tester) async {
      final db = GtdDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.pumpWidget(_buildApp(db: db));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'My task');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
    });

    testWidgets('no add button in header', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      expect(find.byIcon(Icons.add), findsNothing);
    });

    testWidgets('OfflineChip is visible when connectivity is none',
        (tester) async {
      await tester.pumpWidget(
        _buildApp(isOnlineStream: Stream.value(false)),
      );
      await tester.pump();

      expect(find.byType(OfflineChip), findsOneWidget);
    });

    testWidgets('OfflineChip is hidden when connectivity is online',
        (tester) async {
      await tester.pumpWidget(
        _buildApp(isOnlineStream: Stream.value(true)),
      );
      await tester.pump();

      expect(find.byType(OfflineChip), findsNothing);
    });

    testWidgets('pull-to-refresh completes without error', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      await tester.fling(
        find.byType(ListView),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();
    });
  });
}
