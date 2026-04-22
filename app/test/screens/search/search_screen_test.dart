import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/models/search_result.dart';
import 'package:jeeves/models/todo.dart' show GtdState;
import 'package:jeeves/providers/search_provider.dart';
import 'package:jeeves/screens/search/search_screen.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Widget _buildScreen() {
  return ProviderScope(
    overrides: [
      // Bypass database + auth; always return empty results.
      searchResultsProvider.overrideWith(
        (_) => Stream.value(<GtdState, List<SearchResult>>{}),
      ),
      // Bypass SharedPreferences; start with no recent searches.
      recentSearchesProvider.overrideWith(
        () => _EmptyRecentSearchesNotifier(),
      ),
    ],
    child: const MaterialApp(home: SearchScreen()),
  );
}

class _EmptyRecentSearchesNotifier extends RecentSearchesNotifier {
  @override
  List<String> build() => const [];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('SearchScreen', () {
    testWidgets('renders without error on fresh install (no pre-existing provider state)',
        (tester) async {
      // Regression test for https://github.com/TMaYaD/Jeeves/issues/154
      // Previously SearchScreen called ref.read(...).update() synchronously in
      // initState, which threw "Tried to modify a provider while the widget
      // tree was building" when the provider had never been alive before.
      await tester.pumpWidget(_buildScreen());
      await tester.pump();

      // Should not throw; screen should show the search hint text.
      expect(find.widgetWithText(TextField, ''), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('search field starts empty', (tester) async {
      await tester.pumpWidget(_buildScreen());
      await tester.pump();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text ?? '', isEmpty);
    });

    testWidgets('shows no results when query is empty', (tester) async {
      await tester.pumpWidget(_buildScreen());
      await tester.pump();

      expect(find.text('Search tasks…'), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
    });

    testWidgets('query resets after leaving and reopening search', (tester) async {
      await tester.pumpWidget(_buildScreen());
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'inbox');
      await tester.pump();

      // Dispose SearchScreen (and its autoDispose providers).
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();

      // Reopen and verify autoDispose reset the query to empty.
      await tester.pumpWidget(_buildScreen());
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text ?? '', isEmpty);
    });
  });
}
