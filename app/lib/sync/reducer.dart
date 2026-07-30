/// Field-grain last-write-wins reduction over the op log.
///
/// The rules, all pinned by `spec/sync/reducer_v1_vectors.json`:
///
/// - A field applies iff its HLC is strictly greater than the stored one. Equal
///   HLCs are an idempotent skip, which is also what makes a pulled echo of the
///   device's own op a no-op.
/// - A field's HLC is its own when it carries one, else the op-level HLC. The
///   same rule applies one level up to a tombstone, whose `tombstone_hlc` a
///   compaction op carries so a compacted deletion is re-asserted at the clock it
///   was made at rather than the compactor's.
/// - Deletion is a tombstone op with its own HLC. Visibility is decided at read
///   time — a field newer than the tombstone is live and revives the entity, a
///   field older stays hidden. Nothing is deleted, so reduction is
///   order-independent in both directions.
/// - **The guards are scoped to the op-level HLC only** (review F15, as ruled
///   for this slice). Per-field HLCs are exempt: a compaction op (#555)
///   legitimately re-asserts *other authors'* older clocks per field, and
///   checking those would make compaction impossible. The exemption is *from
///   the guards, not from LWW* — a re-asserted older clock still loses.
/// - LWW is the *default* rule, not the only one. A field may be governed by a
///   non-LWW [FieldMergeStrategy] — ADR-0011's Conflict Strategy registry rides
///   here — and every such strategy must be a join-semilattice so reduction
///   stays order-independent (ADR-0030).
/// - **Which** strategy arbitrates is read from the op and nothing else. A
///   `user_preferences` write names the `key` that selects its lattice or it is
///   refused (`preference_value_without_key`, ADR-0033), so reduction consults no
///   stored state to pick a strategy and selection is order-independent
///   structurally rather than by policy.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import 'collection_codecs.dart' show userPreferencesCollection;
import 'envelope.dart';
import 'hlc.dart';
import 'merge_strategy.dart';
import 'op_payload.dart';
import 'sync_database.dart';

/// One entity the reducer touched — what the domain projector consumes.
typedef AffectedEntity = ({String collection, String entityId});

/// How far ahead of local time an op-level `wall_ms` may be before the op is
/// quarantined. Without a bound, any member could pin a field against every
/// future edit by writing a clock in 2099 (review F15).
const int defaultFutureSkewBoundMs = 5 * 60 * 1000;

class Reducer {
  Reducer(
    this._db, {
    required int Function() nowMs,
    this.futureSkewBoundMs = defaultFutureSkewBoundMs,
    this.strategies = const MergeStrategyRegistry(),
  }) : _nowMs = nowMs;

  final SyncDatabase _db;
  final int Function() _nowMs;
  final int futureSkewBoundMs;

  /// Which [FieldMergeStrategy] governs each field. The default is ADR-0011's
  /// registry adapter; every collection but `user_preferences` resolves to LWW.
  final MergeStrategyRegistry strategies;

  /// Apply [payload], or throw [SyncRejection] so the caller quarantines it.
  ///
  /// Returns the entities this op touched. `SyncClient` accumulates them over a
  /// pull batch and hands them to the domain projector once the batch is
  /// applied — projection hangs off the tail of the receive order, after apply.
  Future<Set<AffectedEntity>> apply(
    OpPayload payload, {
    required String authorMemberIdHex,
  }) async {
    guardPayload(payload, authorMemberIdHex: authorMemberIdHex);
    await _db.transaction(() async {
      if (payload.tombstone) {
        await _applyTombstone(payload);
      }
      final preferenceKey = _preferenceKeyFor(payload);
      for (final entry in payload.fields.entries) {
        await _applyField(payload, entry.key, entry.value, preferenceKey);
      }
    });
    return {(collection: payload.collection, entityId: payload.entityId)};
  }

  /// The `user_preferences` key this op carries, or null for every other
  /// collection and for a preference op that carries no key (a tombstone, or a
  /// write touching only plain-LWW fields — neither has a value to arbitrate).
  ///
  /// A pure read of the op: nothing stored is consulted, so which strategy
  /// arbitrates a field cannot depend on what this device has already applied.
  /// The one shape this could not resolve — a `value` with no string key — is
  /// refused by [guardPayload] before reduction starts.
  String? _preferenceKeyFor(OpPayload payload) {
    if (payload.collection != userPreferencesCollection) return null;
    final carried = payload.fields[preferenceKeyField]?.value;
    return carried is String ? carried : null;
  }

