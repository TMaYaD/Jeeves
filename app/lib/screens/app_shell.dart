import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/focus_session_planning_provider.dart';
import '../providers/inbox_provider.dart';
import '../providers/gtd_lists_provider.dart';
import '../providers/sync_status_provider.dart';
import '../providers/tags_provider.dart';
import '../widgets/app_title_bar/app_title_bar.dart';
import '../widgets/capture/capture_action.dart';
import '../widgets/jeeves_logo.dart';
import '../widgets/nudge_banner.dart';
import 'common/tag_cloud.dart';
import 'sync_health/sync_health_copy.dart';
import 'sync_health/sync_health_screen.dart';

/// The shared title-bar title for each of the seven shell list routes, keyed
/// by [GoRouterState] path. The bar's title is a pure function of route state,
/// owned above the child screens (ADR-0021) — the children no longer hand-roll
/// their own header. "Now" is the user-facing label for `/focus` (epic #35);
/// the route and internal identifiers stay Focus (CONTEXT.md divergence list).
const Map<String, String> shellRouteTitles = {
  '/inbox': 'Inbox',
  '/focus': 'Now',
  '/next-actions': 'Next Actions',
  '/waiting-for': 'Waiting For',
  '/someday-maybe': 'Maybe',
  '/done': 'Done',
  '/trash': 'Trash',
};

/// Intent dispatched by the search keyboard shortcut (Ctrl+K or /).
class _SearchIntent extends Intent {
  const _SearchIntent();
}

