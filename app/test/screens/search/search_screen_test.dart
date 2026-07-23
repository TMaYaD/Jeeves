import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/search_result.dart';
import 'package:jeeves/providers/search_provider.dart';
import 'package:jeeves/screens/search/search_screen.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Widget _buildScreen({
  Stream<List<SearchResult>>? resultsStream,
  Stream<int>? hiddenCountStream,
}) {
  return ProviderScope(
    overrides: [
      // Bypass database + auth; always return empty results unless overridden.
      searchResultsProvider.overrideWith(
        (_) => resultsStream ?? Stream.value(<SearchResult>[]),
      ),
      hiddenDoneMatchCountProvider.overrideWith(
        (_) => hiddenCountStream ?? Stream.value(0),
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

Todo _fakeTodo() => Todo(
      id: 'fake-1',
      title: 'Fake task',
      notes: null,
      doneAt: null,
      priority: null,
      dueDate: null,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: null,
      clarified: false,
      intent: 'next',
      timeEstimate: null,
      energyLevel: null,
      captureSource: 'manual',
      locationId: null,
      userId: 'local',
      timeSpentMinutes: 0,
    );

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

      // Should not throw; screen should show the search hint text, start with
      // an empty field, and render no result rows.
      expect(find.text('Search tasks…'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.byType(ListTile), findsNothing);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text ?? '', isEmpty);
    });

    testWidgets('query resets after leaving and reopening search', (tester) async {
      // Use a single ProviderScope so the same container persists across
      // navigations. Without autoDispose the provider would survive the pop
      // and the text would not clear on reopen.
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            searchResultsProvider.overrideWith(
              (_) => Stream.value(<SearchResult>[]),
            ),
            hiddenDoneMatchCountProvider.overrideWith((_) => Stream.value(0)),
            recentSearchesProvider.overrideWith(
              () => _EmptyRecentSearchesNotifier(),
            ),
          ],
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: const SizedBox.shrink(),
            routes: {'/search': (_) => const SearchScreen()},
          ),
        ),
      );

      navigatorKey.currentState!.pushNamed('/search');
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'inbox');
      await tester.pump();

      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      // Reopen within the same container — autoDispose must have reset the provider.
      navigatorKey.currentState!.pushNamed('/search');
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text ?? '', isEmpty);
    });
  });

  group('SearchScreen — hidden done-match hint', () {
    testWidgets('empty results with no hidden matches shows no hint',
        (tester) async {
      await tester.pumpWidget(_buildScreen());
      await tester.pump();

      // Type something and advance past the 300ms debounce so the empty state
      // is visible.
      await tester.enterText(find.byType(TextField), 'foo');
      await tester.pump(const Duration(milliseconds: 400)); // fire debounce
      await tester.pump(); // process stream emissions

      expect(find.textContaining('completed tasks'), findsNothing);
    });

    testWidgets('empty results with hidden matches shows hint with count',
        (tester) async {
      await tester.pumpWidget(
        _buildScreen(hiddenCountStream: Stream.value(3)),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'foo');
      await tester.pump(const Duration(milliseconds: 400)); // fire debounce
      await tester.pump(); // process stream emissions

      expect(find.textContaining('3 matches in completed tasks'), findsOneWidget);
    });

    testWidgets('hint uses singular form when count is 1', (tester) async {
      await tester.pumpWidget(
        _buildScreen(hiddenCountStream: Stream.value(1)),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'foo');
      await tester.pump(const Duration(milliseconds: 400)); // fire debounce
      await tester.pump(); // process stream emissions

      expect(find.textContaining('1 match in completed tasks'), findsOneWidget);
    });

    testWidgets('tapping hint sets includeDone to true', (tester) async {
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            searchResultsProvider.overrideWith(
              (_) => Stream.value(<SearchResult>[]),
            ),
            hiddenDoneMatchCountProvider.overrideWith(
              (_) => Stream.value(3),
            ),
            recentSearchesProvider.overrideWith(
              () => _EmptyRecentSearchesNotifier(),
            ),
          ],
          child: Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return const MaterialApp(home: SearchScreen());
            },
          ),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'foo');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(container.read(searchQueryProvider).includeDone, isFalse);

      await tester.tap(find.textContaining('matches in completed tasks'));
      await tester.pump();

      expect(container.read(searchQueryProvider).includeDone, isTrue);
    });

    testWidgets('hint not shown when results are non-empty', (tester) async {
      final fakeResult = SearchResult(
        todo: _fakeTodo(),
        tags: const [],
        matchedFields: const {},
        matchSnippet: null,
      );
      await tester.pumpWidget(
        _buildScreen(
          resultsStream: Stream.value([fakeResult]),
          hiddenCountStream: Stream.value(2),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'foo');
      await tester.pump(const Duration(milliseconds: 400)); // fire debounce
      await tester.pump(); // process stream emissions

      expect(find.textContaining('completed tasks'), findsNothing);
    });
  });
}
