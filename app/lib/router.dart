import 'package:go_router/go_router.dart';

import 'providers/daily_planning_provider.dart';
import 'screens/app_shell.dart';
import 'screens/inbox/inbox_screen.dart';
import 'screens/next_actions/next_actions_screen.dart';
import 'screens/planning/planning_ritual_screen.dart';
import 'screens/scheduled/scheduled_screen.dart';
import 'screens/someday_maybe/someday_maybe_screen.dart';
import 'screens/task_detail/task_detail_screen.dart';
import 'screens/waiting_for/waiting_for_screen.dart';
import 'screens/blocked/blocked_screen.dart';
import 'screens/focus_screen.dart';

/// Routes that require the daily planning ritual to be completed first.
const _protectedPaths = [
  '/next-actions',
  '/waiting-for',
  '/someday-maybe',
  '/blocked',
  '/scheduled',
  '/focus',
];

final appRouter = GoRouter(
  initialLocation: '/inbox',
  // Re-evaluate the redirect whenever the planning completion state changes
  // (e.g. after "Start Day" or "Re-plan Day").
  refreshListenable: planningCompletionNotifier,
  redirect: (context, state) {
    final completed = planningCompletionNotifier.value;
    if (!completed) {
      final loc = state.uri.path;
      final isProtected = _protectedPaths.any((p) => loc.startsWith(p));
      if (isProtected) return '/planning';
    }
    // Already heading to /planning — no loop.
    return null;
  },
  routes: [
    GoRoute(
      path: '/planning',
      builder: (context, state) => const PlanningRitualScreen(),
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
  ],
);
