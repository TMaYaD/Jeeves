import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/models/focus_session_planning_settings.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/focus_session_planning_settings_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/nudge_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/screens/app_shell.dart';
import 'package:jeeves/widgets/app_title_bar/app_title_bar.dart';
import 'package:jeeves/widgets/nudge_banner.dart';
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
  String initialLocation = '/inbox',
  FocusSessionPlanningSettings planningSettings =
      const FocusSessionPlanningSettings(bannerEnabled: false),
}) {
  return ProviderScope(
    overrides: [
      authTokenProvider.overrideWith(() => _MockAuthNotifier(onLogout: onLogout)),
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
            initialLocation: initialLocation,
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
                    // Plain body — the drawer opens from the shared title bar's
                    // leading slot now, not a per-screen menu button.
                    builder: (_, _) => const Scaffold(body: Text('Inbox body')),
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

    // Drawer is initially hidden — the bar titles the route 'Inbox', so anchor
    // on a drawer-only marker (the Search tile's Ctrl+K hint) instead.
    expect(find.text('Ctrl+K'), findsNothing);

    // Open drawer via the shared title bar's leading (drawer) slot.
    await tester.tap(find.byKey(appTitleBarLeadingKey));
    await tester.pumpAndSettle();

    expect(find.text('Ctrl+K'), findsOneWidget);
    // The bar's route title and the drawer's Inbox tile both read 'Inbox'.
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

  testWidgets('AppShell drawer entries navigate to their routes',
      (tester) async {
    // One case per drawer destination. "Now" is the user-facing label for the
    // execution home (design review: Focus ↔ Now); its route stays /focus, so
    // tapping it lands on 'Focus body'. Done and Trash sit in the record group
    // at the bottom of the scrollable nav column, so their tiles need the
    // drawer scrolled before they are tappable.
    const cases = <({String label, String body, bool scroll})>[
      (label: 'Next Actions', body: 'Next Actions body', scroll: false),
      (label: 'Waiting For', body: 'Waiting For body', scroll: false),
      (label: 'Maybe', body: 'Someday body', scroll: false),
      (label: 'Now', body: 'Focus body', scroll: false),
      (label: 'Done', body: 'Done body', scroll: true),
      (label: 'Trash', body: 'Trash body', scroll: true),
    ];

    for (final c in cases) {
      await tester.pumpWidget(_buildShellOnly());
      await tester.pump();

      await tester.tap(find.byKey(appTitleBarLeadingKey));
      await tester.pumpAndSettle();

      if (c.scroll) {
        await tester.drag(find.byType(Drawer), const Offset(0, -600));
        await tester.pumpAndSettle();
      }

      await tester.tap(find.text(c.label));
      await tester.pumpAndSettle();

      expect(find.text(c.body), findsOneWidget,
          reason: 'tapping ${c.label} should navigate to ${c.body}');
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  testWidgets('AppShell drawer shows Settings tile', (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    await tester.tap(find.byKey(appTitleBarLeadingKey));
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

    await tester.tap(find.byKey(appTitleBarLeadingKey));
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

  testWidgets('the shared bar titles each shell route from the route→title map',
      (tester) async {
    for (final entry in shellRouteTitles.entries) {
      await tester.pumpWidget(_buildShellOnly(initialLocation: entry.key));
      await tester.pump();

      expect(
        find.descendant(
          of: find.byType(AppTitleBar),
          matching: find.text(entry.value),
        ),
        findsOneWidget,
        reason: '${entry.key} should carry the bar title "${entry.value}"',
      );
    }
  });

  testWidgets('the shell bar uses the drawer leading on shell routes',
      (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    final bar = tester.widget<AppTitleBar>(find.byType(AppTitleBar));
    expect(bar.leading, AppTitleBarLeading.drawer);
  });

  testWidgets('NudgeBanner renders inside the shell body below the bar',
      (tester) async {
    await tester.pumpWidget(_buildShellOnly());
    await tester.pump();

    expect(find.byType(NudgeBanner), findsOneWidget);
  });

  group('inbox unprocessed-count badge', () {
    testWidgets('shows the count on /inbox when there are captures',
        (tester) async {
      await tester.pumpWidget(_buildShellOnly(items: [
        Capture(
          id: 'a',
          title: 'Buy milk',
          notes: null,
          captureSource: 'manual',
          createdAt: DateTime(2024, 1, 1),
          clarifiedAt: null,
          updatedAt: null,
          userId: 'local',
        ),
        Capture(
          id: 'b',
          title: 'Call dentist',
          notes: null,
          captureSource: 'manual',
          createdAt: DateTime(2024, 1, 1),
          clarifiedAt: null,
          updatedAt: null,
          userId: 'local',
        ),
      ]));
      await tester.pump();

      expect(find.byKey(appTitleBarBadgeKey), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(appTitleBarBadgeKey),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
      final bar = tester.widget<AppTitleBar>(find.byType(AppTitleBar));
      expect(bar.badge?.semanticsLabel, '2 unprocessed captures');
    });

    testWidgets('is absent on /inbox when there are no captures',
        (tester) async {
      await tester.pumpWidget(_buildShellOnly());
      await tester.pump();

      expect(find.byKey(appTitleBarBadgeKey), findsNothing);
    });

    testWidgets('is absent on non-inbox routes even with captures',
        (tester) async {
      await tester.pumpWidget(_buildShellOnly(
        initialLocation: '/next-actions',
        items: [
          Capture(
            id: 'a',
            title: 'Buy milk',
            notes: null,
            captureSource: 'manual',
            createdAt: DateTime(2024, 1, 1),
            clarifiedAt: null,
            updatedAt: null,
            userId: 'local',
          ),
        ],
      ));
      await tester.pump();

      expect(find.byKey(appTitleBarBadgeKey), findsNothing);
    });
  });
}
