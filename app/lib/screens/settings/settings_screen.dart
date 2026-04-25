import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/planning_settings.dart';
import '../../providers/auth_provider.dart';
import '../../providers/focus_settings_provider.dart';
import '../../providers/planning_settings_provider.dart';
import '../../providers/sync_status_provider.dart';
import '../../widgets/jeeves_logo.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncAsync = ref.watch(syncStatusProvider);
    final syncStatus = syncAsync.hasError
        ? SyncStatus.error
        : syncAsync.asData?.value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1A1A2E),
        elevation: 0,
        leading: BackButton(onPressed: () => context.pop()),
      ),
      backgroundColor: Colors.white,
      body: ValueListenableBuilder<bool>(
        valueListenable: authStateNotifier,
        builder: (context, isAuthenticated, _) => ListView(
        children: [
          _sectionHeader('SYNC'),
          if (!isAuthenticated) ...[
            ListTile(
              key: const Key('sign_in_to_sync_tile'),
              leading: const Icon(Icons.cloud_upload_outlined,
                  color: Color(0xFF2563EB)),
              title: const Text(
                'Sign in to sync across devices',
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF2563EB),
                ),
              ),
              subtitle: const Text(
                'Your data stays local until you choose to sync.',
                style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
              ),
              onTap: () => context.push('/login'),
            ),
          ] else ...[
            ListTile(
              leading: _syncIcon(syncStatus),
              title: const Text(
                'Sync enabled',
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF374151),
                ),
              ),
              subtitle: Text(
                _syncLabel(syncStatus),
                style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.logout, color: Color(0xFF9CA3AF)),
              title: const Text(
                'Sign out',
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF374151),
                ),
              ),
              subtitle: const Text(
                'Your local data will remain on this device.',
                style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
              ),
              onTap: () => _confirmLogout(context, ref),
            ),
          ],
          const Divider(height: 1, color: Color(0xFFF3F4F6)),
          _sectionHeader('IMPORT'),
          ListTile(
            leading:
                const Icon(Icons.download_outlined, color: Color(0xFF9CA3AF)),
            title: const Text(
              'Import from Nirvana',
              style: TextStyle(
                  fontWeight: FontWeight.w500, color: Color(0xFF374151)),
            ),
            subtitle: const Text(
              'Import tasks and projects from a Nirvana export.',
              style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
            ),
            onTap: () => context.push('/import'),
          ),
          const Divider(height: 1, color: Color(0xFFF3F4F6)),
          _sectionHeader('DAILY PLANNING'),
          _DailyPlanningSettings(),
          const Divider(height: 1, color: Color(0xFFF3F4F6)),
          _sectionHeader('FOCUS MODE'),
          _FocusModeSettings(),
          const Divider(height: 1, color: Color(0xFFF3F4F6)),
          _sectionHeader('ABOUT'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: Column(
                children: [
                  JeevesLogo(
                    variant: JeevesLogoVariant.pointillist,
                    size: 64,
                    appIcon: true,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Jeeves',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 18,
                        color: Color(0xFF1A1A2E)),
                  ),
                  const Text(
                    'Offline-first GTD task manager',
                    style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                  ),
                ],
              ),
            ),
          ),
          ListTile(
            leading:
                const Icon(Icons.article_outlined, color: Color(0xFF9CA3AF)),
            title: const Text(
              'Open source licenses',
              style: TextStyle(
                  fontWeight: FontWeight.w500, color: Color(0xFF374151)),
            ),
            onTap: () =>
                showLicensePage(context: context, applicationName: 'Jeeves'),
          ),
        ],
      ),
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
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

  Widget _syncIcon(SyncStatus? status) {
    switch (status) {
      case SyncStatus.synced:
        return const Icon(Icons.cloud_done, color: Color(0xFF16A34A));
      case SyncStatus.syncing:
        return const Icon(Icons.cloud_sync, color: Color(0xFF2563EB));
      case SyncStatus.connecting:
        return const Icon(Icons.cloud_upload_outlined,
            color: Color(0xFF9CA3AF));
      case SyncStatus.error:
        return const Icon(Icons.cloud_off, color: Color(0xFFDC2626));
      default:
        return const Icon(Icons.cloud_outlined, color: Color(0xFF9CA3AF));
    }
  }

  String _syncLabel(SyncStatus? status) {
    switch (status) {
      case SyncStatus.synced:
        return 'All changes saved';
      case SyncStatus.syncing:
        return 'Syncing\u2026';
      case SyncStatus.connecting:
        return 'Connecting\u2026';
      case SyncStatus.error:
        return 'Sync error';
      default:
        return 'Sync active';
    }
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'Your data will remain on this device. Sign in again to re-sync.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Sign out',
              style: TextStyle(color: Color(0xFFDC2626)),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(authTokenProvider.notifier).logout();
      // Stay on Settings; the screen rebuilds to show the signed-out state.
    }
  }
}

