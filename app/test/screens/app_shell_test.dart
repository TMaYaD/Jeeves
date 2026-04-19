import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/connectivity_provider.dart';
import 'package:jeeves/providers/daily_planning_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/screens/app_shell.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Mock notifiers — no-ops async operations that touch platform channels
// ---------------------------------------------------------------------------

class _MockDailyPlanningNotifier extends DailyPlanningNotifier {
  @override
  Future<void> reEnterPlanning() async {}
}

class _MockAuthNotifier extends AuthNotifier {
  _MockAuthNotifier({this.onLogout});
  final VoidCallback? onLogout;

  @override
  Future<String?> build() async => null; // no FlutterSecureStorage call

  @override
  Future<void> logout() async => onLogout?.call();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Widget _buildShellOnly({
  List<Todo> items = const [],
  VoidCallback? onLogout,
}) {
  return ProviderScope(
    overrides: [
      authTokenProvider.overrideWith(() => _MockAuthNotifier(onLogout: onLogout)),
      isOnlineProvider.overrideWith((_) => Stream.value(true)),
      inboxItemsProvider.overrideWith((_) => Stream.value(items)),
      nextActionsProvider.overrideWith((_) => Stream.value([])),
      waitingForProvider.overrideWith((_) => Stream.value([])),
      blockedTasksProvider.overrideWith((_) => Stream.value([])),
      somedayMaybeProvider.overrideWith((_) => Stream.value([])),
      scheduledProvider.overrideWith((_) => Stream.value([])),
      projectTagsProvider.overrideWith((_) => Stream.value([])),
      contextTagsProvider.overrideWith((_) => Stream.value([])),
      todaySelectedTasksProvider.overrideWith((_) => Stream.value([])),
      dailyPlanningProvider
          .overrideWith(() => _MockDailyPlanningNotifier()),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (ctx) {
          final router = GoRouter(
            initialLocation: '/inbox',
            routes: [
              // /planning is outside the ShellRoute — matches production router
              // where PlanningRitualScreen renders without the AppShell wrapper.
              GoRoute(
                path: '/planning',
                builder: (_, _) => const Scaffold(body: Text('Planning body')),
              ),
              ShellRoute(
                builder: (context, state, child) => AppShell(child: child),
                routes: [
                  GoRoute(
                    path: '/inbox',
                    builder: (context, _) => Scaffold(
                      body: Row(children: [
                        Builder(
                          builder: (innerCtx) => IconButton(
                            icon: const Icon(Icons.menu),
                            onPressed: () {
                              innerCtx.findRootAncestorStateOfType<ScaffoldState>()?.openDrawer();
                            },
                          ),
                        ),
                        const Text('Inbox body')
                      ]),
                    ),
                  ),
                  GoRoute(
                    path: '/next-actions',
                    builder: (_, _) => const Scaffold(body: Text('Next Actions body')),
                  ),
                  GoRoute(
                    path: '/waiting-for',
                    builder: (_, _) => const Scaffold(body: Text('Waiting For body')),
                  ),
                  GoRoute(
                    path: '/someday-maybe',
                    builder: (_, _) => const Scaffold(body: Text('Someday body')),
                  ),
                  GoRoute(
                    path: '/blocked',
                    builder: (_, _) => const Scaffold(body: Text('Blocked body')),
                  ),
                  GoRoute(
                    path: '/scheduled',
                    builder: (_, _) => const Scaffold(body: Text('Scheduled body')),
                  ),
                  GoRoute(
                    path: '/focus',
                    builder: (_, _) => const Scaffold(body: Text('Focus body')),
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

  testWidgets('AppShell renders CustomDrawer that can be opened', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    // Drawer is initially hidden
    expect(find.text('Inbox'), findsNothing);

    // Open drawer via the menu button added in the mock child scaffold
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('Inbox'), findsWidgets);
    // Scroll the drawer to reveal sections further down.
    await tester.drag(find.byType(Drawer), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('PROJECTS'), findsOneWidget);
  });

  testWidgets('AppShell shows Inbox content by default', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    expect(find.text('Inbox body'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('AppShell navigation drawer labels are correct', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('Inbox'), findsOneWidget); // Plus "Inbox body" outside, but 'Inbox' list tile
    expect(find.text('Next Actions'), findsOneWidget);
    expect(find.text('Scheduled'), findsOneWidget);
    expect(find.text('Waiting For'), findsOneWidget);
    expect(find.text('Someday/Maybe'), findsOneWidget);
    expect(find.text('Focus'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('AppShell navigates to Next Actions on drawer tap', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Next Actions'));
    await tester.pumpAndSettle();

    expect(find.text('Next Actions body'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('AppShell navigates to Waiting For on drawer tap', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Waiting For'));
    await tester.pumpAndSettle();

    expect(find.text('Waiting For body'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('AppShell navigates to Someday on drawer tap', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Someday/Maybe'));
    await tester.pumpAndSettle();

    expect(find.text('Someday body'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('AppShell navigates to Blocked on drawer tap', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Blocked'));
    await tester.pumpAndSettle();

    expect(find.text('Blocked body'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('AppShell navigates to Scheduled on drawer tap', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Scheduled'));
    await tester.pumpAndSettle();

    expect(find.text('Scheduled body'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('AppShell Focus navigates to /focus on tap', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Focus'));
    await tester.pumpAndSettle();

    expect(find.text('Focus body'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('AppShell drawer shows Settings tile', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    // Scroll to reveal the Settings tile at the bottom.
    await tester.drag(find.byType(Drawer), const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings_tile')), findsOneWidget);
  });
}
