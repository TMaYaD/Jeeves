/// Jeeves-native data export, and its silent re-import.
///
/// **The format is the op-log wire encoding.** An export is nothing more than
/// every GTD collection's rows, each field encoded exactly as
/// `sync/collection_codecs.dart` would put it on the wire (a Drift `dateTime`
/// through [encodeInstant]; TEXT / int / bool pass through). Reusing that one
/// canonical encoding is what lets [importJeevesExport] replay a row straight
/// back through the seam every DAO writes through — authoring an op per row —
/// without a second, drifting serialisation to keep in step.
///
/// **What travels: GTD data only.** The eleven collections below are every
/// syncable collection *except* `user_preferences`. An export carries Captures,
/// Outcomes, Actions, Tags (Labels, Areas, Contexts, Projects, Persons),
/// TimeLogs, FocusSessions and their junctions — never the user's preferences,
/// and never any credential (auth material lives in a separate secure store, not
/// the domain database at all).
///
/// **Import is silent.** A Jeeves export re-enters through the very same call
/// [importNirvanaLocally] serves, detected by its [jeevesExportEnvelopeKey]
/// envelope — which a Nirvana JSON export (a bare top-level list) can never
/// match. No surface names this format or the fact that the app can produce it.
///
/// **Every imported row authors an op, so an import reaches the user's other
/// devices** (the principle issue #610 established for the Nirvana import). Each
/// row is both written into the local Drift table *and* described through
/// `GtdDatabase.opCapture` inside a `capturing` scope; on an un-enrolled device
/// the seam simply drops the op, so the import still works fully offline.
///
/// **A batch is the transaction and the capturing scope**, exactly as in the
/// Nirvana import ([nirvanaImportTaskBatchSize]) and for the same reason: it
/// bounds how many signed-but-unqueued ops a process death can strand, and the
/// row ids are the export's own — deterministic — so re-running the same export
/// converges rather than duplicating.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../database/gtd_database.dart';
import '../sync/collection_codecs.dart';
import 'nirvana_local_import.dart' show ImportResult;
import 'nirvana_parser.dart' show ParseError;

/// The export format version, carried under [jeevesExportEnvelopeKey]. Bumped
/// only for a breaking change to the on-disk shape; [importJeevesExport] is
/// tolerant of missing fields, so an additive column change does not need one.
const int jeevesExportVersion = 1;

/// The top-level key whose presence *is* the format discriminator. A Nirvana
/// JSON export is a bare list, so it decodes to a `List`, never a `Map` carrying
/// this key — the two formats cannot be confused.
const String jeevesExportEnvelopeKey = 'jeeves_export';

/// The top-level key holding the per-collection row lists.
const String jeevesExportCollectionsKey = 'collections';

/// Rows per capturing scope — and therefore per transaction and per burst of
/// authored ops. The Jeeves-import analogue of [nirvanaImportTaskBatchSize].
const int jeevesImportBatchSize = 200;

/// The GTD collections an export carries, in foreign-key dependency order
/// (parents before children) so an import writes a referenced row before the
/// rows that point at it.
///
/// `user_preferences` is deliberately absent: an export is GTD data only.
/// Foreign-key enforcement is latent in the domain store today (issue #637), so
/// the order is not load-bearing for insert success — it is honest bookkeeping
/// that stays correct if enforcement is ever switched on.
const List<String> jeevesExportCollections = <String>[
  tagsCollection,
  todosCollection,
  capturesCollection,
  actionsCollection,
  focusSessionsCollection,
  timeLogsCollection,
  todoTagsCollection,
  captureOutcomesCollection,
  captureTagsCollection,
  focusSessionTasksCollection,
  focusSessionDispositionsCollection,
];

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

/// Build the export document for [userId] from the domain store [db].
///
/// Returns a JSON-encodable map. Every collection's rows are filtered to
/// [userId] — an export is *this* user's data — and every field is encoded to
/// its canonical wire form, so the document round-trips through
/// [importJeevesExport] with byte-identical fidelity.
Future<Map<String, Object?>> buildJeevesExport({
  required GtdDatabase db,
  required String userId,
}) async {
  final collections = <String, Object?>{};
  for (final name in jeevesExportCollections) {
    final codec = collectionCodecs[name]!;
    final rows = await db.customSelect(
      'SELECT * FROM "${codec.table}" WHERE "user_id" = ?',
      variables: [Variable<String>(userId)],
    ).get();
    collections[name] = [for (final row in rows) _encodeRow(codec, row)];
  }
  return {
    jeevesExportEnvelopeKey: jeevesExportVersion,
    jeevesExportCollectionsKey: collections,
  };
}