class _DailyPlanningSettings extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(planningSettingsProvider);
    final notifier = ref.read(planningSettingsProvider.notifier);

    return Column(
      children: [
        ListTile(
          key: const Key('planning_time_tile'),
          leading: const Icon(Icons.schedule_outlined, color: Color(0xFF9CA3AF)),
          title: const Text(
            'Planning time',
            style: TextStyle(fontWeight: FontWeight.w500, color: Color(0xFF374151)),
          ),
          subtitle: Text(
            settings.planningTime.format(context),
            style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          ),
          onTap: () async {
            final picked = await showTimePicker(
              context: context,
              initialTime: settings.planningTime,
            );
            if (picked != null) {
              await notifier.setPlanningTime(picked);
            }
          },
        ),
        SwitchListTile(
          key: const Key('planning_notification_toggle'),
          secondary: const Icon(Icons.notifications_outlined,
              color: Color(0xFF9CA3AF)),
          title: const Text(
            'Notify me at planning time',
            style: TextStyle(fontWeight: FontWeight.w500, color: Color(0xFF374151)),
          ),
          value: settings.notificationEnabled,
          onChanged: (v) => notifier.setNotificationEnabled(v),
        ),
        if (settings.notificationEnabled)
          ListTile(
            key: const Key('planning_snooze_tile'),
            leading: const Icon(Icons.snooze_outlined, color: Color(0xFF9CA3AF)),
            title: const Text(
              'Default snooze duration',
              style: TextStyle(
                  fontWeight: FontWeight.w500, color: Color(0xFF374151)),
            ),
            subtitle: Text(
              _snoozeLabel(settings.defaultSnoozeDuration),
              style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
            ),
            onTap: () => _pickSnoozeDuration(context, ref, settings),
          ),
        SwitchListTile(
          key: const Key('planning_banner_toggle'),
          secondary: const Icon(Icons.campaign_outlined, color: Color(0xFF9CA3AF)),
          title: const Text(
            'Show banner on main views',
            style: TextStyle(fontWeight: FontWeight.w500, color: Color(0xFF374151)),
          ),
          subtitle: const Text(
            'A reminder banner until you plan your day.',
            style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          ),
          value: settings.bannerEnabled,
          onChanged: (v) => notifier.setBannerEnabled(v),
        ),
      ],
    );
  }

  String _snoozeLabel(int minutes) {
    if (minutes < 60) return '$minutes min';
    if (minutes == 60) return '1 hour';
    if (minutes < 1440) return '${minutes ~/ 60} hours';
    return 'Tomorrow';
  }

  Future<void> _pickSnoozeDuration(
    BuildContext context,
    WidgetRef ref,
    PlanningSettings settings,
  ) async {
    final durations = settings.snoozeDurations;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Default snooze duration'),
        children: durations
            .map((d) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, d),
                  child: Text(_snoozeLabel(d)),
                ))
            .toList(),
      ),
    );
    if (picked != null) {
      await ref
          .read(planningSettingsProvider.notifier)
          .setDefaultSnoozeDuration(picked);
    }
  }
}

// ---------------------------------------------------------------------------
// Focus mode settings
// ---------------------------------------------------------------------------

class _FocusModeSettings extends ConsumerWidget {
  const _FocusModeSettings();

  static const _sprintOptions = [5, 10, 15, 20, 25, 30];
  static const _breakOptions = [1, 2, 3, 5, 10];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(focusSettingsProvider);
    final notifier = ref.read(focusSettingsProvider.notifier);

    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.timer_outlined, color: Color(0xFF9CA3AF)),
          title: const Text(
            'Sprint duration',
            style: TextStyle(
                fontWeight: FontWeight.w500, color: Color(0xFF374151)),
          ),
          subtitle: Text(
            '${settings.sprintDurationMinutes} minutes',
            style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          ),
          onTap: () => _pickDuration(
            context,
            title: 'Sprint duration',
            options: _sprintOptions,
            current: settings.sprintDurationMinutes,
            onPicked: notifier.setSprintDurationMinutes,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.self_improvement, color: Color(0xFF9CA3AF)),
          title: const Text(
            'Break duration',
            style: TextStyle(
                fontWeight: FontWeight.w500, color: Color(0xFF374151)),
          ),
          subtitle: Text(
            '${settings.breakDurationMinutes} minutes',
            style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          ),
          onTap: () => _pickDuration(
            context,
            title: 'Break duration',
            options: _breakOptions,
            current: settings.breakDurationMinutes,
            onPicked: notifier.setBreakDurationMinutes,
          ),
        ),
      ],
    );
  }

  Future<void> _pickDuration(
    BuildContext context, {
    required String title,
    required List<int> options,
    required int current,
    required Future<void> Function(int) onPicked,
  }) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: options
            .map((m) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, m),
                  child: Text(
                    '$m minutes',
                    style: TextStyle(
                      fontWeight: m == current
                          ? FontWeight.w700
                          : FontWeight.normal,
                    ),
                  ),
                ))
            .toList(),
      ),
    );
    if (picked != null) await onPicked(picked);
  }
}
