import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/connectivity_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/screens/app_shell.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build just the AppShell with a dummy child, bypassing go_router's router
/// by providing the shell directly inside a GoRouterScope.
Widget _buildShellOnly({
  List<Todo> items = const [],
}) {
  return ProviderScope(
    overrides: [
      isOnlineProvider.overrideWith((_) => Stream.value(true)),
      inboxItemsProvider.overrideWith((_) => Stream.value(items)),
    ],
    child: MaterialApp(
      // Wrap in a GoRouter so that GoRouterState.of(context) works.
      home: Builder(
        builder: (ctx) {
          // Use a minimal GoRouter that renders AppShell directly.
          final router = GoRouter(
            initialLocation: '/inbox',
            routes: [
              ShellRoute(
                builder: (context, state, child) => AppShell(child: child),
                routes: [
                  GoRoute(
                    path: '/inbox',
                    builder: (_, _) =>
                        const Scaffold(body: Text('Inbox body')),
                  ),
                  GoRoute(
                    path: '/next-actions',
                    builder: (_, _) =>
                        const Scaffold(body: Text('Next Actions body')),
                  ),
                  GoRoute(
                    path: '/waiting-for',
                    builder: (_, _) =>
                        const Scaffold(body: Text('Waiting For body')),
                  ),
                  GoRoute(
                    path: '/someday-maybe',
                    builder: (_, _) =>
                        const Scaffold(body: Text('Someday body')),
                  ),
                ],
              ),
            ],
          );
          return MaterialApp.router(routerConfig: router);
        },
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(configureSqliteForTests);

  // Each test tears down after itself to avoid timer-related assertion failures
  // that can occur when a go_router GoRouter instance isn't fully drained.

  testWidgets('AppShell renders NavigationBar with four destinations',
      (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    expect(find.byKey(const Key('bottom_nav')), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(4));
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('AppShell shows Inbox content by default', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    expect(find.text('Inbox body'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('AppShell navigation destination labels are correct',
      (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    // Labels on the navigation bar
    expect(find.text('Inbox'), findsWidgets);
    expect(find.text('Next'), findsOneWidget);
    expect(find.text('Waiting'), findsOneWidget);
    expect(find.text('Someday'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('AppShell inbox badge displays item count', (tester) async {
    final items = List.generate(
      5,
      (i) => Todo(
        id: 'item-$i',
        title: 'Task $i',
        completed: false,
        createdAt: DateTime(2024, 1, 1),
        state: 'inbox',
        userId: 'local',
        timeSpentMinutes: 0,
      ),
    );
    await tester.pumpWidget(_buildShellOnly(items: items));
    await tester.pump();

    expect(find.text('5'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('AppShell navigates to Next Actions on tab tap', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Next Actions body'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('AppShell navigates to Waiting For on tab tap', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    await tester.tap(find.text('Waiting'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Waiting For body'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('AppShell navigates to Someday on tab tap', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    await tester.tap(find.text('Someday'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Someday body'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });
}