/// [buildJeevesExport] serialised to a pretty-printed JSON string.
String encodeJeevesExportJson(Map<String, Object?> document) =>
    const JsonEncoder.withIndent('  ').convert(document);

/// One stored row → its wire field map, `id` included.
///
/// [QueryRow.readNullable] decodes through the database's own `SqlTypes`, so a
/// `dateTime` column comes back as a [DateTime] regardless of whether the store
/// keeps it as text or as an integer — and [encodeInstant] then pins it to the
/// canonical three-fraction-digit `Z` spelling the log uses.
Map<String, Object?> _encodeRow(CollectionCodec codec, QueryRow row) {
  final out = <String, Object?>{'id': row.read<String>('id')};
  codec.columns.forEach((column, kind) {
    out[column] = switch (kind) {
      FieldKind.text => row.readNullable<String>(column),
      FieldKind.integer => row.readNullable<int>(column),
      FieldKind.boolean => row.readNullable<bool>(column),
      FieldKind.instant => encodeInstant(row.readNullable<DateTime>(column)),
    };
  });
  return out;
}

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------

/// Whether [content] is a Jeeves export rather than a Nirvana one.
///
/// True only for a JSON object carrying the [jeevesExportEnvelopeKey] envelope
/// and a [jeevesExportCollectionsKey] map. A Nirvana JSON export decodes to a
/// list; a CSV export is not JSON at all — both are false here.
bool isJeevesExport(String content) {
  final Object? decoded;
  try {
    decoded = jsonDecode(content);
  } catch (_) {
    return false;
  }
  return decoded is Map &&
      decoded[jeevesExportEnvelopeKey] != null &&
      decoded[jeevesExportCollectionsKey] is Map;
}

// ---------------------------------------------------------------------------
// Import
// ---------------------------------------------------------------------------

/// A single row queued for import: which collection it belongs to, its entity
/// id, and its raw (already wire-encoded) field map from the export.
class _PendingRow {
  const _PendingRow(this.codec, this.id, this.raw);
  final CollectionCodec codec;
  final String id;
  final Map<Object?, Object?> raw;
}

/// Import a Jeeves export [content] into the domain store [db] for [userId].
///
/// Every row's `user_id` is remapped to [userId] — the importing account owns
/// what it imports, exactly as the Nirvana import stamps its own `userId`. Rows
/// are written in [jeevesExportCollections] order, batched into `capturing`
/// scopes so each batch commits and authors together.
///
/// The returned [ImportResult] reuses the Nirvana shape so no calling surface
/// changes: [ImportResult.importedCount] counts the Outcomes imported (the
/// "tasks" the existing copy speaks of); the other two fields stay zero.
///
/// Throws [ParseError] if [content] is not a structurally valid export.
Future<ImportResult> importJeevesExport({
  required String content,
  required String userId,
  required GtdDatabase db,
}) async {
  final Object? decoded;
  try {
    decoded = jsonDecode(content);
  } catch (e) {
    throw ParseError('Invalid JSON: $e');
  }
  if (decoded is! Map || decoded[jeevesExportCollectionsKey] is! Map) {
    throw const ParseError('Not a Jeeves export');
  }
  final collections = decoded[jeevesExportCollectionsKey] as Map;

  // Flatten into one ordered work list so a fixed-size batch can span a
  // collection boundary the way the Nirvana import's task batches do — the
  // parents-first order is preserved because collections are appended in it.
  final work = <_PendingRow>[];
  for (final name in jeevesExportCollections) {
    final codec = collectionCodecs[name]!;
    final rows = collections[name];
    if (rows is! List) continue;
    for (final entry in rows) {
      if (entry is! Map) continue;
      final id = entry['id'];
      if (id is! String) continue;
      work.add(_PendingRow(codec, id, entry));
    }
  }

  var importedOutcomeCount = 0;
  for (var start = 0; start < work.length; start += jeevesImportBatchSize) {
    final batch = work.skip(start).take(jeevesImportBatchSize);
    await db.capturing(() async {
      for (final row in batch) {
        final fields = _importFields(row.codec, row.raw, userId);
        // Author the op only if the local row was actually persisted. When
        // [_writeRow] cannot locate the row (an unresolvable junction key),
        // it skips both the write and the count, so the op log never asserts a
        // row this device did not keep and importedCount never overstates.
        if (!await _writeRow(db, row.codec, row.id, fields)) continue;
        // The op that makes this row reach the user's other devices. On an
        // un-enrolled device the seam drops it; on an enrolled one it syncs.
        db.opCapture.write(
          collection: row.codec.collection,
          entityId: row.id,
          fields: fields,
        );
        if (row.codec.collection == todosCollection) importedOutcomeCount++;
      }
    });
  }

  _notifyAllViews(db);
  return ImportResult(
    importedCount: importedOutcomeCount,
    skippedCount: 0,
    projectTagsCreated: 0,
  );
}

