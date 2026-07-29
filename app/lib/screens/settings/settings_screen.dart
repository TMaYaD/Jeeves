import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

// Cutover tooling (#553 Phase 1) — removed by #556.
import '../../cutover/converge_verify/converge_verify_screen.dart';
import '../../models/clarify_mode.dart';
import '../../models/focus_session_planning_settings.dart';
import '../../providers/auth_provider.dart';
import '../../providers/clarify_mode_provider.dart';
import '../../providers/evening_shutdown_provider.dart';
import '../../providers/focus_session_planning_settings_provider.dart';
import '../../providers/focus_settings_provider.dart';
import '../../providers/periodic_review_provider.dart';
import '../../providers/periodic_review_settings_provider.dart';
import '../../providers/shutdown_settings_provider.dart';
import '../../providers/sync_status_provider.dart';
import '../../widgets/app_title_bar/app_title_bar.dart';
import '../../widgets/capture/capture_action.dart';
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
      appBar: AppTitleBar(
        title: 'Settings',
        pinnedAction: captureAction(context),
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
          _sectionHeader('CLARIFY'),
          const _ClarifySettings(),
          const Divider(height: 1, color: Color(0xFFF3F4F6)),
          _sectionHeader('DAILY PLANNING'),
          _FocusSessionPlanningSettings(),
          const Divider(height: 1, color: Color(0xFFF3F4F6)),
          _sectionHeader('FOCUS MODE'),
          _FocusModeSettings(),
          const Divider(height: 1, color: Color(0xFFF3F4F6)),
          _sectionHeader('WEEKLY REVIEW'),
          const _PeriodicReviewSettings(),
          const Divider(height: 1, color: Color(0xFFF3F4F6)),
          _sectionHeader('EVENING SHUTDOWN'),
          _EveningShutdownSettings(),
          const Divider(height: 1, color: Color(0xFFF3F4F6)),
          // Cutover tooling (#553 Phase 1) — removed by #556 along with the
          // screen and its route.
          _sectionHeader('CUTOVER TOOLING'),
          ListTile(
            key: const Key('converge_verify_tile'),
            leading: const Icon(Icons.rule, color: Color(0xFF9CA3AF)),
            title: const Text(
              'Converge-verify',
              style: TextStyle(
                  fontWeight: FontWeight.w500, color: Color(0xFF374151)),
            ),
            subtitle: const Text(
              'Compare this device\'s store with the server mirror, table by '
              'table. Read-only.',
              style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
            ),
            onTap: () => context.push(ConvergeVerifyScreen.routePath),
          ),
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

class _FocusSessionPlanningSettings extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(focusSessionPlanningSettingsProvider);
    final notifier = ref.read(focusSessionPlanningSettingsProvider.notifier);

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
        ListTile(
          key: const Key('planning_default_estimate_tile'),
          leading: const Icon(Icons.timer_outlined, color: Color(0xFF9CA3AF)),
          title: const Text(
            'Default time estimate',
            style:
                TextStyle(fontWeight: FontWeight.w500, color: Color(0xFF374151)),
          ),
          subtitle: Text(
            '${settings.defaultTimeEstimate} min',
            style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          ),
          onTap: () => _pickDefaultTimeEstimate(context, ref, settings),
        ),
      ],
    );
  }

  static const _defaultEstimateOptions = [5, 10, 15, 20, 30, 45, 60];

  Future<void> _pickDefaultTimeEstimate(
    BuildContext context,
    WidgetRef ref,
    FocusSessionPlanningSettings settings,
  ) async {
    final current = settings.defaultTimeEstimate;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Default time estimate'),
        children: _defaultEstimateOptions
            .map((m) => SimpleDialogOption(
                  key: Key('planning_default_estimate_option_$m'),
                  onPressed: () => Navigator.pop(ctx, m),
                  child: Text(
                    '$m min',
                    style: TextStyle(
                      fontWeight:
                          m == current ? FontWeight.w700 : FontWeight.normal,
                    ),
                  ),
                ))
            .toList(),
      ),
    );
    if (picked != null) {
      await ref
          .read(focusSessionPlanningSettingsProvider.notifier)
          .setDefaultTimeEstimate(picked);
    }
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
    FocusSessionPlanningSettings settings,
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
          .read(focusSessionPlanningSettingsProvider.notifier)
          .setDefaultSnoozeDuration(picked);
    }
  }
}

