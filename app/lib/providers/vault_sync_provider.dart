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

import '../auth/session_gate.dart';
import '../sync/host/sync_host_service.dart';
import '../sync/vault/android_vault_folder.dart';
import '../sync/vault/vault_folder.dart';
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

/// The vault's setting: this device's reference to the folder.
///
/// One string in the device's preferences. **The preferences API changes its
/// cache before it asks the platform**, so a write the platform refuses leaves
/// the cache and the platform disagreeing: the cache says the folder changed
/// and the platform says it did not. The setting is behind a seam so that
/// disagreement can be exercised rather than assumed away.
abstract class VaultFolderSetting {
  /// This device's reference to the folder, or null when the vault is off.
  Future<String?> read();

  /// Keep [reference] as this device's reference to the folder.
  ///
  /// False when the platform refused the write.
  Future<bool> save(String reference);

  /// Forget this device's reference to the folder.
  ///
  /// False when the platform refused.
  Future<bool> clear();
}

/// The vault's setting, in the device's shared preferences.
class PrefsVaultFolderSetting implements VaultFolderSetting {
  const PrefsVaultFolderSetting();

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kVaultFolderKey);
  }

  @override
  Future<bool> save(String reference) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.setString(_kVaultFolderKey, reference);
  }

  @override
  Future<bool> clear() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.remove(_kVaultFolderKey);
  }
}

/// The vault's setting, on this device.
final vaultFolderSettingProvider = Provider<VaultFolderSetting>(
  (ref) => const PrefsVaultFolderSetting(),
);

/// The vault's folder on this device, or null when the vault is off.
///
/// Null means off: there is no second switch that could disagree with it.
final vaultFolderProvider = FutureProvider<String?>((ref) async {
  final setting = ref.watch(vaultFolderSettingProvider);
  return setting.read();
});

/// How the vault's folder is chosen.
///
/// Overridden in tests: the system picker is a dialog, and a dialog cannot run
/// headless. Everything else about the vault is real.
final vaultFolderPickerProvider =
    Provider<Future<String?> Function()>((ref) => pickVaultFolder);

/// Whether this platform has a folder picker for the vault.
///
/// Android has the system document-tree picker. The web has no folder at all,
/// and no other platform has a system picker that names one: the vault's setup
/// is not offered there, and a folder that is already configured can still be
/// forgotten.
bool vaultFolderPickerAvailable() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android;
}

/// Whether this platform has a folder picker for the vault.
final vaultFolderPickerAvailableProvider =
    Provider<bool>((ref) => vaultFolderPickerAvailable());

/// The system folder picker, on the platforms that have one.
///
/// Android, over the document-tree channel the op-log folder plugin already
/// provides — one channel, one picker, no broad storage permission. Elsewhere
/// there is no folder to pick, and the vault's tile is not shown.
Future<String?> pickVaultFolder() async {
  if (!vaultFolderPickerAvailable()) return null;
  return pickAndroidVaultFolder();
}

/// The folder a vault setting names.
///
/// Overridden in tests: a test needs a folder it can make slow, or make fail,
/// and the real folder is reached through the platform.
final vaultFolderFactoryProvider =
    Provider<VaultFolder Function(String reference)>((ref) => openVaultFolder);

/// This device's session, as a provider.
///
/// The gate is a [ValueNotifier] because the router needs it outside a
/// `ProviderScope`. This mirror lets a provider watch it: the notifier's state
/// is the gate, and it changes when the gate does.
final sessionGateProvider =
    NotifierProvider<SessionGateNotifier, SessionGate>(SessionGateNotifier.new);

/// The session gate, watched.
///
/// **One listener, whatever happens.** The notifier is kept across rebuilds, so
/// the listener one build registers is taken away before the next one puts its
/// own in its place.
class SessionGateNotifier extends Notifier<SessionGate> {
  void Function()? _listener;

  @override
  SessionGate build() {
    _removeListener();
    void listener() {
      if (!ref.mounted) return;
      state = sessionGateNotifier.value;
    }
    _listener = listener;
    sessionGateNotifier.addListener(listener);
    ref.onDispose(_removeListener);
    return sessionGateNotifier.value;
  }

  void _removeListener() {
    final listener = _listener;
    if (listener == null) return;
    _listener = null;
    sessionGateNotifier.removeListener(listener);
  }
}