/// Persistent scaffold with a collapsible left drawer navigation.
///
/// The [child] is rendered in the body; routes inside the [ShellRoute]
/// automatically replace the body while keeping the drawer state consistent.
///
/// Registers a global keyboard shortcut (Ctrl+K or /) that opens the search
/// screen from any GTD list view.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).uri.path;
    final title = shellRouteTitles[location] ?? '';

    // The Inbox route carries the unprocessed-capture count as a typed badge;
    // every other shell route shows none. Null at zero preserves the prior
    // "only when > 0" behaviour. `.value` (not `.asData?.value`) retains the
    // last-rendered count across a transient loading/error state (e.g. a
    // brief error during re-subscription), so the badge doesn't flicker away.
    final inboxCount = ref.watch(inboxItemsProvider).value?.length ?? 0;
    final badge = location == '/inbox' && inboxCount > 0
        ? AppTitleBarBadge(
            count: inboxCount,
            semanticsLabel: '$inboxCount unprocessed captures',
          )
        : null;

    // The Now route offers Re-plan as a shared-title-bar page action while the
    // user is in an open session carrying tasks (the shutdown-callout state,
    // #499) — mirroring the Inbox badge: the same route-derived condition,
    // supplied top-down to the bar rather than hand-rolled inside the screen.
    // Every other shell route supplies none.
    final showReplan =
        location == '/focus' && ref.watch(hasOpenSessionWithTasksProvider);
    final pageActions = showReplan
        ? [
            AppTitleBarAction(
              key: const Key('focus_replan'),
              icon: Icons.wb_sunny_outlined,
              label: 'Re-plan',
              onPressed: () => context.go('/focus-session-planning'),
            ),
          ]
        : const <AppTitleBarAction>[];

    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyK):
            const _SearchIntent(),
        // CharacterActivator is layout-agnostic: it binds to the '/' character
        // regardless of where it sits on the user's keyboard, unlike
        // LogicalKeyboardKey.slash which is position-based on QWERTY.
        const CharacterActivator('/'): const _SearchIntent(),
      },
      child: Actions(
        actions: {
          _SearchIntent: CallbackAction<_SearchIntent>(
            onInvoke: (_) {
              context.push('/search');
              return null;
            },
          ),
        },
        child: Scaffold(
          drawer: const CustomDrawer(),
          appBar: AppTitleBar(
            title: title,
            badge: badge,
            pageActions: pageActions,
            leading: AppTitleBarLeading.drawer,
            // Capture is pinned on every shell route except the Inbox, whose
            // QuickAddBar already serves capture — a second affordance would be
            // redundant (owner ruling, #458). Mirrors the badge/pageActions
            // top-down pattern: the bar stays a pure function of route state.
            pinnedAction: location == '/inbox' ? null : captureAction(context),
          ),
          body: Column(
            children: [
              const NudgeBanner(),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class CustomDrawer extends ConsumerWidget {
  const CustomDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).uri.path;
    final inboxCount = ref.watch(inboxItemsProvider).asData?.value.length ?? 0;
    final nextCount = ref.watch(nextProvider).asData?.value.length ?? 0;
    final waitingForCount = ref.watch(waitingForProvider).asData?.value.length ?? 0;
    final maybeCount = ref.watch(maybeProvider).asData?.value.length ?? 0;
    final syncAsync = ref.watch(syncStatusProvider);
    // A throwing health read is a red indicator with nothing behind it: we do
    // not know what to report, so the tile must not offer to explain.
    final syncIndication = syncAsync.hasError
        ? (status: SyncStatus.error, hasSomethingToReport: false)
        : syncAsync.asData?.value;

    final projectTags = ref.watch(projectTagsProvider).asData?.value ?? [];

    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
              child: Row(
                children: [
                  // Pointillist at 32 px — threshold for auto, meets clear-space req
                  const JeevesLogo(size: 32),
                  const Spacer(),
                  SyncIndicator(indication: syncIndication),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFFF3F4F6)),
            // Search — fixed (non-scrollable) for consistent visibility
            ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.search,
                  color: Color(0xFF6B7280)),
              title: const Text(
                'Search',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF374151),
                ),
              ),
              trailing: const Text(
                'Ctrl+K',
                style: TextStyle(
                  fontSize: 11,
                  color: Color(0xFF9CA3AF),
                ),
              ),
              onTap: () {
                Navigator.pop(context);
                context.push('/search');
              },
            ),
            const Divider(height: 1, color: Color(0xFFF3F4F6)),
            // Nav items — scrollable to accommodate all list types + projects
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  _buildNavItem(context,
                      icon: Icons.inbox_outlined,
                      title: 'Inbox',
                      path: '/inbox',
                      location: location,
                      count: inboxCount),
                  // User-facing title is "Now" (epic #35 design review);
                  // the route and internal identifiers stay Focus — see
                  // CONTEXT.md's term-unification divergence list.
                  _buildNavItem(context,
                      icon: Icons.center_focus_strong_outlined,
                      title: 'Now',
                      path: '/focus',
                      location: location),
                  _buildNavItem(context,
                      icon: Icons.check_circle_outline,
                      title: 'Next Actions',
                      path: '/next-actions',
                      location: location,
                      count: nextCount),
                  _buildNavItem(context,
                      icon: Icons.hourglass_empty,
                      title: 'Waiting For',
                      path: '/waiting-for',
                      location: location,
                      count: waitingForCount),
                  _buildNavItem(context,
                      icon: Icons.star_border,
                      title: 'Maybe',
                      path: '/someday-maybe',
                      location: location,
                      count: maybeCount),
                  const SizedBox(height: 8),
                  const Divider(height: 1, color: Color(0xFFF3F4F6)),
                  const SizedBox(height: 8),
                  const TagCloud(),
                  const SizedBox(height: 8),
                  const Divider(height: 1, color: Color(0xFFF3F4F6)),
                  const SizedBox(height: 16),
                  _buildSectionHeader('PROJECTS'),
                  ...projectTags.map((t) => ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 24),
                        leading: const Icon(Icons.folder_outlined,
                            color: Color(0xFF9CA3AF)),
                        title: Text(t.name,
                            style: const TextStyle(
                                fontSize: 14, color: Color(0xFF374151))),
                      )),
                  const SizedBox(height: 8),
                  const Divider(height: 1, color: Color(0xFFF3F4F6)),
                  const SizedBox(height: 8),
                  // Record group — Done and Trash are records, not working
                  // lists: de-emphasised, no count badges (record size is
                  // not actionable signal), scrolls with the nav column.
                  _buildNavItem(context,
                      icon: Icons.task_alt,
                      title: 'Done',
                      path: '/done',
                      location: location,
                      muted: true),
                  _buildNavItem(context,
                      icon: Icons.delete_outline,
                      title: 'Trash',
                      path: '/trash',
                      location: location,
                      muted: true),
                  const SizedBox(height: 8),
                ],
              ),
              ),
            ),
            const Divider(height: 1, color: Color(0xFFF3F4F6)),
            ListTile(
              key: const Key('settings_tile'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.settings_outlined,
                  color: Color(0xFF9CA3AF)),
              title: const Text(
                'Settings',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF374151),
                ),
              ),
              onTap: () {
                Navigator.pop(context);
                context.push('/settings');
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, {int? badge}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: Color(0xFF9CA3AF),
            ),
          ),
          if (badge != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFF2563EB),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$badge',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Builds one drawer nav tile. [muted] renders the de-emphasised record
  /// idiom (grey icon, smaller label — matching the PROJECTS tiles) used by
  /// the Done / Trash group; the selected-state highlight still applies.
  Widget _buildNavItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String path,
    required String location,
    int count = 0,
    bool muted = false,
  }) {
    final isSelected = location.startsWith(path);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      leading: Icon(icon,
          color: isSelected
              ? const Color(0xFF2563EB)
              : muted
                  ? const Color(0xFF9CA3AF)
                  : const Color(0xFF6B7280)),
      title: Text(
        title,
        style: TextStyle(
          fontSize: muted ? 14 : 16,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
          color:
              isSelected ? const Color(0xFF2563EB) : const Color(0xFF374151),
        ),
      ),
      trailing: count > 0
          ? Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(10)),
              child: Text('$count',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF4B5563))),
            )
          : null,
      selected: isSelected,
      selectedTileColor: const Color(0xFFEFF6FF),
      onTap: () {
        context.go(path);
        Navigator.pop(context);
      },
    );
  }
}

