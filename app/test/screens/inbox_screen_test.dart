import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/providers/onboarding_provider.dart';
import 'package:jeeves/screens/inbox/inbox_screen.dart';
import 'package:jeeves/screens/inbox/widgets/inbox_list.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A minimal Inbox [Capture] row for widget tests — `clarifiedAt` null, so it
/// is in the Inbox (ADR-0006).
Capture _capture(String id, String title) => Capture(
      id: id,
      title: title,
      notes: null,
      captureSource: 'manual',
      createdAt: DateTime(2024, 1, 1),
      clarifiedAt: null,
      updatedAt: null,
      userId: 'local',
    );

/// Build the app with fully controlled provider overrides so no platform
/// channels (SQLite watch streams) run inside fakeAsync.
///
/// [inboxStream] is what [inboxItemsProvider] emits.
/// [db] is needed only when [InboxNotifier.addCapture] must actually write.
Widget _buildApp({
  Stream<List<Capture>>? inboxStream,
  GtdDatabase? db,
}) {
  return ProviderScope(
    overrides: [
      inboxItemsProvider.overrideWith(
        (ref) => inboxStream ?? Stream.value([]),
      ),
      // Stub out hasAnyItemProvider so OnboardingCard never hits the real DB.
      hasAnyItemProvider.overrideWith((ref) => Stream.value(true)),
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
    setUp(() => onboardingSeenNotifier.value = true);
    tearDown(() => onboardingSeenNotifier.value = false);

    testWidgets('empty state shows one Jeeves-speak line from the pool',
        (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      // Exactly one of the pool lines renders; the old instructional copy is
      // gone entirely.
      final matches = inboxEmptyStateLines
          .where((line) => find.text(line).evaluate().isNotEmpty)
          .toList();
      expect(matches, hasLength(1),
          reason: 'expected exactly one empty-state line from the pool');
      expect(find.textContaining('No items yet'), findsNothing);
    });

    testWidgets('items are rendered in the list', (tester) async {
      // The unprocessed-count badge lives in the shared AppShell title bar now
      //; it is covered by app_shell_test, not here — this screen
      // renders standalone with no title bar.
      final items = [_capture('a', 'Buy milk'), _capture('b', 'Call dentist')];
      await tester.pumpWidget(_buildApp(inboxStream: Stream.value(items)));
      await tester.pump();

      expect(find.text('Buy milk'), findsOneWidget);
      expect(find.text('Call dentist'), findsOneWidget);
    });

    testWidgets('submitting text field clears the input', (tester) async {
      final db = GtdDatabase(NativeDatabase.memory());
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

    testWidgets('tapping Add persists a Capture row', (tester) async {
      final db = GtdDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.pumpWidget(_buildApp(db: db));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Integration test task');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      // Plain select, not a watch — a live drift watch hangs widget tests
      // (docs/TESTING.md). Rendering from the stream is covered above.
      final rows = await db.select(db.captures).get();
      expect(rows, hasLength(1));
      expect(rows.first.title, 'Integration test task');
      expect(rows.first.clarifiedAt, isNull);
    });
  });
}
