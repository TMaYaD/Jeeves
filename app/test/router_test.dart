/// Tests for the production router's redirect policy (issues #225, #595, #673).
///
/// One rule, applied twice. **The router never sends the user somewhere they
/// did not ask to go.** /focus is unconditionally accessible regardless of
/// whether the day has been planned — planning is entered explicitly via the
/// Focus screen's "Plan the Day" button or the Nudge banner ("planning done"
/// derives from an open session (ADR-0020), not a notifier, so there is no
/// router state to toggle here). And enrolment is opt-in: a signed-in device
/// whose store says it is not enrolled runs the app exactly like any other, and
/// reaches `/enrolment` only by navigating there itself.
///
/// The redirect's remaining job is negative — keeping `/enrolment` out of reach
/// of the two sessions it cannot mean anything for (signed out: no account to
/// enrol against; enrolled: already done). Bouncing *off* a route is not routing
/// *to* one.
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
// the three locations the enrolment rule arbitrates between.
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

  group('enrolment is opt-in', () {
    testWidgets('an unenrolled session reaches the app, not the ceremony',
        (tester) async {
      // The defect this group exists for: the user opened the app and was put
      // in the enrolment ceremony with no way back to their data.
      final gated = _buildGatedRouter(SessionGate.signedInNotEnrolled);

      await tester
          .pumpWidget(MaterialApp.router(routerConfig: gated.router));
      await tester.pumpAndSettle();

      expect(find.text('inbox'), findsOneWidget);
      expect(find.text('enrolment'), findsNothing);

      gated.router.go('/settings');
      await tester.pumpAndSettle();
      expect(find.text('settings'), findsOneWidget);
    });

    testWidgets('an unenrolled session can navigate to /enrolment deliberately',
        (tester) async {
      // Opt-in, not unreachable. Settings and the first-launch card both send
      // the user here on purpose, and the route has to accept them.
      final gated = _buildGatedRouter(SessionGate.signedInNotEnrolled);

      await tester
          .pumpWidget(MaterialApp.router(routerConfig: gated.router));
      await tester.pumpAndSettle();

      gated.router.go('/enrolment');
      await tester.pumpAndSettle();
      expect(find.text('enrolment'), findsOneWidget);
    });

    testWidgets('signing in does not move the user off where they were',
        (tester) async {
      // The refreshListenable still fires; what it must no longer do is carry
      // the user away. Signing in from Settings leaves them on Settings.
      final gated = _buildGatedRouter(SessionGate.signedOut);

      await tester
          .pumpWidget(MaterialApp.router(routerConfig: gated.router));
      await tester.pumpAndSettle();
      gated.router.go('/settings');
      await tester.pumpAndSettle();
      expect(find.text('settings'), findsOneWidget);

      gated.gate.value = SessionGate.signedInNotEnrolled;
      await tester.pumpAndSettle();
      expect(find.text('settings'), findsOneWidget);
      expect(find.text('enrolment'), findsNothing);
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
      // The one place the router still moves somebody: the ceremony screen has
      // nothing left to say once the device is enrolled, so finishing it hands
      // the user back to the app rather than stranding them on a dead surface.
      final gated = _buildGatedRouter(SessionGate.signedInNotEnrolled);

      await tester
          .pumpWidget(MaterialApp.router(routerConfig: gated.router));
      await tester.pumpAndSettle();
      gated.router.go('/enrolment');
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
      // Outside on purpose: the ceremony is not a drawer destination, and the
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