// ---------------------------------------------------------------------------
// Clarify settings
// ---------------------------------------------------------------------------

class _ClarifySettings extends ConsumerWidget {
  const _ClarifySettings();

  static String _label(ClarifyMode mode) => switch (mode) {
        ClarifyMode.oneToOne => '1-1 mode',
        ClarifyMode.nToM => 'n-m mode',
      };

  static String _description(ClarifyMode mode) => switch (mode) {
        // "at most" because discarding is a legitimate verdict that clarifies
        // the Capture without creating anything (ADR-0006).
        ClarifyMode.oneToOne => 'Each Capture becomes at most one Outcome.',
        ClarifyMode.nToM => 'Each Capture can become several Outcomes, and '
            'several Captures can merge into one.',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(clarifyModeProvider);

    return ListTile(
      key: const Key('clarify_mode_tile'),
      leading: const Icon(Icons.call_split_outlined, color: Color(0xFF9CA3AF)),
      title: const Text(
        'Clarify mode',
        style:
            TextStyle(fontWeight: FontWeight.w500, color: Color(0xFF374151)),
      ),
      subtitle: Text(
        '${_label(mode)} — ${_description(mode)}',
        style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
      ),
      onTap: () => _pickMode(context, ref, current: mode),
    );
  }

  Future<void> _pickMode(
    BuildContext context,
    WidgetRef ref, {
    required ClarifyMode current,
  }) async {
    final picked = await showDialog<ClarifyMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Clarify mode'),
        children: ClarifyMode.values
            .map((mode) => SimpleDialogOption(
                  key: Key('clarify_mode_option_${mode.name}'),
                  onPressed: () => Navigator.pop(ctx, mode),
                  child: Text(
                    '${_label(mode)} — ${_description(mode)}',
                    style: TextStyle(
                      fontWeight: mode == current
                          ? FontWeight.w700
                          : FontWeight.normal,
                    ),
                  ),
                ))
            .toList(),
      ),
    );
    if (picked != null) {
      await ref.read(clarifyModeProvider.notifier).setMode(picked);
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

// ---------------------------------------------------------------------------
// Weekly review settings
// ---------------------------------------------------------------------------

class _PeriodicReviewSettings extends ConsumerWidget {
  const _PeriodicReviewSettings();

  String _formatLastCompleted(DateTime? when) {
    if (when == null) return 'Never';
    final local = when.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(periodicReviewSettingsProvider);
    final notifier = ref.read(periodicReviewSettingsProvider.notifier);
    final reviewNotifier = ref.read(periodicReviewProvider.notifier);
    final lastCompleted = ref.watch(periodicReviewLastCompletedProvider);

    return Column(
      children: [
        ListTile(
          key: const Key('periodic_review_time_tile'),
          leading: const Icon(Icons.schedule_outlined,
              color: Color(0xFF9CA3AF)),
          title: const Text(
            'Remind me at',
            style: TextStyle(
                fontWeight: FontWeight.w500, color: Color(0xFF374151)),
          ),
          subtitle: Text(
            settings.notificationTime.format(context),
            style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          ),
          onTap: () async {
            final picked = await showTimePicker(
              context: context,
              initialTime: settings.notificationTime,
            );
            if (picked != null) {
              await notifier.setNotificationTime(picked);
            }
          },
        ),
        SwitchListTile(
          key: const Key('periodic_review_notification_toggle'),
          secondary: const Icon(Icons.notifications_outlined,
              color: Color(0xFF9CA3AF)),
          title: const Text(
            'Weekly Review Reminder',
            style: TextStyle(
                fontWeight: FontWeight.w500, color: Color(0xFF374151)),
          ),
          value: settings.notificationEnabled,
          onChanged: (v) => notifier.setNotificationEnabled(v),
        ),
        SwitchListTile(
          key: const Key('periodic_review_banner_toggle'),
          secondary: const Icon(Icons.campaign_outlined,
              color: Color(0xFF9CA3AF)),
          title: const Text(
            'Show Weekly Review banner',
            style: TextStyle(
                fontWeight: FontWeight.w500, color: Color(0xFF374151)),
          ),
          subtitle: const Text(
            'A reminder banner once a weekly review is due.',
            style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          ),
          value: settings.bannerEnabled,
          onChanged: (v) => notifier.setBannerEnabled(v),
        ),
        ListTile(
          key: const Key('periodic_review_last_completed_tile'),
          leading: const Icon(Icons.history, color: Color(0xFF9CA3AF)),
          title: const Text(
            'Last completed',
            style: TextStyle(
                fontWeight: FontWeight.w500, color: Color(0xFF374151)),
          ),
          subtitle: Text(
            _formatLastCompleted(lastCompleted),
            style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          ),
        ),
        ListTile(
          key: const Key('start_periodic_review_tile'),
          leading: const Icon(Icons.refresh, color: Color(0xFF059669)),
          title: const Text(
            'Start Weekly Review',
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: Color(0xFF059669),
            ),
          ),
          subtitle: const Text(
            'Walk through the wizard now without waiting for the cadence.',
            style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          ),
          onTap: () {
            context.pop();
            // Reset the wizard cursor to the intro; the screen's initState
            // reloads every step's snapshot so a manual start sees current
            // state (and the intro's estimate).
            reviewNotifier.goToStep(PeriodicReviewNotifier.kStepIntro);
            context.push('/periodic-review');
          },
        ),
      ],
    );
  }
}

