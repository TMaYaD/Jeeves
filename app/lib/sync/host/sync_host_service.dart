/// The app-owned sync host.
///
/// Owns merge state, the merge core, the projector and the reconciler; drains the
/// domain store's `pending_changes` outbox into merge state and a durable change
/// sequence; and hands changes to plugins through [SyncPlugin.deliver], resuming
/// each from a cursor it stores. Built once per device, without a signed-in user.
///
/// **Ordering of a drain.** Per outbox row, one sync-store transaction merges the
/// change and (when any plugin cursor exists) appends it to the sequence; only
/// after that commit is the row deleted. A crash between the two commits replays
/// the row: the merge is idempotent and `change_id` is a unique key on the
/// sequence, so the replay leaves one entry.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../../database/gtd_database.dart';
import '../domain_projector.dart';
import '../domain_reconciler.dart';
import '../hlc.dart';
import '../merge_strategy.dart';
import '../sync_database.dart';
import '../sync_rejection.dart';
import 'change.dart';
import 'hosted_capture.dart';
import 'merge_core.dart';
import 'merge_state_seeder.dart';
import 'merge_state.dart';
import 'sync_host.dart';

/// Called with the changes a drain merged, in order — the interim bridge to the
/// op-log client. Failures are the listener's to contain.
typedef LocalChangeListener = Future<void> Function(List<Change> changes);

/// How many sequence entries one `deliver` call carries.
const int deliveryBatchSize = 200;

class SyncHostService implements SyncHost, OutboxDrainer {
  SyncHostService({
    required SyncDatabase sync,
    required GtdDatabase domain,
    required HlcClock clock,
    MergeStrategyRegistry strategies = const MergeStrategyRegistry(),
  })  : _sync = sync,
        _domain = domain,
        _clock = clock,
        _core = MergeCore(sync, strategies: strategies),
        registry = CollectionRegistry(sync) {
    projector = DomainProjector(registry: registry, domain: domain);
    reconciler = DomainReconciler(registry: registry, domain: domain);
  }

  final SyncDatabase _sync;
  final GtdDatabase _domain;
  final HlcClock _clock;
  final MergeCore _core;

  /// One registry over merge state for the whole device.
  final CollectionRegistry registry;
  late final DomainProjector projector;
  late final DomainReconciler reconciler;

  /// The interim op-log bridge (removed by moving the op log behind
  /// [SyncPlugin]).
  LocalChangeListener? localChangeListener;

  String? _deviceNodeId;
  bool _reconcileRetryRequired = false;
  Future<void> _drainTail = Future<void>.value();
  final Map<String, SyncPlugin> _plugins = <String, SyncPlugin>{};
  final Map<String, Future<void>> _deliveryTails = <String, Future<void>>{};

  /// Load the device identity and replay whatever the outbox still holds — the
  /// crash replay.
  Future<void> start() async {
    _deviceNodeId = (await readClockIdentity(_domain)).deviceNodeId;
    await drain();
  }

  // --- Seeding ---------------------------------------------------------------

  Future<void>? _seeding;

  /// Walk the domain rows this device already holds into merge state, once per
  /// device (see [MergeStateSeeder]). Concurrent callers share one walk; after a
  /// failure the next call walks again, picking up only what is still missing.
  /// Never touches the domain store beyond reading it.
  Future<void> ensureMergeStateSeeded() {
    final existing = _seeding;
    if (existing != null) return existing;
    final run = MergeStateSeeder(
      sync: _sync,
      domain: _domain,
      core: _core,
      deviceNodeId: deviceNodeId,
    ).runIfIncomplete();
    final shared = run.then((_) {});
    _seeding = shared;
    shared.then((_) {}, onError: (Object _) {
      if (identical(_seeding, shared)) _seeding = null;
    });
    return shared;
  }

  // --- Local writes ----------------------------------------------------------

