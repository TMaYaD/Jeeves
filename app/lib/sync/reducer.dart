/// Field-grain last-write-wins reduction over the op log.
///
/// The rules, all pinned by `spec/sync/reducer_v1_vectors.json`:
///
/// - A field applies iff its HLC is strictly greater than the stored one. Equal
///   HLCs are an idempotent skip, which is also what makes a pulled echo of the
///   device's own op a no-op.
/// - A field's HLC is its own when it carries one, else the op-level HLC.
/// - Deletion is a tombstone op with its own HLC. Visibility is decided at read
///   time — a field newer than the tombstone is live and revives the entity, a
///   field older stays hidden. Nothing is deleted, so reduction is
///   order-independent in both directions.
/// - **The guards are scoped to the op-level HLC only** (review F15, as ruled
///   for this slice). Per-field HLCs are exempt: a compaction op (#555)
///   legitimately re-asserts *other authors'* older clocks per field, and
///   checking those would make compaction impossible. The exemption is *from
///   the guards, not from LWW* — a re-asserted older clock still loses.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import 'envelope.dart';
import 'hlc.dart';
import 'op_payload.dart';
import 'sync_database.dart';

/// How far ahead of local time an op-level `wall_ms` may be before the op is
/// quarantined. Without a bound, any member could pin a field against every
/// future edit by writing a clock in 2099 (review F15).
const int defaultFutureSkewBoundMs = 5 * 60 * 1000;

class Reducer {
  Reducer(
    this._db, {
    required int Function() nowMs,
    this.futureSkewBoundMs = defaultFutureSkewBoundMs,
  }) : _nowMs = nowMs;

  final SyncDatabase _db;
  final int Function() _nowMs;
  final int futureSkewBoundMs;

  /// Apply [payload], or throw [SyncRejection] so the caller quarantines it.
  Future<void> apply(
    OpPayload payload, {
    required String authorMemberIdHex,
  }) async {
    _guard(payload, authorMemberIdHex);
    await _db.transaction(() async {
      if (payload.tombstone) {
        await _applyTombstone(payload);
      }
      for (final entry in payload.fields.entries) {
        await _applyField(payload, entry.key, entry.value);
      }
    });
  }

  void _guard(OpPayload payload, String authorMemberIdHex) {
    if (payload.hlc.wallMs > _nowMs() + futureSkewBoundMs) {
      throw SyncRejection(
        SyncRejectionReason.hlcInTheFuture,
        'op wall_ms ${payload.hlc.wallMs} is beyond the '
        '${futureSkewBoundMs}ms skew bound',
      );
    }
    if (payload.hlc.memberIdHex != authorMemberIdHex) {
      throw SyncRejection(
        SyncRejectionReason.hlcMemberIsNotAuthor,
        'op hlc member ${payload.hlc.memberIdHex} is not the header author '
        '$authorMemberIdHex',
      );
    }
  }

  Future<void> _applyTombstone(OpPayload payload) async {
    final existing = await (_db.select(_db.rowTombstones)
          ..where((row) =>
              row.collection.equals(payload.collection) &
              row.entityId.equals(payload.entityId)))
        .getSingleOrNull();
    if (existing != null &&
        !(payload.hlc >
            Hlc(existing.wallMs, existing.counter, existing.memberIdHex))) {
      return;
    }
    await _db.into(_db.rowTombstones).insertOnConflictUpdate(
          RowTombstonesCompanion.insert(
            collection: payload.collection,
            entityId: payload.entityId,
            wallMs: payload.hlc.wallMs,
            counter: payload.hlc.counter,
            memberIdHex: payload.hlc.memberIdHex,
          ),
        );
  }