/// The vault plugin, attached while this device has a vault folder set.
///
/// **Watching this provider is what runs the vault.** It attaches the plugin to
/// the host and reads the folder again while the app is open; when the folder
/// is taken away it detaches the plugin, forgets its cursor and clears this
/// device's base copies.
///
/// **One plugin at a time** (#914): the vault runs where the op log does not.
/// The session gate says which mode this device is in, and while the gate is
/// still being restored the answer is not known — so the vault waits for it
/// rather than run beside an op log that is about to start.
final vaultPluginProvider = FutureProvider<VaultPlugin?>((ref) async {
  // Only whether the vault may run is watched, not the gate itself: signing in
  // moves the gate between two states that both allow the vault, and a rebuild
  // would detach the plugin and clear its base copies for nothing.
  final gateAllowsVault = ref.watch(sessionGateProvider.select(
      (gate) => gate != SessionGate.checking && gate != SessionGate.ready));
  if (!gateAllowsVault) return null; // checking, or the op log runs.

  // The provider is disposed when the vault is turned off, or when the folder
  // changes; the flag tells a build that is still waiting that it no longer
  // owns the vault.
  var stopped = false;
  ref.onDispose(() => stopped = true);

  final reference = await ref.watch(vaultFolderProvider.future);
  if (reference == null) return null; // no folder: the vault is off
  if (stopped) return null;

  final host = await ref.watch(syncHostProvider.future);
  if (stopped) return null;

  final sync = await ref.watch(syncDatabaseProvider.future);
  if (stopped) return null;

  final folder = ref.watch(vaultFolderFactoryProvider)(reference);
  final plugin = VaultPlugin(folder: folder, sync: sync);
  final attachment = _VaultAttachment(host: host, plugin: plugin);
  // Registered before the attach is awaited: a vault that is turned off while
  // its first scan is running still takes its plugin back off the host, and a
  // first scan that fails does not leave the host holding a plugin nobody
  // reads.
  ref.onDispose(attachment.stop);

  try {
    await attachment.attach();
  } on Object {
    await attachment.rollBack();
    rethrow;
  }
  if (stopped) return null;
  return plugin;
});

/// One vault's attachment to the host.
///
/// Owns the plugin, the timer that reads the folder again and the observer
/// that reads it when the app comes forward.
///
/// **The cleanup is registered before the attach is awaited.** A vault that is
/// turned off while its first scan is running must still take its plugin back
/// off the host, and a first scan that fails must not leave the host holding a
/// plugin nobody reads.
class _VaultAttachment {
  _VaultAttachment({required this.host, required this.plugin});

  final SyncHostService host;
  final VaultPlugin plugin;

  _VaultScanSchedule? _scans;
  Timer? _scanTimer;
  _VaultResumeObserver? _resumeObserver;
  bool _stopped = false;

  /// Attach to the host and start reading the folder.
  Future<void> attach() async {
    final scans = _VaultScanSchedule(plugin: plugin, host: host);
    _scans = scans;
    await _vaultLifecycle(() => host.attach(plugin));
    if (_stopped) return;
    _scanTimer = Timer.periodic(_vaultScanInterval, (_) => scans.request());
    final observer = _VaultResumeObserver(() => scans.request());
    _resumeObserver = observer;
    WidgetsBinding.instance.addObserver(observer);
  }

  /// Stop reading the folder and take the plugin off the host.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _scanTimer?.cancel();
    _scanTimer = null;
    final observer = _resumeObserver;
    _resumeObserver = null;
    if (observer != null) WidgetsBinding.instance.removeObserver(observer);
    _scans?.forgetWaiting();
    unawaited(_detach());
  }

  /// Take the plugin off the host and drop this device's base copies.
  ///
  /// The cursor goes with it: otherwise the change sequence grows with nobody
  /// reading it. The base copies go with it: they are copies, and the next
  /// start reads the folder again. The folder itself is left as it is.
  ///
  /// The store can already be closed when the app is shutting down — the vault
  /// is still off, and the next start reads the folder again — so a closed
  /// store is logged, not thrown.
  Future<void> _detach() async {
    await _vaultLifecycle(() async {
      try {
        await host.detach(plugin.id, forgetCursor: true);
        await plugin.clearBases();
      } on Object catch (error) {
        debugPrint('vault: detaching failed — $error');
      }
    });
  }

  /// Take the plugin off the host after a failed attach.
  ///
  /// The cursor is kept: the vault never started, so there is nothing to
  /// forget, and the next start resumes where it left off.
  Future<void> rollBack() async {
    await _vaultLifecycle(() async {
      try {
        await host.detach(plugin.id);
      } on Object catch (error) {
        debugPrint('vault: the failed attachment was not taken off — $error');
      }
    });
  }
}

/// The vault's reads of the folder.
///
/// **One read at a time, and at most one waiting.** A folder that takes longer
/// to read than the tick has to wait must not queue a read behind every tick:
/// the queue would grow without bound, the host's own writes would wait behind
/// it, and stopping the vault would wait for all of it.
///
/// A read that fails is the folder's problem, not the app's: it is logged, and
/// the next tick reads the folder again.
class _VaultScanSchedule {
  _VaultScanSchedule({required this.plugin, required this.host});

