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

      // Onboarding is one decision, taken here rather than by each screen's
      // success handler: sign-in and sign-up both just `go('/inbox')` and this
      // routes them, a deep link cannot skip enrolment, and a cold start that
      // restores a half-founded session lands straight on the resume controls.
      switch ((gate ?? sessionGateNotifier).value) {
        case SessionGate.checking:
          // Nothing is known yet; guessing would flash onboarding at an
          // enrolled device.
          return null;
        case SessionGate.needsEnrolment:
          return state.matchedLocation == EnrolmentCeremonyScreen.routePath
              ? null
              : EnrolmentCeremonyScreen.routePath;
        case SessionGate.signedOut:
        case SessionGate.ready:
          // The screen has no reason to exist for either: a signed-out device
          // has no account to enrol against, and an enrolled one is done.
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
  // Without this the gate would only be consulted on the next navigation, so a
  // sign-in from Settings would leave the user sitting on Settings with
  // onboarding unfinished.
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
    // Onboarding, not a settings page: a signed-in device that is not enrolled
    // is routed here and cannot leave until it is (or signs out).
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