  Future<void> _applyField(
    OpPayload payload,
    String field,
    FieldWrite write,
  ) async {
    final clock = write.hlc ?? payload.hlc;
    final stored = await (_db.select(_db.fieldClocks)
          ..where((row) =>
              row.collection.equals(payload.collection) &
              row.entityId.equals(payload.entityId) &
              row.field.equals(field)))
        .getSingleOrNull();
    if (stored != null &&
        !(clock > Hlc(stored.wallMs, stored.counter, stored.memberIdHex))) {
      return;
    }
    await _db.into(_db.reducedFields).insertOnConflictUpdate(
          ReducedFieldsCompanion.insert(
            collection: payload.collection,
            entityId: payload.entityId,
            field: field,
            valueJson: jsonEncode(write.value),
          ),
        );
    await _db.into(_db.fieldClocks).insertOnConflictUpdate(
          FieldClocksCompanion.insert(
            collection: payload.collection,
            entityId: payload.entityId,
            field: field,
            wallMs: clock.wallMs,
            counter: clock.counter,
            memberIdHex: clock.memberIdHex,
          ),
        );
  }
}

/// Typed reads over one collection's reduced state.
///
/// ADR-0011's per-collection Conflict Strategy registry is not wired in here:
/// every collection in this slice uses plain field-grain LWW, and #550 is where
/// the strategies plug into this seam.
class CollectionView {
  CollectionView(this._db, this.collection);

  final SyncDatabase _db;
  final String collection;

  static const String _liveFieldsSql = '''
SELECT f.entity_id AS entity_id, f.field AS field, f.value_json AS value_json
FROM reduced_fields f
JOIN field_clocks c
  ON c.collection = f.collection AND c.entity_id = f.entity_id AND c.field = f.field
LEFT JOIN row_tombstones t
  ON t.collection = f.collection AND t.entity_id = f.entity_id
WHERE f.collection = ?
  AND (
    t.entity_id IS NULL
    OR c.wall_ms > t.wall_ms
    OR (c.wall_ms = t.wall_ms AND c.counter > t.counter)
    OR (c.wall_ms = t.wall_ms AND c.counter = t.counter
        AND c.member_id_hex > t.member_id_hex)
  )
ORDER BY f.entity_id, f.field
''';

  Selectable<QueryRow> _liveFields() => _db.customSelect(
        _liveFieldsSql,
        variables: [Variable<String>(collection)],
        readsFrom: {_db.reducedFields, _db.fieldClocks, _db.rowTombstones},
      );

  static Map<String, Map<String, Object?>> _group(List<QueryRow> rows) {
    final entities = <String, Map<String, Object?>>{};
    for (final row in rows) {
      entities
          .putIfAbsent(row.read<String>('entity_id'), () => <String, Object?>{})[
          row.read<String>('field')] = jsonDecode(row.read<String>('value_json'));
    }
    return entities;
  }

  /// Every live entity, as `{entity id: {field: value}}`. An entity with no
  /// live field is absent.
  Future<Map<String, Map<String, Object?>>> readAll() async =>
      _group(await _liveFields().get());

  Stream<Map<String, Map<String, Object?>>> watchAll() =>
      _liveFields().watch().map(_group);

  Future<Map<String, Object?>?> readEntity(String entityId) async =>
      (await readAll())[entityId];

  Stream<Map<String, Object?>?> watchEntity(String entityId) =>
      watchAll().map((entities) => entities[entityId]);
}

/// The collections this client knows how to read back.
///
/// Reduction itself is collection-generic — an op for an unregistered
/// collection still reduces, because a device that has not yet shipped a
/// feature must not lose its peers' writes. Registration is what gives a
/// collection a typed read surface.
class CollectionRegistry {
  CollectionRegistry(this._db);

  final SyncDatabase _db;
  final Map<String, CollectionView> _views = {};

  CollectionView register(String collection) =>
      _views.putIfAbsent(collection, () => CollectionView(_db, collection));

  CollectionView view(String collection) {
    final registered = _views[collection];
    if (registered == null) {
      throw StateError('Collection "$collection" is not registered');
    }
    return registered;
  }

  Iterable<String> get registered => _views.keys;
}