/// The wire field map to assert for one imported row: exactly the codec's
/// columns, taking each value verbatim from the export (it is already
/// wire-encoded), but overriding `user_id` with the importing account's.
Map<String, Object?> _importFields(
  CollectionCodec codec,
  Map<Object?, Object?> raw,
  String userId,
) {
  final fields = <String, Object?>{};
  codec.columns.forEach((column, _) {
    if (column == 'user_id') {
      fields[column] = userId;
    } else if (raw.containsKey(column)) {
      fields[column] = raw[column];
    }
  });
  return fields;
}

/// Insert [id] into the codec's table from [fields], or update the row it
/// already occupies. Mirrors `DomainProjector`'s codec-driven upsert: an owned
/// entity is located by `id`, a junction by its domain pair, so a re-import
/// lands on the same row rather than duplicating it.
///
/// Returns whether the row is now persisted: `false` only when [_identity]
/// cannot locate it (an unresolvable junction key), so the caller can skip
/// authoring an op for a row this device never kept.
Future<bool> _writeRow(
  GtdDatabase db,
  CollectionCodec codec,
  String id,
  Map<String, Object?> fields,
) async {
  final values = <String, Variable<Object>>{'id': Variable<String>(id)};
  codec.columns.forEach((column, kind) {
    if (!fields.containsKey(column)) return;
    values[column] = _bind(kind, fields[column]);
  });

  final identity = _identity(codec, id, fields);
  if (identity == null) return false;

  final existing = await db
      .customSelect(
        'SELECT 1 FROM "${codec.table}" WHERE ${identity.sql} LIMIT 1',
        variables: identity.variables,
      )
      .getSingleOrNull();

  if (existing == null) {
    final columns = values.keys.map((c) => '"$c"').join(', ');
    final placeholders = List.filled(values.length, '?').join(', ');
    await db.customInsert(
      'INSERT INTO "${codec.table}" ($columns) VALUES ($placeholders)',
      variables: values.values.toList(),
    );
    return true;
  }

  final assignments = <String>[];
  final bound = <Variable<Object>>[];
  values.forEach((column, variable) {
    if (codec.identityColumns.contains(column)) return;
    assignments.add('"$column" = ?');
    bound.add(variable);
  });
  // The row already exists (identity matched); nothing to update but it is
  // persisted, so the caller still authors its op.
  if (assignments.isEmpty) return true;
  await db.customUpdate(
    'UPDATE "${codec.table}" SET ${assignments.join(', ')} '
    'WHERE ${identity.sql}',
    variables: [...bound, ...identity.variables],
  );
  return true;
}

/// How to locate the row this entity occupies: by `id` for an owned entity, by
/// the domain-key columns for a junction (all of which are text and present in
/// [fields], `user_id` already remapped).
({String sql, List<Variable<Object>> variables})? _identity(
  CollectionCodec codec,
  String id,
  Map<String, Object?> fields,
) {
  if (codec.identifiedById) {
    return (sql: '"id" = ?', variables: [Variable<String>(id)]);
  }
  final clauses = <String>[];
  final variables = <Variable<Object>>[];
  for (final column in codec.identityColumns) {
    final value = fields[column];
    if (value is! String) return null;
    clauses.add('"$column" = ?');
    variables.add(Variable<String>(value));
  }
  if (clauses.isEmpty) return null;
  return (sql: clauses.join(' AND '), variables: variables);
}

/// Bind a wire value for its column kind — the inverse of [_encodeRow], and the
/// same mapping `DomainProjector` binds with.
Variable<Object> _bind(FieldKind kind, Object? value) => switch (kind) {
      FieldKind.text => Variable<String>(value is String ? value : null),
      FieldKind.integer => Variable<int>(value is num ? value.toInt() : null),
      FieldKind.boolean => Variable<int>(
          value == null ? null : (value == true || value == 1 ? 1 : 0),
        ),
      FieldKind.instant => Variable<DateTime>(decodeInstant(value)),
    };

/// Refresh every domain surface the import may have written. The row writes go
/// through `customInsert` / `customUpdate` without an `updates:` set (as the
/// projector's do), so — exactly like a projected row — nothing refreshes until
/// these ADR-0010 notifies fire.
void _notifyAllViews(GtdDatabase db) {
  db.notifyTagsViewWrite();
  db.notifyTodosViewWrite(includeTodoTags: true);
  db.notifyCapturesViewWrite();
  db.notifyActionsViewWrite();
  db.notifyTimeLogsViewWrite();
  db.notifyFocusSessionsViewWrite();
}
