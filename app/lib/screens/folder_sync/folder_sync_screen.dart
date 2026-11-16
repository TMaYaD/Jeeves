/// Sync through a folder: choose the folder, pair the other devices, turn it off.
///
/// Opt-in and pushed from Settings, for a device that is not signed in. Choosing a
/// folder goes through a confirmation that the folder is not encrypted — accepted
/// before anything is written — and the screen says so permanently.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/folder_sync_provider.dart';
import '../../sync/folder/folder_setup.dart';
import '../../sync/folder_sync_controller.dart';

/// The wording the person accepts before a folder is used.
const String folderNotEncryptedWarning =
    'Jeeves does not encrypt this folder. Anyone who can open it can read your '
    'tasks and notes: other apps with storage access, the company that runs your '
    'file sync service, or anyone who gets a copy. Jeeves can tell if someone '
    'changes them, but cannot stop them reading them.';

const String folderTurnOffNotice =
    'The files already in the folder stay there, and on every device your file '
    'sync service has copied them to, until you delete them.';

class FolderSyncScreen extends ConsumerStatefulWidget {
  const FolderSyncScreen({super.key});

  static const String routePath = '/settings/folder-sync';

  @override
  ConsumerState<FolderSyncScreen> createState() => _FolderSyncScreenState();
}

class _FolderSyncScreenState extends ConsumerState<FolderSyncScreen> {
  bool _busy = false;
  String? _message;

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
    required Key actionKey,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: actionKey,
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on FolderSyncRefusal catch (refusal) {
      _message = refusal.message;
    } on Object catch (error) {
      _message = 'Something went wrong: $error';
    }
    ref.invalidate(folderSyncSummaryProvider);
    ref.invalidate(folderSyncRowsProvider);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _chooseFolder() async {
    final accepted = await _confirm(
      title: 'This folder is not encrypted',
      body: folderNotEncryptedWarning,
      action: 'I understand, choose a folder',
      actionKey: const Key('folder_sync_accept_unencrypted'),
    );
    if (!accepted || !mounted) return;
    await _run(() async {
      final platform = ref.read(folderPlatformProvider);
      final location = await platform.pickFolder();
      if (location == null) return;
      final controller = await ref.read(folderSyncControllerProvider.future);
      await controller.turnOn(
        location: location,
        deviceLabel: 'This device',
        acknowledgedUnencrypted: true,
      );
    });
  }

  Future<void> _pair(FolderMemberCandidate member, FolderSyncSummary summary) async {
    final accepted = await _confirm(
      title: 'Pair with ${member.deviceLabel}?',
      body: 'On ${member.deviceLabel}, check that its key fingerprint reads '
          '${member.fingerprint}. Then pair only if it matches.\n\n'
          'This device\'s fingerprint is ${summary.fingerprint}; check that '
          '${member.deviceLabel} shows the same when you pair there.',
      action: 'It matches, pair',
      actionKey: const Key('folder_sync_confirm_pair'),
    );
    if (!accepted || !mounted) return;
    await _run(() async {
      final controller = await ref.read(folderSyncControllerProvider.future);
      await controller.pair(member.memberId);
    });
  }

  Future<void> _turnOff() async {
    final accepted = await _confirm(
      title: 'Turn off folder sync?',
      body: folderTurnOffNotice,
      action: 'Turn off',
      actionKey: const Key('folder_sync_confirm_turn_off'),
    );
    if (!accepted || !mounted) return;
    await _run(() async {
      final controller = await ref.read(folderSyncControllerProvider.future);
      await controller.turnOff();
    });
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(folderSyncSummaryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Sync through a folder')),
      backgroundColor: Colors.white,
      body: summary.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Folder sync is not available: $error'),
        ),
        data: (current) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Choose a folder that your file sync app (Syncthing, Nextcloud, '
              'Dropbox, …) keeps the same on each of your devices. No account or '
              'server is needed.',
              key: Key('folder_sync_intro'),
            ),
            const SizedBox(height: 8),
            const Text(
              folderNotEncryptedWarning,
              key: Key('folder_sync_permanent_warning'),
              style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
            ),
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(_message!,
                  key: const Key('folder_sync_message'),
                  style: const TextStyle(color: Color(0xFFB91C1C))),
            ],
            const SizedBox(height: 16),
            if (current == null)
              FilledButton(
                key: const Key('folder_sync_choose'),
                onPressed: _busy ? null : _chooseFolder,
                child: const Text('Choose a folder'),
              )
            else ..._active(current),
          ],
        ),
      ),
    );
  }

  List<Widget> _active(FolderSyncSummary summary) => [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Folder'),
          subtitle: Text(summary.folderLocation, key: const Key('folder_sync_location')),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(summary.deviceLabel),
          subtitle: Text('Key fingerprint ${summary.fingerprint}',
              key: const Key('folder_sync_fingerprint')),
        ),
        const Divider(),
        const Text('Other devices in this folder'),
        if (summary.members.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'None yet. Turn on folder sync on another device, then come back '
              'here once your file sync app has copied its files over.',
              key: Key('folder_sync_no_members'),
            ),
          ),
        for (final member in summary.members)
          ListTile(
            key: Key('folder_sync_member_${member.memberId}'),
            contentPadding: EdgeInsets.zero,
            title: Text(member.deviceLabel.isEmpty ? member.memberId : member.deviceLabel),
            subtitle: Text(member.problem ??
                (member.isPaired ? 'Paired' : 'Not paired — ${member.fingerprint}')),
            trailing: member.isPaired || member.problem != null
                ? null
                : TextButton(
                    key: Key('folder_sync_pair_${member.memberId}'),
                    onPressed: _busy ? null : () => _pair(member, summary),
                    child: const Text('Pair'),
                  ),
          ),
        const SizedBox(height: 16),
        OutlinedButton(
          key: const Key('folder_sync_turn_off'),
          onPressed: _busy ? null : _turnOff,
          child: const Text('Turn off folder sync'),
        ),
      ];
}