  final VaultPlugin plugin;
  final SyncHostService host;

  bool _reading = false;
  bool _waiting = false;

  /// Read the folder again.
  void request() {
    if (_reading) {
      _waiting = true;
      return;
    }
    _reading = true;
    unawaited(_run());
  }

  /// Forget the waiting read: the vault is stopping.
  void forgetWaiting() => _waiting = false;

  Future<void> _run() async {
    try {
      do {
        _waiting = false;
        await _readOnce();
      } while (_waiting);
    } finally {
      _reading = false;
    }
  }

  Future<void> _readOnce() async {
    try {
      await plugin.rescan();
    } on Object catch (error) {
      debugPrint('vault: the folder was not read — $error');
    }
    // What the host still owes this device: a page whose write failed is
    // delivered again once the folder is writable again. The delivery is asked
    // for here, outside the plugin's own queue, because the delivery needs
    // that queue.
    try {
      await host.deliverAll();
    } on Object catch (error) {
      debugPrint('vault: the host could not deliver — $error');
    }
  }
}

/// The vault's attachments, one at a time.
///
/// The host keys its plugins by id, and the vault's id does not change when the
/// folder does: the old vault's cleanup and the new vault's attachment must not
/// overlap, or the old one's cleanup takes the new one's cursor away and the
/// new vault is left with nothing to receive.
Future<void> _vaultLifecycleTail = Future<void>.value();

/// Run [action] after every vault action already queued.
Future<T> _vaultLifecycle<T>(Future<T> Function() action) {
  final run = _vaultLifecycleTail.then((_) => action());
  _vaultLifecycleTail = run.then<void>((_) {}, onError: (Object _) {});
  return run;
}

/// What a turn of the vault did.
enum VaultTurnOutcome {
  /// The setting changed, and the change reached storage.
  changed,

  /// The picker was cancelled: nothing was decided, and nothing changed.
  cancelled,

  /// The picker failed: no folder was chosen.
  pickerFailed,

  /// The setting did not reach storage: the vault is as it was.
  notPersisted,
}

/// Turns the vault on and off.
class VaultController {
  VaultController(this._ref);

  final Ref _ref;

  /// Choose a folder and turn the vault on.
  ///
  /// Does nothing when the person cancels the picker: a cancelled picker is not
  /// a decision to stop syncing.
  Future<VaultTurnOutcome> turnOn() async {
    final String? reference;
    try {
      reference = await _ref.read(vaultFolderPickerProvider)();
    } on Object catch (error) {
      // The picker is the platform's: a failure there is the person's to see,
      // and the vault is left as it was.
      debugPrint('vault: the folder picker failed — $error');
      return VaultTurnOutcome.pickerFailed;
    }
    if (reference == null) return VaultTurnOutcome.cancelled;
    return _save(reference);
  }

  /// Turn the vault off.
  ///
  /// The folder is left where it is; only this device's syncing through it
  /// stops.
  Future<VaultTurnOutcome> turnOff() => _clear();

  Future<VaultTurnOutcome> _save(String reference) async {
    final setting = _ref.read(vaultFolderSettingProvider);
    final bool saved;
    try {
      saved = await setting.save(reference);
    } on Object catch (error) {
      debugPrint('vault: the folder reference did not reach storage — $error');
      return VaultTurnOutcome.notPersisted;
    }
    if (!saved) {
      // The preferences API changes its cache before it asks the platform: a
      // refused write leaves the two disagreeing, and the change is not
      // presented as a successful toggle.
      debugPrint('vault: the platform refused the folder reference');
      return VaultTurnOutcome.notPersisted;
    }
    _ref.invalidate(vaultFolderProvider);
    return VaultTurnOutcome.changed;
  }

  Future<VaultTurnOutcome> _clear() async {
    final setting = _ref.read(vaultFolderSettingProvider);
    final bool cleared;
    try {
      cleared = await setting.clear();
    } on Object catch (error) {
      debugPrint('vault: the folder reference did not reach storage — $error');
      return VaultTurnOutcome.notPersisted;
    }
    if (!cleared) {
      debugPrint('vault: the platform refused to forget the folder reference');
      return VaultTurnOutcome.notPersisted;
    }
    _ref.invalidate(vaultFolderProvider);
    return VaultTurnOutcome.changed;
  }
}

final vaultControllerProvider =
    Provider<VaultController>((ref) => VaultController(ref));

class _VaultResumeObserver with WidgetsBindingObserver {
  _VaultResumeObserver(this._onResumed);

  final void Function() _onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResumed();
  }
}
