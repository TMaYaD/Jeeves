import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the hidden developer-options section is unlocked.
///
/// Session-scoped and in memory only: it starts locked on every launch and is
/// unlocked by the About-section Easter egg (tapping the Jeeves name). It is not
/// persisted — the surface is meant to be re-discovered, not left switched on,
/// and nothing about it belongs in the synced preference store.
class DevOptionsUnlockedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void unlock() => state = true;
}

final devOptionsUnlockedProvider =
    NotifierProvider<DevOptionsUnlockedNotifier, bool>(
  DevOptionsUnlockedNotifier.new,
);