/// Small sync indicator shown in the drawer header.
///
/// [SyncStatus.worthKnowing] differs from healthy in **both glyph and tone**,
/// because colour alone is not an accessible difference: amber against green can
/// collapse under deuteranopia at 20px. Filled `cloud_done` in green stays
/// healthy; the calm state is the outlined glyph in amber, a shape difference
/// readable with no colour at all.
///
/// Public **so that the tests assert this widget** rather than a second copy of
/// its status-to-(glyph, tone, tooltip) table. A test that re-declares the table
/// passes whatever the shell happens to render, which would leave the one thing
/// this surface exists to get right — the calm band being visibly neither
/// healthy nor an error — unguarded.
class SyncIndicator extends StatelessWidget {
  const SyncIndicator({super.key, required this.indication});
  final SyncIndication? indication;

  @override
  Widget build(BuildContext context) {
    final (icon, color, tooltip) = switch (indication?.status) {
      SyncStatus.localOnly => (Icons.cloud_off_outlined, const Color(0xFF9CA3AF), 'Local only'),
      SyncStatus.connecting => (Icons.cloud_upload_outlined, const Color(0xFF9CA3AF), 'Connecting'),
      SyncStatus.syncing => (Icons.cloud_sync, const Color(0xFF2563EB), 'Syncing'),
      SyncStatus.synced => (Icons.cloud_done, const Color(0xFF16A34A), 'Synced'),
      SyncStatus.worthKnowing => (
          Icons.cloud_done_outlined,
          const Color(0xFFF59E0B),
          syncHealthWorthKnowingTooltip,
        ),
      SyncStatus.error => (Icons.cloud_off, const Color(0xFFDC2626), 'Sync error'),
      null => (Icons.cloud_off_outlined, const Color(0xFF9CA3AF), 'Local only'),
    };

    final glyph = Tooltip(
      message: tooltip,
      child: Icon(icon, size: 20, color: color),
    );

    // Tappable **iff there is something to report**, read off the same value the
    // glyph came from so the tile and its tappability cannot disagree. A healthy
    // device has no entry point at all — see docs/DESIGN.md § Sync health for
    // why that is a decision rather than an omission.
    if (indication?.hasSomethingToReport != true) return glyph;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () {
        Navigator.pop(context);
        context.push(SyncHealthScreen.routePath);
      },
      child: Padding(padding: const EdgeInsets.all(8), child: glyph),
    );
  }
}
