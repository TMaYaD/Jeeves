import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/notification_service.dart';

/// Whether the OS currently lets Jeeves show notifications. Read at startup
/// and again on every app resume, because the user can change it in system
/// settings. Starts `true` so nothing flashes before the first read.
final notificationPermissionProvider =
    NotifierProvider<NotificationPermissionNotifier, bool>(
        NotificationPermissionNotifier.new);

class NotificationPermissionNotifier extends Notifier<bool>
    with WidgetsBindingObserver {
  @override
  bool build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(this));
    refresh();
    return true;
  }

  Future<void> refresh() async {
    final allowed =
        await ref.read(notificationServiceProvider).areNotificationsAllowed();
    state = allowed;
  }

  /// Asks the OS again. Android stops showing its dialog after two refusals,
  /// in which case the answer stays "denied" and the user must use system
  /// settings.
  Future<void> request() async {
    await ref.read(notificationServiceProvider).requestPermissions();
    await refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }
}