  /// Merge every outbox row into merge state, in row order, then project the
  /// touched entities, notify the bridge and trigger delivery. Serialised.
  @override
  Future<void> drain() {
    final run = _drainTail.then((_) => _drainOnce());
    _drainTail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _drainOnce() async {
    final rows = await _domain
        .customSelect('SELECT id, change_id, change_json FROM pending_changes ORDER BY id')
        .get();
    if (rows.isEmpty) return;
    final touched = <AffectedEntity>{};
    final merged = <Change>[];
    Object? storageError;
    for (final row in rows) {
      final id = row.read<int>('id');
      final changeId = row.read<String>('change_id');
      final Change change;
      try {
        change = Change.fromJson(
            (jsonDecode(row.read<String>('change_json')) as Map).cast<String, Object?>());
      } on Object catch (error) {
        debugPrint('sync host: dropped an unreadable pending change $changeId — $error');
        try {
          await _deletePending(id);
        } on Object catch (deleteError) {
          storageError = deleteError;
          break;
        }
        continue;
      }
      try {
        touched.addAll(await _mergeAndSequence(change, changeId, 'local'));
      } on SyncRejection catch (rejection) {
        debugPrint('sync host: refused pending change $changeId — $rejection');
        try {
          await _deletePending(id);
        } on Object catch (deleteError) {
          storageError = deleteError;
          break;
        }
        continue;
      } on Object catch (error) {
        // A storage error: leave this row and everything behind it for the next
        // drain, so merge order stays outbox order.
        storageError = error;
        break;
      }
      try {
        await _deletePending(id);
      } on Object catch (error) {
        // Merged but still in the outbox: the next drain replays it as a no-op
        // merge (one sequence entry) and notifies then.
        storageError = error;
        break;
      }
      merged.add(change);
    }
    // Whatever merged and left the outbox is notified and delivered even when
    // the projection or a later row failed — its outbox row is gone, so nothing
    // else would hand it to the bridge.
    if (touched.isNotEmpty) {
      try {
        await projector.project(touched);
      } on Object catch (error) {
        storageError ??= error;
      }
    }
    final listener = localChangeListener;
    if (listener != null && merged.isNotEmpty) {
      try {
        await listener(merged);
      } on Object catch (error) {
        debugPrint('sync host: op-log bridge failed — $error');
      }
    }
    if (merged.isNotEmpty) _deliverInBackground();
    if (storageError != null) throw storageError;
  }

  void _deliverInBackground() {
    unawaited(_triggerDelivery().catchError((Object error) {
      debugPrint('sync host: delivery failed — $error');
    }));
  }

  Future<void> _deletePending(int id) =>
      _domain.customStatement('DELETE FROM pending_changes WHERE id = ?', [id]);

  Future<Set<AffectedEntity>> _mergeAndSequence(
    Change change,
    String changeId,
    String source,
  ) =>
      _sync.transaction(() async {
        final affected = await _core.apply(change);
        if (await _hasCursors()) {
          await _sync.customStatement(
            'INSERT OR IGNORE INTO change_sequence (change_id, source, change_json) '
            'VALUES (?, ?, ?)',
            [changeId, source, jsonEncode(change.toJson())],
          );
        }
        return affected;
      });

  Future<bool> _hasCursors() async =>
      (await _sync.customSelect('SELECT 1 FROM plugin_cursors LIMIT 1').get())
          .isNotEmpty;

  // --- SyncHost --------------------------------------------------------------

  @override
  Future<void> applyRemote(String sourcePluginId, List<Change> changes) async {
    final touched = <AffectedEntity>{};
    Object? storageError;
    for (final change in changes) {
      try {
        touched.addAll(await _mergeAndSequence(
          change,
          // A remote change has no outbox identity: derive a stable id from its
          // content so redelivery of the same change is one sequence entry.
          'remote:$sourcePluginId:'
          '${crypto.sha256.convert(utf8.encode(jsonEncode(change.toJson())))}',
          sourcePluginId,
        ));
      } on SyncRejection catch (rejection) {
        // One bad change must not stall the batch or leave what merged
        // unprojected; a redelivery would refuse it again.
        debugPrint('sync host: refused remote change from $sourcePluginId — $rejection');
        continue;
      } on Object catch (error) {
        storageError = error;
        break;
      }
      final highest = change.highestClock;
      if (highest != null) _clock.receive(highest);
    }
    if (touched.isNotEmpty) {
      try {
        final groups = await projector.project(touched);
        await _reconcileProjected(groups);
      } on Object catch (error) {
        storageError ??= error;
      }
      _deliverInBackground();
    }
    if (storageError != null) throw storageError;
  }

  /// Run the convergence passes over what a projection changed, containing any
  /// failure and re-arming — the passes detect from durable state, so a retry is
  /// safe (the rule `SyncClient._reconcileProjected` follows).
  Future<void> _reconcileProjected(Set<String> groups) async {
    try {
      await reconciler.reconcile(groups, force: _reconcileRetryRequired);
      _reconcileRetryRequired = false;
    } on Object {
      _reconcileRetryRequired = true;
    }
  }

  @override
  Stream<Change> snapshot() async* {
    final entities = (await reducedEntities(_sync)).toList()
      ..sort((a, b) {
        final byCollection = a.collection.compareTo(b.collection);
        return byCollection != 0 ? byCollection : a.entityId.compareTo(b.entityId);
      });
    for (final entity in entities) {
      yield await _readChange(entity.collection, entity.entityId);
    }
  }

  Future<Change> _readChange(String collection, String entityId) async {
    final fieldRows = await _sync.customSelect(
      'SELECT f.field AS field, f.value_json AS value_json, '
      'c.wall_ms AS wall_ms, c.counter AS counter, c.member_id_hex AS member_id_hex '
      'FROM reduced_fields f JOIN field_clocks c '
      'ON c.collection = f.collection AND c.entity_id = f.entity_id AND c.field = f.field '
      'WHERE f.collection = ? AND f.entity_id = ? ORDER BY f.field',
      variables: [Variable<String>(collection), Variable<String>(entityId)],
    ).get();
    final tombstoneRow = await (_sync.select(_sync.rowTombstones)
          ..where((row) =>
              row.collection.equals(collection) & row.entityId.equals(entityId)))
        .getSingleOrNull();
    return Change(
      collection: collection,
      entityId: entityId,
      fields: {
        for (final row in fieldRows)
          row.read<String>('field'): ClockedValue(
            jsonDecode(row.read<String>('value_json')),
            Hlc(row.read<int>('wall_ms'), row.read<int>('counter'),
                row.read<String>('member_id_hex')),
          ),
      },
      tombstone: tombstoneRow == null
          ? null
          : Hlc(tombstoneRow.wallMs, tombstoneRow.counter, tombstoneRow.memberIdHex),
    );
  }

  @override
  Hlc mintClock() {
    final node = _deviceNodeId;
    if (node == null) {
      throw StateError('SyncHostService.start must complete before mintClock');
    }
    return _clock.send(nodeIdHex: node);
  }

  // --- Things the op-log bridge needs ----------------------------------------

  /// Merge state whose winning clock names [nodeIdHex] — the changes this device
  /// made under its own node id, which no op ever carried.
  Future<List<Change>> changesStampedBy(String nodeIdHex) async {
    final fieldEntities = await _sync.customSelect(
      'SELECT DISTINCT collection, entity_id FROM field_clocks WHERE member_id_hex = ? '
      'UNION SELECT collection, entity_id FROM row_tombstones WHERE member_id_hex = ?',
      variables: [Variable<String>(nodeIdHex), Variable<String>(nodeIdHex)],
    ).get();
    final changes = <Change>[];
    for (final row in fieldEntities) {
      final whole = await _readChange(
          row.read<String>('collection'), row.read<String>('entity_id'));
      changes.add(Change(
        collection: whole.collection,
        entityId: whole.entityId,
        fields: {
          for (final field in whole.fields.entries)
            if (field.value.hlc.memberIdHex == nodeIdHex) field.key: field.value,
        },
        tombstone:
            whole.tombstone?.memberIdHex == nodeIdHex ? whole.tombstone : null,
      ));
    }
    return changes;
  }

  /// [changesStampedBy] for this device's own node id.
  Future<List<Change>> changesStampedByDevice() async => changesStampedBy(
      _deviceNodeId ?? (await readClockIdentity(_domain)).deviceNodeId);

  /// What the device wrote under its own node id after [afterWallMs] that is still
  /// visible, per entity, for upload once an account is back.
  ///
  /// A tombstone qualifies when it names the device; a field qualifies when it
  /// names the device **and** is live — no tombstone on the entity, or the field's
  /// clock newer than it, whoever stamped that tombstone. A hidden field is left
  /// out so an entity another device deleted is never revived by a stale
  /// signed-out edit. Clocks at or before [afterWallMs] are left out: they predate
  /// the account's upload, which deliberately left them off the log.
  /// [excludedCollections] are skipped altogether.
  Future<List<Change>> visibleChangesStampedByDeviceAfter(
    int afterWallMs, {
    Set<String> excludedCollections = const {},
  }) async {
    final node = _deviceNodeId ?? (await readClockIdentity(_domain)).deviceNodeId;
    final changes = <Change>[];
    for (final change in await changesStampedBy(node)) {
      if (excludedCollections.contains(change.collection)) continue;
      final deviceTombstone = change.tombstone;
      final tombstone =
          deviceTombstone != null && deviceTombstone.wallMs > afterWallMs
              ? deviceTombstone
              : null;
      final winningTombstone =
          (await _readChange(change.collection, change.entityId)).tombstone;
      final fields = {
        for (final field in change.fields.entries)
          if (field.value.hlc.wallMs > afterWallMs &&
              (winningTombstone == null || field.value.hlc > winningTombstone))
            field.key: field.value,
      };
      if (tombstone == null && fields.isEmpty) continue;
      changes.add(Change(
        collection: change.collection,
        entityId: change.entityId,
        fields: fields,
        tombstone: tombstone,
      ));
    }
    return changes;
  }

  /// A view of the device's one clock that stamps [memberIdHex] by default — what
  /// the op-log stack mints its own clocks (certificates, uploads, compaction) from.
  HlcClock clockForMember(String memberIdHex) => _clock.viewFor(memberIdHex);

  /// Entity ids in [collection] with at least one field or tombstone clock that
  /// names this device's own node id.
  Future<Set<String>> entityIdsStampedByDevice(String collection) async {
    final node = _deviceNodeId ?? (await readClockIdentity(_domain)).deviceNodeId;
    final rows = await _sync.customSelect(
      'SELECT entity_id FROM field_clocks WHERE collection = ? AND member_id_hex = ? '
      'UNION SELECT entity_id FROM row_tombstones WHERE collection = ? AND member_id_hex = ?',
      variables: [
        Variable<String>(collection),
        Variable<String>(node),
        Variable<String>(collection),
        Variable<String>(node),
      ],
    ).get();
    return {for (final row in rows) row.read<String>('entity_id')};
  }

  /// This device's node id (after [start]).
  String get deviceNodeId {
    final node = _deviceNodeId;
    if (node == null) {
      throw StateError('SyncHostService.start must complete first');
    }
    return node;
  }

  /// Record which member id, if any, local writes are stamped with.
  Future<void> setEnrolledMember(String? memberIdHex) async {
    await readClockIdentity(_domain);
    await _domain.customStatement(
      'UPDATE device_clock_identity SET enrolled_member_id_hex = ? WHERE id = 1',
      [memberIdHex],
    );
  }

  /// Clear the stored member id only if it still equals [memberIdHex].
  ///
  /// For an abandoned activation undoing its own write: the compare and the
  /// clear are one statement, so a newer account's id is never wiped.
  Future<void> clearEnrolledMemberIfEquals(String memberIdHex) async {
    await readClockIdentity(_domain);
    await _domain.customStatement(
      'UPDATE device_clock_identity SET enrolled_member_id_hex = NULL '
      'WHERE id = 1 AND enrolled_member_id_hex = ?',
      [memberIdHex],
    );
  }

  /// Merge changes saved from before a wipe back in, and project them.
  Future<void> restore(List<Change> changes) async {
    for (final change in changes) {
      await _core.apply(change);
    }
  }

  // --- Plugins and delivery --------------------------------------------------

  /// Attach [plugin]: record its cursor at the current head if it has none, start
  /// it, and deliver whatever it is owed. Earlier state reaches a new plugin
  /// through [snapshot].
  ///
  /// Waits for the seeding pass first, so the [snapshot] a plugin reads holds the
  /// whole local dataset. If the pass fails, attaching fails and no cursor is
  /// recorded.
  ///
  /// A plugin that does not start is not attached: the registration it took is
  /// given back, so a failed attach cannot take away a working one. The cursor
  /// stays — only turning sync off forgets it — so the changes made while the
  /// plugin was down are still owed to it when it comes back.
  Future<void> attach(SyncPlugin plugin) async {
    await ensureMergeStateSeeded();
    final previous = _plugins[plugin.id];
    _plugins[plugin.id] = plugin;
    try {
      await _sync.customStatement(
        'INSERT OR IGNORE INTO plugin_cursors (plugin_id, acknowledged_sequence) '
        'VALUES (?, COALESCE((SELECT MAX(sequence) FROM change_sequence), 0))',
        [plugin.id],
      );
      await plugin.start(this);
    } on Object {
      if (identical(_plugins[plugin.id], plugin)) {
        if (previous == null) {
          _plugins.remove(plugin.id);
        } else {
          _plugins[plugin.id] = previous;
        }
      }
      try {
        await plugin.stop();
      } on Object catch (error) {
        debugPrint('sync host: stopping a plugin that did not start failed — $error');
      }
      rethrow;
    }
    _deliverInBackground();
  }

  /// Stop [pluginId]. Its cursor is kept unless [forgetCursor], so a later attach
  /// resumes where it left off.
  Future<void> detach(String pluginId, {bool forgetCursor = false}) async {
    final plugin = _plugins.remove(pluginId);
    await plugin?.stop();
    if (forgetCursor) {
      await _sync
          .customStatement('DELETE FROM plugin_cursors WHERE plugin_id = ?', [pluginId]);
      await _prune();
    }
  }

  /// The plugin attached under [pluginId], or null when none is.
  SyncPlugin? pluginOf(String pluginId) => _plugins[pluginId];

  /// The highest sequence number [pluginId] has acknowledged.
  Future<int?> cursorOf(String pluginId) async {
    final row = await _sync.customSelect(
      'SELECT acknowledged_sequence FROM plugin_cursors WHERE plugin_id = ?',
      variables: [Variable<String>(pluginId)],
    ).getSingleOrNull();
    return row?.read<int>('acknowledged_sequence');
  }

  /// Run delivery to every attached plugin and wait until each has nothing
  /// further to take.
  Future<void> deliverAll() => _triggerDelivery();

  Future<void> _triggerDelivery() {
    final runs = <Future<void>>[];
    for (final plugin in _plugins.values.toList()) {
      final previous = _deliveryTails[plugin.id] ?? Future<void>.value();
      final run = previous.then((_) => _deliverTo(plugin));
      _deliveryTails[plugin.id] = run.then((_) {}, onError: (Object _) {});
      runs.add(run);
    }
    return Future.wait(runs);
  }

  Future<void> _deliverTo(SyncPlugin plugin) async {
    while (true) {
      final cursor = await cursorOf(plugin.id);
      if (cursor == null) return;
      final rows = await _sync.customSelect(
        'SELECT sequence, source, change_json FROM change_sequence '
        'WHERE sequence > ? ORDER BY sequence LIMIT ?',
        variables: [Variable<int>(cursor), Variable<int>(deliveryBatchSize)],
      ).get();
      if (rows.isEmpty) return;
      final lastSequence = rows.last.read<int>('sequence');
      final owed = <SequencedChange>[
        for (final row in rows)
          if (row.read<String>('source') != plugin.id)
            SequencedChange(
              row.read<int>('sequence'),
              Change.fromJson((jsonDecode(row.read<String>('change_json')) as Map)
                  .cast<String, Object?>()),
            ),
      ];
      int acknowledged;
      if (owed.isEmpty) {
        // Nothing this plugin is owed: pass its own entries without a call.
        acknowledged = lastSequence;
      } else {
        try {
          acknowledged = await plugin.deliver(owed);
        } on Object catch (error) {
          debugPrint('sync host: plugin ${plugin.id} failed to take changes — $error');
          return;
        }
        // Never believe an acknowledgement beyond what was delivered.
        final highestDelivered = owed.last.sequence;
        if (acknowledged > highestDelivered) acknowledged = highestDelivered;
        // An acknowledgement short of the last owed entry still moves the cursor
        // only as far as it says. Skipped own-source entries ahead of the first
        // owed entry are covered by an acknowledgement that reaches it.
      }
      if (acknowledged <= cursor) return;
      await _sync.customStatement(
        'UPDATE plugin_cursors SET acknowledged_sequence = ? WHERE plugin_id = ?',
        [acknowledged, plugin.id],
      );
      await _prune();
    }
  }

  Future<void> _prune() => _sync.customStatement(
        'DELETE FROM change_sequence WHERE sequence <= '
        '(SELECT COALESCE(MIN(acknowledged_sequence), 0) FROM plugin_cursors)',
      );

  /// Stop every attached plugin. The host stays usable.
  Future<void> stopPlugins() async {
    for (final plugin in _plugins.values.toList()) {
      await plugin.stop();
    }
    _plugins.clear();
  }
}
