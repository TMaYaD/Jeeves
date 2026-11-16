/// Reads over merge state — what the projector, the reconciler and the rebuild
/// consume. Merge state itself is written only by [MergeCore].
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../sync_database.dart';

/// One entity a merge touched — what the domain projector consumes.
typedef AffectedEntity = ({String collection, String entityId});

/// Every entity the reduced substrate currently holds any trace of.
///
/// Both tables, because either alone is a partial answer: an entity may hold
/// fields with no tombstone, or a tombstone whose fields a compaction already
/// took away. The tombstoned ones matter as much as the live ones — a consumer
/// told only about live entities would leave a deleted row standing.
///
/// Device-wide rather than per-Workspace: reduced state is not partitioned by
/// Workspace, and both consumers (a chain rebuild, and the first-open projection
/// into a fresh domain store) want everything this device has ever reduced.
Future<Set<AffectedEntity>> reducedEntities(SyncDatabase db) async {
  final rows = await db.customSelect(
    'SELECT collection, entity_id FROM reduced_fields '
    'UNION SELECT collection, entity_id FROM row_tombstones',
    readsFrom: {db.reducedFields, db.rowTombstones},
  ).get();
  return {
    for (final row in rows)
      (
        collection: row.read<String>('collection'),
        entityId: row.read<String>('entity_id'),
      ),
  };
}

/// Typed reads over one collection's reduced state.
///
/// Visibility is decided here, at read time, against the tombstone table — see
/// [readAll]. [readEntityIncludingHidden] deliberately bypasses that rule: it
/// is what the domain projector uses to learn *which* row a tombstoned entity
/// occupied, since nothing in the reduced store is ever deleted.
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

  /// Every field ever reduced for [entityId], tombstone or not.
  ///
  /// The projector needs it to delete a tombstoned entity's domain row: a
  /// junction's identity is its pair, and once the entity is hidden there is no
  /// *live* field left to read the pair from. Nothing here is deleted by a
  /// tombstone, so the last asserted values are still on record.
  Future<Map<String, Object?>> readEntityIncludingHidden(
    String entityId,
  ) async {
    final rows = await _db.customSelect(
      'SELECT field, value_json FROM reduced_fields '
      'WHERE collection = ? AND entity_id = ? ORDER BY field',
      variables: [Variable<String>(collection), Variable<String>(entityId)],
      readsFrom: {_db.reducedFields},
    ).get();
    return {
      for (final row in rows)
        row.read<String>('field'): jsonDecode(row.read<String>('value_json')),
    };
  }

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
