/// Field-grain merge of a [Change] into merge state — the sync host's reducer.
///
/// The rules (pinned for the op log by `spec/sync/reducer_v1_vectors.json`, which
/// the op-log adapter in `reducer.dart` still passes through unchanged):
///
/// - A field applies iff its HLC is strictly greater than the stored one. Equal
///   HLCs are an idempotent skip, which is also what makes a change coming back to
///   the device it left from a no-op.
/// - Deletion is a tombstone with its own HLC. Visibility is decided at read time —
///   a field newer than the tombstone is live and revives the entity, a field older
///   stays hidden. Nothing is deleted, so merge is order-independent in both
///   directions.
/// - LWW is the *default* rule, not the only one. A field may be governed by a
///   non-LWW [FieldMergeStrategy], and every such strategy must be a
///   join-semilattice so merge stays order-independent (ADR-0030).
/// - **Which** strategy arbitrates is read from the change and nothing else. A
///   `user_preferences` value names the `key` that selects its lattice or the
///   change is refused (`preference_value_without_key`, ADR-0033).
///
/// Nothing here knows where a change came from.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../collection_codecs.dart' show userPreferencesCollection;
import '../hlc.dart';
import '../merge_strategy.dart';
import '../sync_database.dart';
import '../sync_rejection.dart';
import 'change.dart';
import 'merge_state.dart';

class MergeCore {
  MergeCore(
    this._db, {
    this.strategies = const MergeStrategyRegistry(),
  });

  final SyncDatabase _db;

  /// Which [FieldMergeStrategy] governs each field.
  final MergeStrategyRegistry strategies;

  /// Refuse a change that cannot be merged deterministically — the one merge
  /// rule that is about the change rather than the stored state.
  void guard(Change change) {
    if (change.collection == userPreferencesCollection &&
        change.fields.containsKey(preferenceValueField) &&
        change.fields[preferenceKeyField]?.value is! String) {
      throw SyncRejection(
        SyncRejectionReason.preferenceValueWithoutKey,
        'user_preferences change ${change.entityId} carries a value with no '
        'string key to select its merge strategy',
      );
    }
  }

  /// Merge [change], or throw [SyncRejection]. Returns the entity it touched.
  ///
  /// Opens its own transaction, which nests as a savepoint inside a caller's.
  Future<Set<AffectedEntity>> apply(Change change) async {
    guard(change);
    await _db.transaction(() async {
      final tombstone = change.tombstone;
      if (tombstone != null) {
        await _applyTombstone(change, tombstone);
      }
      final preferenceKey = _preferenceKeyFor(change);
      for (final entry in change.fields.entries) {
        await _applyField(change, entry.key, entry.value, preferenceKey);
      }
    });
    return {(collection: change.collection, entityId: change.entityId)};
  }

  /// The `user_preferences` key this change carries, or null for every other
  /// collection and for a preference change that carries no key.
  String? _preferenceKeyFor(Change change) {
    if (change.collection != userPreferencesCollection) return null;
    final carried = change.fields[preferenceKeyField]?.value;
    return carried is String ? carried : null;
  }

  Future<void> _applyTombstone(Change change, Hlc clock) async {
    final existing = await (_db.select(_db.rowTombstones)
          ..where((row) =>
              row.collection.equals(change.collection) &
              row.entityId.equals(change.entityId)))
        .getSingleOrNull();
    if (existing != null &&
        !(clock > Hlc(existing.wallMs, existing.counter, existing.memberIdHex))) {
      return;
    }
    await _db.into(_db.rowTombstones).insertOnConflictUpdate(
          RowTombstonesCompanion.insert(
            collection: change.collection,
            entityId: change.entityId,
            wallMs: clock.wallMs,
            counter: clock.counter,
            memberIdHex: clock.memberIdHex,
          ),
        );
  }

  Future<void> _applyField(
    Change change,
    String field,
    ClockedValue write,
    String? preferenceKey,
  ) async {
    final clock = write.hlc;
    final storedClockRow = await (_db.select(_db.fieldClocks)
          ..where((row) =>
              row.collection.equals(change.collection) &
              row.entityId.equals(change.entityId) &
              row.field.equals(field)))
        .getSingleOrNull();
    final storedClock = storedClockRow == null
        ? null
        : Hlc(storedClockRow.wallMs, storedClockRow.counter,
            storedClockRow.memberIdHex);
    final strategy = strategies.resolve(
      collection: change.collection,
      field: field,
      preferenceKey: preferenceKey,
    );
    // The default path reads no stored value at all, so the extra SELECT is
    // paid only by the collections that actually register a non-LWW strategy.
    Object? storedValue;
    if (storedClock != null && !identical(strategy, lww)) {
      final storedValueRow = await (_db.select(_db.reducedFields)
            ..where((row) =>
                row.collection.equals(change.collection) &
                row.entityId.equals(change.entityId) &
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
            collection: change.collection,
            entityId: change.entityId,
            field: field,
            valueJson: jsonEncode(decision.value),
          ),
        );
    await _db.into(_db.fieldClocks).insertOnConflictUpdate(
          FieldClocksCompanion.insert(
            collection: change.collection,
            entityId: change.entityId,
            field: field,
            wallMs: winningClock.wallMs,
            counter: winningClock.counter,
            memberIdHex: winningClock.memberIdHex,
          ),
        );
  }
}
