/// The interface between the app and a sync plugin.
///
/// The device database is the source of truth on every device and sync is a
/// plugin: a plugin carries changes between this device and somewhere else, and
/// never decides what a field's value is. The app does, with the merge
/// strategies it already has. Design: `docs/proposals/sync-plugins.md`.
library;

import '../hlc.dart';
import 'change.dart';

/// What the app gives a plugin.
abstract interface class SyncHost {
  /// Merge remote changes, project, reconcile, and forward them to every other
  /// attached plugin. Idempotent: a change already merged is a no-op.
  Future<void> applyRemote(String sourcePluginId, List<Change> changes);

  /// Current merged state, for a plugin's first upload or full rewrite.
  Stream<Change> snapshot();

  /// A fresh clock, for a plugin whose medium carries none.
  Hlc mintClock();
}

/// What a plugin implements.
abstract interface class SyncPlugin {
  String get id;

  Future<void> start(SyncHost host);

  Future<void> stop();

  /// The next changes after this plugin's acknowledged position in the host's
  /// change sequence — local writes and other plugins' changes alike. Returns
  /// the highest sequence number the plugin has durably handed off, which
  /// acknowledges a contiguous prefix: every change up to it, with no gaps.
  Future<int> deliver(List<SequencedChange> changes);

  Stream<PluginHealth> get health;
}
