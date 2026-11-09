import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/screens/waiting_for/waiting_for_screen.dart';
import 'package:jeeves/widgets/outcome_row.dart';

void main() {
  testWidgets('grouped Outcomes share metadata and retain detail routing', (
    tester,
  ) async {
    final todo = Todo(
      id: 'report',
      title: 'Report',
      userId: 'local',
      createdAt: DateTime(2030),
      clarified: true,
      intent: 'next',
      energyLevel: 'high',
      timeEstimate: 125,
      dueDate: DateTime(2030, 3, 15),
    );
    String? openedOutcomeId;
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const WaitingForScreen()),
        GoRoute(
          path: '/task/:id',
          builder: (_, state) {
            openedOutcomeId = state.pathParameters['id'];
            return const Scaffold(body: Text('Detail'));
          },
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inboxItemsProvider.overrideWith((_) => Stream.value([])),
          waitingListGroupedProvider.overrideWith(
            (_) => Stream.value({
              const Tag(
                id: 'person',
                name: 'Trixy',
                type: 'person',
                userId: 'local',
              ): [
                todo,
              ],
            }),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    expect(find.text('Trixy'), findsOneWidget);
    expect(find.byType(OutcomeRow), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
    expect(find.text('Mar 15, 2030'), findsOneWidget);
    await tester.tap(find.text('2h 5m'));
    await tester.pumpAndSettle();
    expect(openedOutcomeId, 'report');
    await tester.pumpWidget(const SizedBox());
    router.dispose();
  });
}
