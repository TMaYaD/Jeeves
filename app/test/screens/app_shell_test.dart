import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/models/focus_session_planning_settings.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/connectivity_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/focus_session_planning_settings_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/nudge_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/screens/app_shell.dart';
import 'package:jeeves/widgets/capture/capture_fab.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Mock notifiers — no-ops async operations that touch platform channels
// ---------------------------------------------------------------------------

class _MockFocusSessionPlanningNotifier extends FocusSessionPlanningNotifier {
  @override
  Future<void> reEnterPlanning() async {}

  @override
  Future<void> skipPlanningToday() async {}

  @override
  Future<void> snoozePlanningNotification(int minutes) async {}
}

class _MockFocusSessionPlanningSettingsNotifier
    extends FocusSessionPlanningSettingsNotifier {
  _MockFocusSessionPlanningSettingsNotifier(this._settings);
  final FocusSessionPlanningSettings _settings;

  @override
  FocusSessionPlanningSettings build() => _settings;
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
  List<Capture> items = const [],
  VoidCallback? onLogout,
  FocusSessionPlanningSettings planningSettings =
      const FocusSessionPlanningSettings(bannerEnabled: false),
}) {
  return ProviderScope(
    overrides: [
      authTokenProvider.overrideWith(() => _MockAuthNotifier(onLogout: onLogout)),
      isOnlineProvider.overrideWith((_) => Stream.value(true)),
      inboxItemsProvider.overrideWith((_) => Stream.value(items)),
      nextProvider.overrideWith((_) => Stream.value([])),
      waitingForProvider.overrideWith((_) => Stream.value([])),
      maybeProvider.overrideWith((_) => Stream.value([])),
      projectTagsProvider.overrideWith((_) => Stream.value([])),
      contextTagsProvider.overrideWith((_) => Stream.value([])),
      focusSessionPlanningSelectedTasksProvider.overrideWith((_) => Stream.value([])),
      focusSessionPlanningProvider
          .overrideWith(() => _MockFocusSessionPlanningNotifier()),
      focusSessionPlanningSettingsProvider.overrideWith(
          () => _MockFocusSessionPlanningSettingsNotifier(planningSettings)),
      // AppShell now mounts NudgeBanner; the banner reads the Nudge queue,
      // which transitively depends on the database / synced-prefs that this
      // test does not mock. Force the queue empty so the banner is a no-op
      // and the test's focus on shell structure is preserved.
      nudgeQueueProvider.overrideWith((ref) => const <RitualId>[]),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (ctx) {
          final router = GoRouter(
            initialLocation: '/inbox',
            routes: [
              // /focus-session-planning is outside the ShellRoute — matches
              // production router where FocusSessionPlanningScreen renders
              // without the AppShell wrapper.
              GoRoute(
                path: '/focus-session-planning',
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
                    path: '/focus',
                    builder: (_, _) => const Scaffold(body: Text('Focus body')),
                  ),
                  GoRoute(
                    path: '/done',
                    builder: (_, _) => const Scaffold(body: Text('Done body')),
                  ),
                  GoRoute(
                    path: '/trash',
                    builder: (_, _) => const Scaffold(body: Text('Trash body')),
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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

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
    expect(find.text('Waiting For'), findsOneWidget);
    expect(find.text('Maybe'), findsOneWidget);
    // The execution home's user-facing title is "Now" (design review:
    // Focus ↔ Now); the route stays /focus.
    expect(find.text('Now'), findsOneWidget);
    expect(find.text('Focus'), findsNothing);
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

  testWidgets('AppShell navigates to Maybe on drawer tap', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Maybe'));
    await tester.pumpAndSettle();

    expect(find.text('Someday body'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('AppShell "Now" entry navigates to /focus on tap', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Now'));
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

  testWidgets(
      'AppShell drawer shows the record group (Done, Trash) at the bottom '
      'of the scrollable nav column, above Settings, without count badges',
      (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    // Scroll the nav column so the record group at its end is visible.
    await tester.drag(find.byType(Drawer), const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Trash'), findsOneWidget);
    // Record group sits above the fixed Settings tile.
    expect(
      tester.getTopLeft(find.text('Trash')).dy <
          tester.getTopLeft(find.byKey(const Key('settings_tile'))).dy,
      isTrue,
    );
    // Record size is not actionable signal — no count badges.
    expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Done')).trailing,
        isNull);
    expect(
        tester.widget<ListTile>(find.widgetWithText(ListTile, 'Trash')).trailing,
        isNull);
  });

  testWidgets('AppShell navigates to Done on drawer tap', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Drawer), const Offset(0, -600));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.text('Done body'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('AppShell navigates to Trash on drawer tap', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Drawer), const Offset(0, -600));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Trash'));
    await tester.pumpAndSettle();

    expect(find.text('Trash body'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  // -------------------------------------------------------------------------
  // Global capture FAB (#458)
  // -------------------------------------------------------------------------

  testWidgets('capture FAB is suppressed on the Inbox (QuickAddBar owns it)',
      (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    expect(find.text('Inbox body'), findsOneWidget);
    expect(find.byType(CaptureFab), findsNothing);
  });

  // Every non-Inbox shell route carries the FAB. Driven off the drawer so the
  // production route-aware suppression is exercised end to end.
  for (final (label, body) in const [
    ('Now', 'Focus body'),
    ('Next Actions', 'Next Actions body'),
    ('Waiting For', 'Waiting For body'),
    ('Maybe', 'Someday body'),
  ]) {
    testWidgets('capture FAB is present on the $label route', (tester) async {
      await tester.pumpWidget(_buildShellOnly());
      await tester.pump();

      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();

      expect(find.text(body), findsOneWidget);
      expect(find.byType(CaptureFab), findsOneWidget);
    });
  }

  // Done / Trash live below the drawer's scroll fold, so each needs its own
  // fresh pump — only the Inbox mock route carries a menu button to reopen the
  // drawer with.
  for (final (label, body) in const [
    ('Done', 'Done body'),
    ('Trash', 'Trash body'),
  ]) {
    testWidgets('capture FAB is present on the $label route', (tester) async {
      await tester.pumpWidget(_buildShellOnly());
      await tester.pump();

      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Drawer), const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();

      expect(find.text(body), findsOneWidget);
      expect(find.byType(CaptureFab), findsOneWidget);
    });
  }
}
