import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/connectivity_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/screens/common/gtd_list_screen.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a standalone GtdListScreen with a custom stream, bypassing routing.
Widget _buildScreen(Stream<List<Todo>> stream) {
  final provider = StreamProvider<List<Todo>>((_) => stream);
  return ProviderScope(
    overrides: [
      isOnlineProvider.overrideWith((_) => Stream.value(true)),
      inboxItemsProvider.overrideWith((_) => Stream.value([])),
    ],
    child: MaterialApp(
      home: GtdListScreen(title: 'Test List', provider: provider),
    ),
  );
}

Todo _todo(String id, String title, {String state = 'next_action'}) => Todo(
      id: id,
      title: title,
      completed: false,
      createdAt: DateTime(2024, 1, 1),
      state: state,
      userId: kLocalUserId,
      timeSpentMinutes: 0,
    );

void main() {
  setUpAll(configureSqliteForTests);

  group('GtdListScreen', () {
    testWidgets('shows title', (tester) async {
      await tester.pumpWidget(_buildScreen(Stream.value([])));
      await tester.pump();
      expect(find.text('Test List'), findsOneWidget);
    });

    testWidgets('shows empty state message when no items', (tester) async {
      await tester.pumpWidget(_buildScreen(Stream.value([])));
      await tester.pump();
      expect(find.textContaining('Nothing here yet'), findsOneWidget);
    });

    testWidgets('renders todo titles', (tester) async {
      final items = [
        _todo('a', 'Buy coffee'),
        _todo('b', 'Fix bug'),
      ];
      await tester.pumpWidget(_buildScreen(Stream.value(items)));
      await tester.pump();

      expect(find.text('Buy coffee'), findsOneWidget);
      expect(find.text('Fix bug'), findsOneWidget);
    });

    testWidgets('tapping item navigates to /task/:id', (tester) async {
      String? pushedRoute;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) {
              final provider =
                  StreamProvider<List<Todo>>((_) => Stream.value([_todo('x', 'Do something')]));
              return GtdListScreen(title: 'List', provider: provider);
            },
          ),
          GoRoute(
            path: '/task/:id',
            builder: (context, state) {
              pushedRoute = state.pathParameters['id'];
              return const Scaffold(body: Text('Detail'));
            },
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isOnlineProvider.overrideWith((_) => Stream.value(true)),
            inboxItemsProvider.overrideWith((_) => Stream.value([])),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Do something'));
      await tester.pumpAndSettle();

      expect(pushedRoute, 'x');
      expect(find.text('Detail'), findsOneWidget);
    });
  });
}
