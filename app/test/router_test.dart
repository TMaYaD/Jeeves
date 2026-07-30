/// Tests for the production router's redirect policy (issues #225, #595).
///
/// Two rules live in the one redirect. /focus must be unconditionally
/// accessible regardless of whether the day has been planned — planning is
/// entered explicitly via the Focus screen's "Plan the Day" button or the Nudge
/// banner, never via an automatic redirect ("planning done" derives from an open
/// session (ADR-0020), not a notifier, so there is no router state to toggle
/// here). And onboarding is enforced: a signed-in device whose store says it is
/// not enrolled cannot be anywhere but /enrolment, and nothing else can be
/// there.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/auth/session_gate.dart';
import 'package:jeeves/router.dart'
    show appRouter, appRouterRedirect, buildAppRouterRedirect;
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helpers.dart';

// Uses the production redirect function with stub routes so that any future
// regression (e.g. re-adding a /focus guard) is caught here.
GoRouter _buildRouter() => GoRouter(
      initialLocation: '/inbox',
      redirect: appRouterRedirect,
      routes: [
        GoRoute(
          path: '/inbox',
          builder: (_, _) => const Scaffold(body: Text('inbox')),
        ),
        GoRoute(
          path: '/focus',
          builder: (_, _) => const Scaffold(body: Text('focus')),
        ),
        GoRoute(
          path: '/focus-session-planning',
          builder: (_, _) => const Scaffold(body: Text('planning')),
        ),
      ],
    );

// Stub router with /register and /login routes that uses the redirect built
// with swsMode: true, exercising the redirect without a separate build flavour.
GoRouter _buildSwsRouter() => GoRouter(
      initialLocation: '/inbox',
      redirect: buildAppRouterRedirect(swsMode: true),
      routes: [
        GoRoute(
          path: '/inbox',
          builder: (_, _) => const Scaffold(body: Text('inbox')),
        ),
        GoRoute(
          path: '/login',
          builder: (_, _) => const Scaffold(body: Text('login')),
        ),
        GoRoute(
          path: '/register',
          builder: (_, _) => const Scaffold(body: Text('register')),
        ),
      ],
    );

