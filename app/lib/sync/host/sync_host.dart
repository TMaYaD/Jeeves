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
  ///
  /// Returns the changes the host **refused** — the ones it could not merge
  /// deterministically. A refused change is not merged, but it does not stall
  /// the batch: the changes around it are merged and projected as usual. A
  /// caller that must know whether its content was taken reads this list: a
  /// change that is not in it was taken.
  Future<List<Change>> applyRemote(String sourcePluginId, List<Change> changes);

  /// Current merged state, for a plugin's first upload or full rewrite.
  ///
  /// Every entity the host holds any trace of, with the same effective
  /// visibility [mergedEntity] reports.
  Stream<Change> snapshot();

  /// One entity's merged state — every field the host holds with its clock, and
  /// its tombstone — as the host holds it right now. What a plugin whose medium
  /// shows state (rather than changes) renders from; [deliver] is then only the
  /// signal that the entity changed, so the plugin never compares clocks
  /// itself.
  ///
  /// The tombstone is the entity's **effective** deletion: it is there only
  /// while the entity is not revived. The host's own rule — the merge core's,
  /// and the SQL in `merge_state.dart` — is that a field whose clock is newer
  /// than the tombstone is live and revives the entity. So an entity that was
  /// deleted and then written again is live, and comes back with no tombstone.
  ///
  /// The fields are every field the host holds, live or not. A deleted entity's
  /// hidden values are what a plugin needs to preserve what the entity held.
  Future<Change> mergedEntity(String collection, String entityId);

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