class _EveningShutdownSettings extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(shutdownSettingsProvider);
    final notifier = ref.read(shutdownSettingsProvider.notifier);

    return Column(
      children: [
        ListTile(
          key: const Key('shutdown_time_tile'),
          leading: const Icon(Icons.nightlight_outlined,
              color: Color(0xFF9CA3AF)),
          title: const Text(
            'Shutdown time',
            style: TextStyle(
                fontWeight: FontWeight.w500, color: Color(0xFF374151)),
          ),
          subtitle: Text(
            settings.shutdownTime.format(context),
            style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          ),
          onTap: () async {
            final picked = await showTimePicker(
              context: context,
              initialTime: settings.shutdownTime,
            );
            if (picked != null) {
              await notifier.setShutdownTime(picked);
            }
          },
        ),
        SwitchListTile(
          key: const Key('shutdown_notification_toggle'),
          secondary: const Icon(Icons.notifications_outlined,
              color: Color(0xFF9CA3AF)),
          title: const Text(
            'Notify me at shutdown time',
            style: TextStyle(
                fontWeight: FontWeight.w500, color: Color(0xFF374151)),
          ),
          value: settings.notificationEnabled,
          onChanged: (v) => notifier.setNotificationEnabled(v),
        ),
        SwitchListTile(
          key: const Key('shutdown_banner_toggle'),
          secondary:
              const Icon(Icons.campaign_outlined, color: Color(0xFF9CA3AF)),
          title: const Text(
            'Show banner at shutdown time',
            style: TextStyle(
                fontWeight: FontWeight.w500, color: Color(0xFF374151)),
          ),
          subtitle: const Text(
            'A reminder banner after your configured shutdown time.',
            style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          ),
          value: settings.bannerEnabled,
          onChanged: (v) => notifier.setBannerEnabled(v),
        ),
        ListTile(
          key: const Key('start_shutdown_tile'),
          leading:
              const Icon(Icons.nightlight_round, color: Color(0xFF4F46E5)),
          title: const Text(
            'Start Evening Shutdown',
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: Color(0xFF4F46E5),
            ),
          ),
          subtitle: const Text(
            'Review your day and close out manually.',
            style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          ),
          onTap: () {
            Navigator.pop(context);
            ref.read(eveningShutdownProvider.notifier).goToStep(0);
            context.push('/shutdown');
          },
        ),
      ],
    );
  }
}