// Stub router carrying the production redirect over a gate the test owns, plus
// the three locations the onboarding rule arbitrates between.
({GoRouter router, ValueNotifier<SessionGate> gate}) _buildGatedRouter(
  SessionGate initial,
) {
  final gate = ValueNotifier<SessionGate>(initial);
  addTearDown(gate.dispose);
  return (
    gate: gate,
    router: GoRouter(
      initialLocation: '/inbox',
      redirect: buildAppRouterRedirect(swsMode: false, gate: gate),
      refreshListenable: gate,
      routes: [
        GoRoute(
          path: '/inbox',
          builder: (_, _) => const Scaffold(body: Text('inbox')),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, _) => const Scaffold(body: Text('settings')),
        ),
        GoRoute(
          path: '/enrolment',
          builder: (_, _) => const Scaffold(body: Text('enrolment')),
        ),
      ],
    ),
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
      '/focus is accessible when planning is incomplete (no auto-redirect)',
      (tester) async {
    final router = _buildRouter();

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();

    router.go('/focus');
    await tester.pumpAndSettle();

    expect(find.text('focus'), findsOneWidget);
    expect(find.text('planning'), findsNothing);
  });

  testWidgets('/focus is accessible when planning is complete', (tester) async {
    final router = _buildRouter();

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();

    router.go('/focus');
    await tester.pumpAndSettle();

    expect(find.text('focus'), findsOneWidget);
    expect(find.text('planning'), findsNothing);
  });

  testWidgets('/focus-session-planning is still reachable explicitly',
      (tester) async {
    final router = _buildRouter();

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();

    router.go('/focus-session-planning');
    await tester.pumpAndSettle();

    expect(find.text('planning'), findsOneWidget);
    expect(find.text('focus'), findsNothing);
  });

  testWidgets('/register redirects to /login in SWS mode', (tester) async {
    final router = _buildSwsRouter();

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();

    router.go('/register');
    await tester.pumpAndSettle();

    expect(find.text('login'), findsOneWidget);
    expect(find.text('register'), findsNothing);
  });

  group('onboarding gate', () {
    testWidgets('needsEnrolment pins every location to /enrolment',
        (tester) async {
      final gated = _buildGatedRouter(SessionGate.needsEnrolment);

      await tester
          .pumpWidget(MaterialApp.router(routerConfig: gated.router));
      await tester.pumpAndSettle();

      // Even the initial location: a cold start on a half-founded session goes
      // straight to the resume controls.
      expect(find.text('enrolment'), findsOneWidget);

      gated.router.go('/settings');
      await tester.pumpAndSettle();
      expect(find.text('enrolment'), findsOneWidget);
      expect(find.text('settings'), findsNothing);
    });

    testWidgets('flipping the gate to needsEnrolment routes without navigation',
        (tester) async {
      // The refreshListenable contract: signing in from Settings must not leave
      // the user sitting on Settings with onboarding unfinished.
      final gated = _buildGatedRouter(SessionGate.signedOut);

      await tester
          .pumpWidget(MaterialApp.router(routerConfig: gated.router));
      await tester.pumpAndSettle();
      gated.router.go('/settings');
      await tester.pumpAndSettle();
      expect(find.text('settings'), findsOneWidget);

      gated.gate.value = SessionGate.needsEnrolment;
      await tester.pumpAndSettle();
      expect(find.text('enrolment'), findsOneWidget);
    });

    testWidgets('ready bounces /enrolment back to the app', (tester) async {
      final gated = _buildGatedRouter(SessionGate.ready);

      await tester
          .pumpWidget(MaterialApp.router(routerConfig: gated.router));
      await tester.pumpAndSettle();

      gated.router.go('/enrolment');
      await tester.pumpAndSettle();
      expect(find.text('inbox'), findsOneWidget);
      expect(find.text('enrolment'), findsNothing);
    });

    testWidgets('a completed ceremony lands in the app on its own',
        (tester) async {
      final gated = _buildGatedRouter(SessionGate.needsEnrolment);

      await tester
          .pumpWidget(MaterialApp.router(routerConfig: gated.router));
      await tester.pumpAndSettle();
      expect(find.text('enrolment'), findsOneWidget);

      gated.gate.value = SessionGate.ready;
      await tester.pumpAndSettle();
      expect(find.text('inbox'), findsOneWidget);
    });

    testWidgets('signedOut has no enrolment screen to reach', (tester) async {
      // There is no account to enrol against, so the route is not a place a
      // signed-out device can be — deep link or not.
      final gated = _buildGatedRouter(SessionGate.signedOut);

      await tester
          .pumpWidget(MaterialApp.router(routerConfig: gated.router));
      await tester.pumpAndSettle();

      gated.router.go('/enrolment');
      await tester.pumpAndSettle();
      expect(find.text('inbox'), findsOneWidget);

      // And everything else stays reachable: local-only is a supported mode.
      gated.router.go('/settings');
      await tester.pumpAndSettle();
      expect(find.text('settings'), findsOneWidget);
    });

    testWidgets('checking redirects nothing', (tester) async {
      // Session restore has not answered. Guessing either way would flash a
      // screen at the user for one frame on every cold start.
      final gated = _buildGatedRouter(SessionGate.checking);

      await tester
          .pumpWidget(MaterialApp.router(routerConfig: gated.router));
      await tester.pumpAndSettle();
      expect(find.text('inbox'), findsOneWidget);

      gated.router.go('/enrolment');
      await tester.pumpAndSettle();
      expect(find.text('enrolment'), findsOneWidget);

      gated.router.go('/settings');
      await tester.pumpAndSettle();
      expect(find.text('settings'), findsOneWidget);
    });

    test('/enrolment is a top-level route, outside the AppShell', () {
      // Outside on purpose: onboarding is not a drawer destination, and the
      // shell's own surfaces (indicator, capture) assume an enrolled-or-local
      // device rather than a session mid-ceremony.
      expect(
        appRouter.configuration.routes.whereType<GoRoute>().map((r) => r.path),
        contains('/enrolment'),
      );
      final shell =
          appRouter.configuration.routes.whereType<ShellRoute>().single;
      expect(
        shell.routes.whereType<GoRoute>().map((r) => r.path),
        isNot(contains('/enrolment')),
      );
    });
  });

  test('/done and /trash are registered inside the ShellRoute (issue #408)',
      () {
    // Inspects the production route table directly: the record surfaces must
    // render inside the AppShell (drawer navigation), not as top-level
    // full-screen routes.
    final shell =
        appRouter.configuration.routes.whereType<ShellRoute>().single;
    final paths = shell.routes.whereType<GoRoute>().map((r) => r.path).toSet();
    expect(paths, containsAll({'/done', '/trash'}));
  });
}
