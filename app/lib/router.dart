import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import 'auth/auth_mode.dart';
import 'auth/session_gate.dart';
import 'screens/app_shell.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/register_screen.dart';
import 'screens/done/done_screen.dart';
import 'screens/enrolment/enrolment_ceremony_screen.dart';
import 'screens/inbox/inbox_screen.dart';
import 'screens/next/next_screen.dart';
import 'screens/periodic_review/periodic_review_screen.dart';
import 'screens/planning/focus_session_planning_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/someday_maybe/someday_maybe_screen.dart';
import 'screens/sync_health/sync_health_screen.dart';
import 'screens/task_detail/task_detail_screen.dart';
import 'screens/trash/trash_screen.dart';
import 'screens/waiting_for/waiting_for_screen.dart';
import 'screens/active_focus_screen.dart';
import 'screens/focus_screen.dart';
import 'screens/import_screen.dart';
import 'screens/inbox/inbox_clarify_screen.dart';
import 'screens/search/search_screen.dart';
import 'screens/shutdown/shutdown_ritual_screen.dart';

/// Creates the router redirect function with a configurable [swsMode] flag and
/// session [gate].
///
/// The production router uses [appRouterRedirect], which bakes in the
/// [isSwsMode] compile-time constant and the live [sessionGateNotifier]. This
/// factory lets tests drive both without a build flavour and without a
/// `ProviderScope`.
GoRouterRedirect buildAppRouterRedirect({
  bool swsMode = isSwsMode,
  ValueListenable<SessionGate>? gate,
}) =>
    (context, state) {
      // In SWS mode the wallet is the identity — there is no email signup, so
      // /register is meaningless. Bounce any stale deep link / nav entry back to
      // /login where the "Connect wallet" flow lives.
      if (swsMode && state.matchedLocation == '/register') return '/login';

      // **Nothing here routes anybody *to* enrolment.** Enrolment is opt-in
      // (issue #673): local-only is a supported steady state, so a signed-in,
      // un-enrolled device runs the app like any other and reaches the ceremony
      // only by navigating there itself — from Settings, or from the
      // first-launch card. The router used to pin every location to
      // `/enrolment`, which on a device with no network was a trap with no way
      // back to the user's own data.
      //
      // What remains is the negative half: keeping the ceremony out of reach of
      // the two sessions it cannot mean anything for. Bouncing *off* a route is
      // not routing *to* one.
      switch ((gate ?? sessionGateNotifier).value) {
        case SessionGate.checking:
        case SessionGate.signedInNotEnrolled:
          // Restore has not answered, or it has and the answer changes nothing
          // about where the user may be.
          return null;
        case SessionGate.signedOut:
        case SessionGate.ready:
          // The screen has nothing to say to either: a signed-out device has no
          // account to enrol against, and an enrolled one is done — which is
          // also how a completed ceremony hands the user back to the app.
          return state.matchedLocation == EnrolmentCeremonyScreen.routePath
              ? '/inbox'
              : null;
      }
      // Unauthenticated users are deliberately *not* forced to /login: the app
      // is fully usable local-only, so signing out from Settings stays on
      // Settings and /login is always something the user can back out of.
    };

/// Top-level redirect callback used by [appRouter].
///
/// Exported as a named symbol so router unit tests can wire up a stub-route
/// router with the real redirect logic, catching regressions without needing
/// every screen's provider dependencies.
final GoRouterRedirect appRouterRedirect = buildAppRouterRedirect();

final appRouter = GoRouter(
  initialLocation: '/inbox',
  redirect: appRouterRedirect,
  // Kept for the one move the gate still makes: a completed ceremony has to
  // hand the user back to the app, and without this the bounce would wait for
  // the next navigation.
  refreshListenable: sessionGateNotifier,
  routes: [
    GoRoute(
      path: '/login',
      builder: (context, state) => const LoginScreen(),
    ),
    GoRoute(
      path: '/register',
      builder: (context, state) => const RegisterScreen(),
    ),
    GoRoute(
      path: '/focus-session-planning',
      builder: (context, state) => const FocusSessionPlanningScreen(),
    ),
    GoRoute(
      path: '/periodic-review',
      builder: (context, state) => const PeriodicReviewScreen(),
    ),
    GoRoute(
      path: '/shutdown',
      builder: (context, state) => const ShutdownRitualScreen(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
    // Outside the shell, like /settings: it is an account of what happened
    // rather than a place in the app. Nothing routes here on its own — the
    // drawer indicator pushes it, and only while there is something to report.
    GoRoute(
      path: SyncHealthScreen.routePath,
      builder: (context, state) => const SyncHealthScreen(),
    ),
    // Outside the shell, like /settings: a ceremony rather than a place in the
    // app. Nothing routes here — Settings and the first-launch card push it, on
    // purpose, and the user can back out of it at any point.
    GoRoute(
      path: EnrolmentCeremonyScreen.routePath,
      builder: (context, state) => const EnrolmentCeremonyScreen(),
    ),
    ShellRoute(
      builder: (context, state, child) => AppShell(child: child),
      routes: [
        GoRoute(
          path: '/inbox',
          builder: (context, state) => const InboxScreen(),
        ),
        GoRoute(
          path: '/next-actions',
          builder: (context, state) => const NextScreen(),
        ),
        GoRoute(
          path: '/waiting-for',
          builder: (context, state) => const WaitingForScreen(),
        ),
        GoRoute(
          path: '/someday-maybe',
          builder: (context, state) => const SomedayMaybeScreen(),
        ),
        GoRoute(
          path: '/focus',
          builder: (context, state) => const FocusScreen(),
        ),
        GoRoute(
          path: '/done',
          builder: (context, state) => const DoneScreen(),
        ),
        GoRoute(
          path: '/trash',
          builder: (context, state) => const TrashScreen(),
        ),
      ],
    ),
    GoRoute(
      path: '/inbox/:id/clarify',
      builder: (context, state) => InboxClarifyScreen(
        captureId: state.pathParameters['id']!,
      ),
    ),
    GoRoute(
      path: '/task/:id',
      builder: (context, state) => TaskDetailScreen(
        todoId: state.pathParameters['id']!,
      ),
    ),
    GoRoute(
      path: '/focus/active',
      builder: (context, state) => const ActiveFocusScreen(),
    ),
    GoRoute(
      path: '/import',
      builder: (context, state) => const ImportScreen(),
    ),
    GoRoute(
      path: '/search',
      builder: (context, state) => const SearchScreen(),
    ),
  ],
);
