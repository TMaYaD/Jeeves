import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import 'share_inbox.dart';

/// Drains the share-sheet queue into the Inbox when the app starts and every
/// time it returns to the foreground (a share made while Jeeves sat in the
/// background lands on the next `resumed`).
class ShareInboxHost extends ConsumerStatefulWidget {
  const ShareInboxHost({
    super.key,
    required this.child,
    this.filesDirectoryLoader = getApplicationSupportDirectory,
  });

  final Widget child;

  /// Resolves the directory the native receiver writes into
  /// (`Context.filesDir` == `getApplicationSupportDirectory()` on Android).
  final Future<Directory> Function() filesDirectoryLoader;

  @override
  ConsumerState<ShareInboxHost> createState() => _ShareInboxHostState();
}

class _ShareInboxHostState extends ConsumerState<ShareInboxHost> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(onResume: _drain);
    _drain();
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  Future<void> _drain() async {
    try {
      final filesDirectory = await widget.filesDirectoryLoader();
      if (!mounted) return;
      await drainShareInbox(
        db: ref.read(databaseProvider),
        filesDirectory: filesDirectory,
        userId: ref.read(currentUserIdProvider),
      );
    } on Object catch (error) {
      debugPrint('share inbox: drain failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