  /// The refusals that read no reduced state — the op, its header author and
  /// local wall time are the whole input, so the verdict does not depend on what
  /// this device has already applied.
  ///
  /// Public because `SyncClient.capture` runs it *before* authoring, on the same
  /// [Reducer] instance the receive path uses: one function rather than a second
  /// author-side copy free to disagree with it, and a payload every peer would
  /// refuse is never signed into the outbox (the divergence class #573 closes).
  /// Stateful verdicts — chain position, grants, the epoch floor — stay where
  /// they are and are deliberately not here.
  void guardPayload(
    OpPayload payload, {
    required String authorMemberIdHex,
  }) {
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
    if (payload.collection == userPreferencesCollection &&
        payload.fields.containsKey(preferenceValueField) &&
        payload.fields[preferenceKeyField]?.value is! String) {
      throw SyncRejection(
        SyncRejectionReason.preferenceValueWithoutKey,
        'user_preferences op ${payload.entityId} carries a value with no '
        'string key to select its merge strategy',
      );
    }
  }

  /// A tombstone applies at [OpPayload.effectiveTombstoneHlc] — its own clock when
  /// it carries one, else the op's.
  ///
  /// Only a compaction op carries one, and for the same reason its fields do: a
  /// compacted tombstone re-stamped with the compactor's newer clock would bury a
  /// resurrection the original tombstone could never have buried. The fallback is
  /// what keeps every content op's behaviour exactly what it was.
  Future<void> _applyTombstone(OpPayload payload) async {
    final clock = payload.effectiveTombstoneHlc;
    final existing = await (_db.select(_db.rowTombstones)
          ..where((row) =>
              row.collection.equals(payload.collection) &
              row.entityId.equals(payload.entityId)))
        .getSingleOrNull();
    if (existing != null &&
        !(clock > Hlc(existing.wallMs, existing.counter, existing.memberIdHex))) {
      return;
    }
    await _db.into(_db.rowTombstones).insertOnConflictUpdate(
          RowTombstonesCompanion.insert(
            collection: payload.collection,
            entityId: payload.entityId,
            wallMs: clock.wallMs,
            counter: clock.counter,
            memberIdHex: clock.memberIdHex,
          ),
        );
  }

  Future<void> _applyField(
    OpPayload payload,
    String field,
    FieldWrite write,
    String? preferenceKey,
  ) async {
    final clock = write.hlc ?? payload.hlc;
    final storedClockRow = await (_db.select(_db.fieldClocks)
          ..where((row) =>
              row.collection.equals(payload.collection) &
              row.entityId.equals(payload.entityId) &
              row.field.equals(field)))
        .getSingleOrNull();
    final storedClock = storedClockRow == null
        ? null
        : Hlc(storedClockRow.wallMs, storedClockRow.counter,
            storedClockRow.memberIdHex);
    final strategy = strategies.resolve(
      collection: payload.collection,
      field: field,
      preferenceKey: preferenceKey,
    );
    // The default path reads no stored value at all, so the extra SELECT is
    // paid only by the collections that actually register a non-LWW strategy.
    Object? storedValue;
    if (storedClock != null && !identical(strategy, lww)) {
      final storedValueRow = await (_db.select(_db.reducedFields)
            ..where((row) =>
                row.collection.equals(payload.collection) &
                row.entityId.equals(payload.entityId) &
                row.field.equals(field)))
          .getSingleOrNull();
      if (storedValueRow != null) {
        storedValue = jsonDecode(storedValueRow.valueJson);
      }
    }
    final decision = strategy.merge(
      incomingValue: write.value,
      incomingClock: clock,
      storedValue: storedValue,
      storedClock: storedClock,
    );
    if (!decision.apply) return;
    final winningClock = decision.clock!;
    await _db.into(_db.reducedFields).insertOnConflictUpdate(
          ReducedFieldsCompanion.insert(
            collection: payload.collection,
            entityId: payload.entityId,
            field: field,
            valueJson: jsonEncode(decision.value),
          ),
        );
    await _db.into(_db.fieldClocks).insertOnConflictUpdate(
          FieldClocksCompanion.insert(
            collection: payload.collection,
            entityId: payload.entityId,
            field: field,
            wallMs: winningClock.wallMs,
            counter: winningClock.counter,
            memberIdHex: winningClock.memberIdHex,
          ),
        );
  }
}

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
