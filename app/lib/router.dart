import 'package:go_router/go_router.dart';

import 'auth/auth_mode.dart';
import 'providers/daily_planning_provider.dart';
import 'screens/app_shell.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/register_screen.dart';
import 'screens/inbox/inbox_screen.dart';
import 'screens/next_actions/next_actions_screen.dart';
import 'screens/planning/planning_ritual_screen.dart';
import 'screens/scheduled/scheduled_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/someday_maybe/someday_maybe_screen.dart';
import 'screens/task_detail/task_detail_screen.dart';
import 'screens/waiting_for/waiting_for_screen.dart';
import 'screens/blocked/blocked_screen.dart';
import 'screens/active_focus_screen.dart';
import 'screens/focus_screen.dart';
import 'screens/import_screen.dart';
import 'screens/search/search_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/inbox',
  refreshListenable: planningCompletionNotifier,
  redirect: (context, state) {
    // In SWS mode the wallet is the identity — there is no email signup, so
    // /register is meaningless. Bounce any stale deep link / nav entry back to
    // /login where the "Connect wallet" flow lives.
    if (isSwsMode && state.matchedLocation == '/register') {
      return '/login';
    }
    // We intentionally do NOT force unauthenticated users to /login: the app
    // is fully usable in local-only mode (logout() reassigns rows back to the
    // 'local' user), so:
    //   - signing out from Settings should stay on Settings
    //   - a user on /login must be able to back out to /inbox and use the app
    //     without creating an account
    // /login remains reachable from Settings → "Sign in to sync" whenever the
    // user does want to sync.
    if (state.matchedLocation.startsWith('/focus') &&
        !planningCompletionNotifier.value) {
      return '/planning';
    }
    return null;
  },
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
      path: '/planning',
      builder: (context, state) => const PlanningRitualScreen(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
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
          builder: (context, state) => const NextActionsScreen(),
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
          path: '/blocked',
          builder: (context, state) => const BlockedScreen(),
        ),
        GoRoute(
          path: '/scheduled',
          builder: (context, state) => const ScheduledScreen(),
        ),
        GoRoute(
          path: '/focus',
          builder: (context, state) => const FocusScreen(),
        ),
      ],
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
