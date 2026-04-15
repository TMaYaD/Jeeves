import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/inbox_provider.dart';
import '../providers/gtd_lists_provider.dart';
import '../providers/tags_provider.dart';
import '../providers/daily_planning_provider.dart';

/// Persistent scaffold with a collapsible left drawer navigation.
///
/// The [child] is rendered in the body; routes inside the [ShellRoute]
/// automatically replace the body while keeping the drawer state consistent.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      drawer: const CustomDrawer(),
      body: child, // Screens must provide their own hamburger menu or gesture to open drawer
    );
  }
}

class CustomDrawer extends ConsumerWidget {
  const CustomDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).uri.path;
    final inboxCount = ref.watch(inboxItemsProvider).asData?.value.length ?? 0;
    final nextActionsCount = ref.watch(nextActionsProvider).asData?.value.length ?? 0;
    final waitingForCount = ref.watch(waitingForProvider).asData?.value.length ?? 0;
    final blockedCount = ref.watch(blockedTasksProvider).asData?.value.length ?? 0;
    final somedayCount = ref.watch(somedayMaybeProvider).asData?.value.length ?? 0;
    final scheduledCount = ref.watch(scheduledProvider).asData?.value.length ?? 0;

    final projectTags = ref.watch(projectTagsProvider).asData?.value ?? [];
    final contextTags = ref.watch(contextTagsProvider).asData?.value ?? [];

    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Text(
                'Jeeves',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF1A1A2E)),
              ),
            ),
            const Divider(height: 1, color: Color(0xFFF3F4F6)),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  _buildSectionHeader('GTD LISTS'),
                  _buildNavItem(context, icon: Icons.inbox_outlined, title: 'Inbox', path: '/inbox', location: location, count: inboxCount),
                  _buildNavItem(context, icon: Icons.check_circle_outline, title: 'Next Actions', path: '/next-actions', location: location, count: nextActionsCount),
                  _buildNavItem(context, icon: Icons.event_outlined, title: 'Scheduled', path: '/scheduled', location: location, count: scheduledCount),
                  _buildNavItem(context, icon: Icons.hourglass_empty, title: 'Waiting For', path: '/waiting-for', location: location, count: waitingForCount),
                  _buildNavItem(context, icon: Icons.block, title: 'Blocked', path: '/blocked', location: location, count: blockedCount),
                  _buildNavItem(context, icon: Icons.star_border, title: 'Someday/Maybe', path: '/someday-maybe', location: location, count: somedayCount),

                  const SizedBox(height: 8),
                  const Divider(height: 1, color: Color(0xFFF3F4F6)),
                  const SizedBox(height: 8),

                  // Re-plan Day — re-enters the daily planning ritual
                  _buildSectionHeader('PLANNING'),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                    leading: const Icon(Icons.wb_sunny_outlined, color: Color(0xFF6B7280)),
                    title: const Text(
                      'Re-plan Day',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Color(0xFF374151)),
                    ),
                    onTap: () async {
                      // Capture the router before closing the drawer; after
                      // Navigator.pop the drawer unmounts and context becomes
                      // invalid across the subsequent await gap.
                      final router = GoRouter.of(context);
                      Navigator.pop(context); // close drawer first
                      await ref.read(dailyPlanningProvider.notifier).reEnterPlanning();
                      router.go('/planning');
                    },
                  ),

                  const SizedBox(height: 16),
                  _buildSectionHeader('CONTEXTS'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: contextTags.map((t) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEFF6FF),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFFDBEAFE)),
                        ),
                        child: Text(t.name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1D4ED8))),
                      )).toList(),
                    ),
                  ),

                  const SizedBox(height: 16),
                  _buildSectionHeader('PROJECTS'),
                  ...projectTags.map((t) => ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                    leading: const Icon(Icons.folder_outlined, color: Color(0xFF9CA3AF)),
                    title: Text(t.name, style: const TextStyle(fontSize: 14, color: Color(0xFF374151))),
                    onTap: () {
                      // Navigate to project list (coming soon)
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Project filters coming soon!')));
                      Navigator.pop(context);
                    },
                  )),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
          color: Color(0xFF9CA3AF),
        ),
      ),
    );
  }

  Widget _buildNavItem(BuildContext context, {
    required IconData icon,
    required String title,
    required String path,
    required String location,
    int count = 0,
  }) {
    final isSelected = location.startsWith(path);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      leading: Icon(icon, color: isSelected ? const Color(0xFF2563EB) : const Color(0xFF6B7280)),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
          color: isSelected ? const Color(0xFF2563EB) : const Color(0xFF374151),
        ),
      ),
      trailing: count > 0 ? Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(10)),
        child: Text('$count', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF4B5563))),
      ) : null,
      selected: isSelected,
      selectedTileColor: const Color(0xFFEFF6FF),
      onTap: () {
        context.go(path);
        Navigator.pop(context); // Close drawer
      },
    );
  }
}
