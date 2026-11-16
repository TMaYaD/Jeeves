/// Walks the domain rows a device already holds into merge state, once.
///
/// **Why.** Merge state is written only by changes the host merges. A row that
/// existed before the host did has none, so `SyncHost.snapshot()` would omit it —
/// and a plugin's first upload is built from that snapshot. This pass makes the
/// snapshot hold the whole local dataset before any plugin can attach.
///
/// **What it does not do.** It reads the domain store and inserts into merge
/// state; it never updates or deletes anything, writes no tombstone, authors no
/// change, appends nothing to the change sequence and projects nothing back.
///
/// **The floor clock.** Every seeded field carries `Hlc(0, 0, <device node id>)`,
/// the lowest clock the device can state. A pre-existing value was written at an
/// unknown time, so the seed claims nothing: any real write, local or remote,
/// from any time, beats it. (That is exact for last-write-wins fields. A
/// preference governed by a join that ignores clocks, such as a `*snoozed_until`
/// instant, keeps whichever value merge state already holds, so there the order
/// in which a seed and a real write arrive can matter.) That is also why the walk needs no lock against
/// concurrent domain writes and cannot revive a deleted entity, and why a walk
/// interrupted and resumed leaves exactly the state an uninterrupted one would.
///
/// **Per field, not per entity.** Only fields merge state holds neither a value
/// nor a clock for are inserted, so an old row edited after the upgrade keeps that
/// field's real clock and still gains its remaining fields.
///
/// **Run once.** A one-row marker in the sync store is written after the last
/// collection. Without it the pass is still idempotent: a second walk finds
/// nothing to insert.
library;

import 'dart:convert';

import '../../database/gtd_database.dart';
import '../collection_codecs.dart';
import '../hlc.dart';
import '../ids.dart' show userPreferencesWorkspaceId;
import '../initial_upload_plan.dart'
    show encodeLegacyRow, initialUploadEntityIdFor;
import '../sync_database.dart';
import 'change.dart';
import 'merge_core.dart';

/// How many entities one sync-store transaction seeds, so a concurrent drain
/// waits for at most one chunk.
const int seedingChunkEntityCount = 300;

/// What a completed walk did, kept in the marker row.
class MergeStateSeedingReport {
  const MergeStateSeedingReport({
    required this.insertedFieldCount,
    required this.excludedRowIdsByCollection,
  });

  /// Fields newly inserted into merge state by this walk.
  final int insertedFieldCount;

  /// Domain rows the walk could not carry, per collection.
  final Map<String, List<String>> excludedRowIdsByCollection;

  Map<String, Object?> toJson() => {
        'inserted_field_count': insertedFieldCount,
        'excluded_row_ids_by_collection': excludedRowIdsByCollection,
      };
}

class MergeStateSeeder {
  MergeStateSeeder({
    required SyncDatabase sync,
    required GtdDatabase domain,
    required MergeCore core,
    required String deviceNodeId,
    int Function()? nowMs,
    this.chunkEntityCount = seedingChunkEntityCount,
  })  : _sync = sync,
        _domain = domain,
        _core = core,
        floorClock = Hlc(0, 0, deviceNodeId),
        _nowMs = nowMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  final SyncDatabase _sync;
  final GtdDatabase _domain;
  final MergeCore _core;
  final int Function() _nowMs;
  final int chunkEntityCount;

  /// The clock every seeded field carries.
  final Hlc floorClock;

  Future<bool> isComplete() async =>
      (await _sync.customSelect('SELECT 1 FROM merge_state_seeding LIMIT 1').get())
          .isNotEmpty;

  /// Walk unless the marker says a walk already finished. Returns the report of
  /// the walk it ran, or null when the marker was already set.
  Future<MergeStateSeedingReport?> runIfIncomplete() async {
    if (await isComplete()) return null;
    return run();
  }

  /// Walk every collection with a sync codec, then write the marker.
  Future<MergeStateSeedingReport> run() async {
    var insertedFieldCount = 0;
    final excluded = <String, List<String>>{};
    for (final collection in collectionCodecs.keys) {
      final planned = <Change>[];
      await _plan(collection, planned, excluded);
      for (var start = 0; start < planned.length; start += chunkEntityCount) {
        final end = start + chunkEntityCount > planned.length
            ? planned.length
            : start + chunkEntityCount;
        insertedFieldCount += await _sync.transaction(() async {
          var inserted = 0;
          for (final change in planned.sublist(start, end)) {
            inserted += await _core.insertMissingFields(change);
          }
          return inserted;
        });
      }
    }
    final report = MergeStateSeedingReport(
      insertedFieldCount: insertedFieldCount,
      excludedRowIdsByCollection: {
        for (final entry in excluded.entries) entry.key: entry.value..sort(),
      },
    );
    await _sync.customStatement(
      'INSERT OR REPLACE INTO merge_state_seeding '
      '(id, completed_at_utc_ms, report_json) VALUES (1, ?, ?)',
      [_nowMs(), jsonEncode(report.toJson())],
    );
    return report;
  }

  /// Read [collection]'s rows and turn each into the change a DAO write would
  /// have captured, with every field at the floor clock.
  ///
  /// `SELECT *`, deliberately unfiltered (the rule the enrolment upload follows):
  /// a row stranded under `user_id = 'local'` is still a row the user sees.
  /// Rows are mirrored as they are — their own `user_id`, no Area-to-Label
  /// conversion.
  Future<void> _plan(
    String collection,
    List<Change> planned,
    Map<String, List<String>> excluded,
  ) async {
    final codec = collectionCodecs[collection]!;
    final rows = await _domain.customSelect('SELECT * FROM ${codec.table}').get();
    for (final queryRow in rows) {
      final row = Map<String, Object?>.of(queryRow.data);
      final rowLabel = row['id'] is String ? row['id']! as String : '(no id)';
      final ownUserId = row['user_id'];
      if (codec.columns.containsKey('user_id') && ownUserId is! String) {
        (excluded[collection] ??= <String>[]).add(rowLabel);
        continue;
      }
      final userId = ownUserId is String ? ownUserId : '';
      final entityId = initialUploadEntityIdFor(
        collection: collection,
        row: row,
        // Each preference row derives its id from its own user, the way the
        // DAO that wrote it did.
        preferencesWorkspaceId: collection == userPreferencesCollection
            ? userPreferencesWorkspaceId(userId)
            : '',
      );
      if (entityId == null) {
        (excluded[collection] ??= <String>[]).add(rowLabel);
        continue;
      }
      final encoded =
          encodeLegacyRow(collection: collection, row: row, userId: userId);
      if (encoded.unprojectable) {
        (excluded[collection] ??= <String>[]).add(rowLabel);
        continue;
      }
      planned.add(Change(
        collection: collection,
        entityId: entityId,
        fields: {
          for (final field in encoded.fields.entries)
            field.key: ClockedValue(field.value, floorClock),
        },
      ));
    }
  }
}
