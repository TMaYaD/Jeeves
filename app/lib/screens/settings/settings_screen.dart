import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/auth_provider.dart';
import '../../providers/sync_status_provider.dart';

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
          _sectionHeader('ABOUT'),
          ListTile(
            leading: const Icon(Icons.info_outline, color: Color(0xFF9CA3AF)),
            title: const Text(
              'Jeeves',
              style: TextStyle(
                  fontWeight: FontWeight.w500, color: Color(0xFF374151)),
            ),
            subtitle: const Text(
              'Offline-first GTD task manager',
              style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
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
