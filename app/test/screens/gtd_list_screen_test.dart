import 'dart:async';

import 'package:flutter/material.dart';
import 'package:jeeves/widgets/outcome_multi_select.dart';
import 'package:jeeves/widgets/outcome_row.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/providers/place_gate_provider.dart';
import 'package:jeeves/providers/place_hours_provider.dart';
import 'package:jeeves/screens/common/gtd_list_screen.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/screens/next/next_screen.dart';
import 'package:jeeves/screens/someday_maybe/someday_maybe_screen.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a standalone GtdListScreen with a custom stream, bypassing routing.
Widget _buildScreen(Stream<List<Todo>> stream) {
  final provider = StreamProvider<List<Todo>>((_) => stream);
  return ProviderScope(
    overrides: [
      inboxItemsProvider.overrideWith((_) => Stream.value([])),
    ],
    child: MaterialApp(
      home: GtdListScreen(provider: provider),
    ),
  );
}

Todo _todo(String id, String title) => Todo(
      id: id,
      title: title,
      doneAt: null,
      createdAt: DateTime(2024, 1, 1),
      intent: 'next',
      userId: kLocalUserId,
    );

void main() {
  setUpAll(configureSqliteForTests);

  group('GtdListScreen', () {
    for (final entry in <(Widget, String)>[
      (const NextScreen(), 'Nothing on Next'),
      (const SomedayMaybeScreen(), 'Nothing in Someday/Maybe'),
    ]) {
      testWidgets('empty List says ${entry.$2}', (tester) async {
        await tester.pumpWidget(ProviderScope(
          overrides: [
            nextProvider.overrideWith((_) => Stream.value([])),
            somedayMaybeProvider.overrideWith((_) => Stream.value([])),
            inboxItemsProvider.overrideWith((_) => Stream.value([])),
            // The Next screen reads the places for the rows and for the calm
            // line about not knowing where the user is.
            currentPlacesProvider.overrideWith((_) => Stream.value(const {})),
            placeHoursProvider.overrideWith((_) => Stream.value(const {})),
          ],
          child: MaterialApp(home: entry.$1),
        ));
        await tester.pump();
        expect(find.text(entry.$2), findsOneWidget);
      });
    }

    testWidgets('shows empty state message when no items', (tester) async {
      await tester.pumpWidget(_buildScreen(Stream.value([])));
      await tester.pump();
      expect(find.textContaining('Nothing here yet'), findsOneWidget);
    });

    testWidgets('renders the todo titles', (tester) async {
      // The list title lives in the shared AppShell title bar now;
      // this screen renders standalone with no header of its own.
      final items = [
        _todo('a', 'Buy coffee'),
        _todo('b', 'Fix bug'),
      ];
      await tester.pumpWidget(_buildScreen(Stream.value(items)));
      await tester.pump();

      expect(find.byType(OutcomeRow), findsNWidgets(2));
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
              return GtdListScreen(provider: provider);
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

    testWidgets('a selection survives the list reloading', (tester) async {
      final controller = StreamController<List<Todo>>.broadcast();
      addTearDown(controller.close);
      final trigger = NotifierProvider<_ReloadTrigger, int>(_ReloadTrigger.new);
      final provider = StreamProvider<List<Todo>>((ref) {
        ref.watch(trigger);
        return controller.stream;
      });

      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(home: GtdListScreen(provider: provider)),
      ));
      controller.add([_todo('t1', 'First')]);
      await tester.pumpAndSettle();

      // The user selects the row.
      await tester.longPress(find.text('First'));
      await tester.pumpAndSettle();
      expect(find.byType(OutcomeSelectionBar), findsOneWidget);

      // The list reloads — the same row, and the list is reloading rather
      // than resolved.
      final container =
          ProviderScope.containerOf(tester.element(find.byType(GtdListScreen)));
      container.read(trigger.notifier).bump();
      await tester.pump();
      expect(container.read(provider).isLoading, isTrue);
      controller.add([_todo('t1', 'First')]);
      await tester.pumpAndSettle();

      // The selection is still there: a list that is reloading still holds
      // the rows it had.
      expect(find.byType(OutcomeSelectionBar), findsOneWidget);
    });
  });
}

/// Counts the reloads of the list under test.
class _ReloadTrigger extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}
