/// The vault: sync through a folder of Markdown pages.
///
/// **One plugin at a time** (#914). The op log is not yet behind the plugin
/// interface, so the vault runs where the op log does not: the Settings tile is
/// offered on a device that has not enrolled for the op log, and the op log's
/// own tile is not offered while the vault is on.
///
/// The vault's whole setting is one string: this device's reference to the
/// folder — a tree URI on Android, a path elsewhere. It is device-local and
/// never synced: this device's reference to the folder is nobody else's
/// business, and another device reaches the same folder through its own picker
/// or through whatever syncer carries it.
///
/// **The plugin is a carrier.** It turns a page into changes, hands them to the
/// host, and writes the host's merged state back as a page. Nothing here
/// decides what a field's value is.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sync/host/sync_host_service.dart';
import '../sync/vault/android_vault_folder.dart';
import '../sync/vault/vault_folder_factory.dart';
import '../sync/vault/vault_plugin.dart';
import 'sync_stack_provider.dart';

/// The device-local key of the vault's folder reference.
const String _kVaultFolderKey = 'vault_folder_reference';

/// How often the folder is read again while the app is open.
///
/// A syncer brings another device's pages at its own pace, and a person edits a
/// page in whatever editor they use. Neither announces itself, so the folder is
/// read again on a timer and whenever the app comes back to the foreground.
const Duration _vaultScanInterval = Duration(seconds: 30);

/// The vault's folder on this device, or null when the vault is off.
///
/// Null means off: there is no second switch that could disagree with it.
final vaultFolderProvider = FutureProvider<String?>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kVaultFolderKey);
});

/// How the vault's folder is chosen.
///
/// Overridden in tests: the system picker is a dialog, and a dialog cannot run
/// headless. Everything else about the vault is real.
final vaultFolderPickerProvider =
    Provider<Future<String?> Function()>((ref) => pickVaultFolder);

/// The system folder picker, on the platforms that have one.
///
/// Android, over the document-tree channel the op-log folder plugin already
/// provides — one channel, one picker, no broad storage permission. Elsewhere
/// there is no folder to pick, and the vault's tile is not shown.
Future<String?> pickVaultFolder() async {
  if (kIsWeb) return null;
  if (defaultTargetPlatform == TargetPlatform.android) {
    return pickAndroidVaultFolder();
  }
  return null;
}

/// The vault plugin, attached while this device has a vault folder set.
///
/// **Watching this provider is what runs the vault.** It attaches the plugin to
/// the host and reads the folder again while the app is open; when the folder
/// is taken away it detaches the plugin, forgets its cursor and clears this
/// device's base copies.
final vaultPluginProvider = FutureProvider<VaultPlugin?>((ref) async {
  final reference = await ref.watch(vaultFolderProvider.future);
  if (reference == null) return null;

  final host = await ref.watch(syncHostProvider.future);
  final sync = await ref.watch(syncDatabaseProvider.future);
  final plugin = VaultPlugin(folder: openVaultFolder(reference), sync: sync);
  await host.attach(plugin);

  final timer = Timer.periodic(_vaultScanInterval, (_) {
    unawaited(plugin.rescan());
  });
  final observer = _VaultResumeObserver(() => unawaited(plugin.rescan()));
  WidgetsBinding.instance.addObserver(observer);

  ref.onDispose(() {
    timer.cancel();
    WidgetsBinding.instance.removeObserver(observer);
    unawaited(_forgetTheVault(host, plugin));
  });

  return plugin;
});

/// Turns the vault on and off.
class VaultController {
  VaultController(this._ref);

  final Ref _ref;

  /// Choose a folder and turn the vault on.
  ///
  /// Does nothing when the person cancels the picker: a cancelled picker is not
  /// a decision to stop syncing.
  Future<void> turnOn() async {
    final reference = await _ref.read(vaultFolderPickerProvider)();
    if (reference == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kVaultFolderKey, reference);
    _ref.invalidate(vaultFolderProvider);
  }

  /// Turn the vault off.
  ///
  /// The folder is left where it is; only this device's syncing through it
  /// stops.
  Future<void> turnOff() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kVaultFolderKey);
    _ref.invalidate(vaultFolderProvider);
  }
}

final vaultControllerProvider =
    Provider<VaultController>((ref) => VaultController(ref));

/// Detach the plugin and drop this device's base copies.
///
/// Forget the cursor: otherwise the change sequence grows with nobody reading
/// it. Clear this device's base copies: they are copies, and the next start
/// reads the folder again. The folder itself is left as it is.
///
/// The store can already be closed when the app is shutting down — the vault
/// is still on, and the next start picks the cursor up where it left off — so a
/// closed store is logged, not thrown.
Future<void> _forgetTheVault(SyncHostService host, VaultPlugin plugin) async {
  try {
    await host.detach(plugin.id, forgetCursor: true);
    await plugin.clearBases();
  } on Object catch (error) {
    debugPrint('vault: detaching at shutdown failed — $error');
  }
}

class _VaultResumeObserver with WidgetsBindingObserver {
  _VaultResumeObserver(this._onResumed);

  final void Function() _onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResumed();
  }
}
