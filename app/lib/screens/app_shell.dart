import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/inbox_provider.dart';

/// Persistent scaffold with bottom navigation bar.
///
/// The [child] is rendered in the body; routes inside the [ShellRoute]
/// automatically replace the body while keeping the navigation bar visible.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  static const _tabs = [
    ('/inbox', Icons.inbox_outlined, Icons.inbox, 'Inbox'),
    ('/next-actions', Icons.check_circle_outline, Icons.check_circle, 'Next'),
    ('/waiting-for', Icons.hourglass_empty, Icons.hourglass_full, 'Waiting'),
    ('/someday-maybe', Icons.star_border, Icons.star, 'Someday'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).uri.path;
    final currentIndex = _tabIndex(location);
    final inboxCount =
        ref.watch(inboxItemsProvider).asData?.value.length ?? 0;

    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        key: const Key('bottom_nav'),
        selectedIndex: currentIndex,
        onDestinationSelected: (index) =>
            context.go(_tabs[index].$1),
        destinations: [
          NavigationDestination(
            icon: Badge(
              isLabelVisible: inboxCount > 0,
              label: Text('$inboxCount'),
              child: const Icon(Icons.inbox_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: inboxCount > 0,
              label: Text('$inboxCount'),
              child: const Icon(Icons.inbox),
            ),
            label: 'Inbox',
          ),
          const NavigationDestination(
            icon: Icon(Icons.check_circle_outline),
            selectedIcon: Icon(Icons.check_circle),
            label: 'Next',
          ),
          const NavigationDestination(
            icon: Icon(Icons.hourglass_empty),
            selectedIcon: Icon(Icons.hourglass_full),
            label: 'Waiting',
          ),
          const NavigationDestination(
            icon: Icon(Icons.star_border),
            selectedIcon: Icon(Icons.star),
            label: 'Someday',
          ),
        ],
      ),
    );
  }

  static int _tabIndex(String path) {
    for (var i = 0; i < _tabs.length; i++) {
      if (path.startsWith(_tabs[i].$1)) return i;
    }
    return 0;
  }
}
