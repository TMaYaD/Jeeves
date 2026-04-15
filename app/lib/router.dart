import 'package:go_router/go_router.dart';

import 'screens/app_shell.dart';
import 'screens/inbox/inbox_screen.dart';
import 'screens/next_actions/next_actions_screen.dart';
import 'screens/someday_maybe/someday_maybe_screen.dart';
import 'screens/task_detail/task_detail_screen.dart';
import 'screens/waiting_for/waiting_for_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/inbox',
  routes: [
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
