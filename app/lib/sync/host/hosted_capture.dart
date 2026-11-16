/// The domain store's capture binding when a sync host exists.
///
/// At the end of the outermost capture scope — still inside the domain
/// transaction — it stamps a host clock on each coalesced effect and writes it to
/// `pending_changes`. The domain rows and their changes therefore commit, or roll
/// back, together; a process killed afterwards replays the rows at the host's next
/// start. After the commit it asks the host to drain.
///
/// Nothing here waits on the sync store: the clock and the device node id come
/// from the domain store alone, so a write on the first turn of a cold start is
/// clocked and durable before the host is even attached.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../../utils/uuid.dart';
import '../domain_op_capture.dart';
import '../hlc.dart';
import 'change.dart';

/// Something that can be asked to drain the outbox after a commit.
abstract interface class OutboxDrainer {
  Future<void> drain();
}

class HostedDomainOpCapture extends BufferedDomainOpCapture {
  HostedDomainOpCapture({required HlcClock clock}) : _clock = clock;

  final HlcClock _clock;
  OutboxDrainer? _drainer;

  /// The scopes that staged at least one change, so [commitScope] knows whether
  /// there is anything to drain.
  final Set<CaptureScope> _staged = <CaptureScope>{};

  /// Attach the host. Until then writes stage and wait.
  void attach(OutboxDrainer drainer) => _drainer = drainer;

  void detach() => _drainer = null;

  @override
  Future<void> stageInTransaction(CaptureScope scope, GeneratedDatabase db) async {
    if (!isOutermost(scope)) return;
    final effects = effectsOf(scope);
    if (effects.isEmpty) return;
    final identity = await readClockIdentity(db);
    final stampWith = identity.enrolledMemberIdHex ?? identity.deviceNodeId;
    for (final effect in effects) {
      final hlc = _clock.send(nodeIdHex: stampWith);
      final change = effect.tombstone
          ? Change(
              collection: effect.collection,
              entityId: effect.entityId,
              tombstone: hlc,
            )
          : Change(
              collection: effect.collection,
              entityId: effect.entityId,
              fields: {
                for (final field in effect.fields.entries)
                  field.key: ClockedValue(field.value, hlc),
              },
            );
      await db.customStatement(
        'INSERT INTO pending_changes (change_id, change_json) VALUES (?, ?)',
        [uuid.v4(), jsonEncode(change.toJson())],
      );
    }
    _staged.add(scope);
  }

  @override
  Future<void> commitScope(CaptureScope scope) async {
    final staged = _staged.remove(scope);
    await super.commitScope(scope);
    if (!staged) return;
    final drainer = _drainer;
    if (drainer == null) return;
    try {
      await drainer.drain();
    } on Object catch (error) {
      // The write and its change have both committed; a drain that fails is
      // retried by the next drain or at start (ADR-0040).
      debugPrint('sync host: drain after commit failed, will retry — $error');
    }
  }

  @override
  void rollbackScope(CaptureScope scope) {
    _staged.remove(scope);
    super.rollbackScope(scope);
  }

  /// The effects were staged, not emitted: nothing is authored from here.
  @override
  Future<void> emit(CapturedOp op) async {}
}

/// Forgets the enrolled member id, so later writes are stamped with the device
/// node id again.
///
/// One statement and no read first: when the row does not exist there is
/// nothing to forget, and this must not mint a device node id as a side effect.
Future<void> clearEnrolledMemberId(GeneratedDatabase db) => db.customStatement(
      'UPDATE device_clock_identity SET enrolled_member_id_hex = NULL '
      'WHERE id = 1',
    );

/// Reads — creating if absent — the device's clock identity through [db].
///
/// Usable inside a transaction on the same connection.
Future<({String deviceNodeId, String? enrolledMemberIdHex})> readClockIdentity(
  GeneratedDatabase db,
) async {
  final existing = await db.customSelect(
    'SELECT device_node_id, enrolled_member_id_hex FROM device_clock_identity '
    'WHERE id = 1',
  ).getSingleOrNull();
  if (existing != null) {
    return (
      deviceNodeId: existing.read<String>('device_node_id'),
      enrolledMemberIdHex: existing.readNullable<String>('enrolled_member_id_hex'),
    );
  }
  final bytes = uuid.v4().replaceAll('-', '');
  await db.customStatement(
    'INSERT OR IGNORE INTO device_clock_identity (id, device_node_id) VALUES (1, ?)',
    [bytes],
  );
  final row = await db.customSelect(
    'SELECT device_node_id, enrolled_member_id_hex FROM device_clock_identity '
    'WHERE id = 1',
  ).getSingle();
  return (
    deviceNodeId: row.read<String>('device_node_id'),
    enrolledMemberIdHex: row.readNullable<String>('enrolled_member_id_hex'),
  );
}
