/// The initial-upload transform: local domain rows in, planned ops out. Pure.
///
/// **Permanent sync-layer machinery.** Enrolment triggers it
/// (`sync_lifecycle`), and `initial_upload.dart` authors what it plans. One
/// implementation, deliberately: any second copy of the transform could only
/// ever agree with the uploader by luck.
///
/// **Which store the walk reads.** The domain read model. Reads are
/// `SELECT * FROM <table>`,
/// deliberately unfiltered (#582's rule): a row stranded at `user_id = 'local'`,
/// or under a previous account's id, must reach the plan rather than vanish
/// behind a predicate. The transform stamps the enrolled `user_id` at authoring,
/// so such rows land under the account that is actually syncing.
///
/// **A note on the word "legacy" in this file.** It names the *row-store* side of
/// the transform — the domain tables — as against the reduced-state side the diff
/// skip reads. It is not a claim that those tables are on their way out: they are
/// the domain read model, and they still are now that the read model lives in a
/// Drift-owned file of its own. The naming (and the report keys
/// derived from it) outlived the swap it was meant to be revisited at; renaming
/// it means renaming the report keys, which is a change of its own.
///
/// Three rules the shape encodes deliberately:
///
/// * **Entity ids are not minted here.** Junctions and `user_preferences` carry
///   their derivation (`todoTagIdFor` and siblings, `preferenceEntityId`);
///   everything else keeps the local row's own `id`, per `sync/ids.dart`'s
///   explicit rule that only those two families are deterministic. That is what
///   makes a re-run address the same entities rather than duplicating them.
/// * **Nulls are authored, absences are not.** A NULL optional column travels as
///   an explicit null field, so the upload preserves it rather than leaving a
///   stale value standing on a re-run. A NULL *required* column is different: an
///   op omitting it can never project, so the row is left out of the plan
///   entirely and named in [InitialUploadPlan.anomalies] — loudly excluded rather
///   than quietly uploaded into a shape no device can materialise.
/// * **ADR-0025 is applied here, not at the storage layer.** An Outcome holding
///   several Areas keeps one and converts the surplus to Labels, by a pure
///   function of the data so every re-run picks the same Area. The pick is
///   provisional: the user's own resolution happens in the next Weekly Review,
///   and [InitialUploadPlan.resolutions] is that pass's worklist.
library;

import 'package:uuid/uuid.dart';

import '../database/daos/capture_dao.dart'
    show captureOutcomeIdFor, captureTagIdFor;
import '../database/daos/focus_session_dao.dart'
    show focusSessionDispositionIdFor;
import '../database/daos/tag_dao.dart' show todoTagIdFor;
import 'collection_codecs.dart';
import 'ids.dart';

/// The production Tag-id minter: a random UUIDv4, per `sync/ids.dart`'s rule
/// that only junctions and `user_preferences` get deterministic ids. Injected
/// rather than called inline so a test can assert the transform is otherwise a
/// pure function of its inputs.
String initialUploadRandomTagId() => const Uuid().v4();

/// Reads every row of one domain table. `SELECT * FROM <table>`, deliberately
/// unfiltered — #582's rule: a row stranded at `user_id = 'local'` must reach
/// the plan and be visible in the report, not vanish behind a predicate.
typedef InitialUploadRowSource = Future<List<Map<String, Object?>>> Function(
    String table);

/// Reduced state for one collection, as `{entity id: {field: value}}`.
typedef ReducedCollectionReader
    = Future<Map<String, Map<String, Object?>>> Function(String collection);

/// Which of the User's two Workspaces an entity is authored into.
enum InitialUploadWorkspace {
  /// The default (GTD) Workspace: eleven of the twelve collections.
  gtd,

  /// The User-global preferences Workspace.
  preferences,
}

/// The `tags.type` values ADR-0025's conversion is about.
const String areaTagType = 'area';
const String labelTagType = 'label';

/// Authoring order: parents before the junctions that reference them.
///
/// The reducer and the projector are order-independent by design — a junction
/// whose Outcome has not arrived still reduces, and projects when it does — so
/// this is for a human reading the log and a progress bar that advances
/// sensibly, not for correctness.
const List<String> initialUploadCollectionOrder = [
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
  userPreferencesCollection,
];


// --- anomaly kinds ---------------------------------------------------------

/// A required column is NULL, so no op for this row could ever project. The row
/// is excluded from the plan and named.
const String nullRequiredColumn = 'null_required_column';

/// A value the column's kind refuses (a number in a text column, an
/// unparseable timestamp). The field is omitted; if it was required the row is
/// excluded, exactly as [nullRequiredColumn].
const String unencodableValue = 'unencodable_value';

/// A junction or preference row whose identity columns are not both present, so
/// no derivation exists for it.
const String missingIdentityColumns = 'missing_identity_columns';

/// Two or more legacy rows deriving to one entity id — pre-derivation junction
/// rows a device minted at random. They collapse onto the derivation, which is
/// the realignment the projector performs; the collapse is counted, not hidden.
const String collapsedDuplicateRow = 'collapsed_duplicate_row';

/// `capture()` refused the payload at the author's own call site (#573). The
/// store, the outbox and the author chain are untouched by design, so the
/// entity simply never lands — and shows up as `only_in_legacy`.
const String uploadRefused = 'upload_refused';

/// Reduced state holds no domain row for this entity: the projector held it back
/// because its required columns are not satisfied.
const String projectionHeldBack = 'projection_held_back';

/// One thing the upload could not do faithfully, named where a reviewer can go
/// look. Never thrown — #582's discipline: a throw would brick the report on the
/// one device the data lives on.
class InitialUploadAnomaly {
  const InitialUploadAnomaly({
    required this.table,
    required this.kind,
    this.rowId,
    this.column,
    this.raw,
  });

  /// The legacy table (equivalently, the collection) the row came from.
  final String table;

  final String kind;

  /// The legacy row's own `id`, or the derived entity id where the anomaly is
  /// about an entity rather than a row.
  final String? rowId;

  final String? column;
  final String? raw;

  Map<String, Object?> toJson() => {
        'table': table,
        'kind': kind,
        if (rowId != null) 'row_id': rowId,
        if (column != null) 'column': column,
        if (raw != null) 'raw': raw,
      };

  @override
  String toString() =>
      'InitialUploadAnomaly($table, $kind, $rowId, $column, $raw)';

  @override
  bool operator ==(Object other) =>
      other is InitialUploadAnomaly &&
      other.table == table &&
      other.kind == kind &&
      other.rowId == rowId &&
      other.column == column &&
      other.raw == raw;

  @override
  int get hashCode => Object.hash(table, kind, rowId, column, raw);
}

// --- planned entities ------------------------------------------------------

/// One entity the upload will assert, with the exact wire fields it will carry.
class PlannedEntity {
  const PlannedEntity({
    required this.workspace,
    required this.collection,
    required this.entityId,
    required this.fields,
    required this.legacyRowIds,
  });

  final InitialUploadWorkspace workspace;
  final String collection;
  final String entityId;

  /// The op's field map, already in wire form: instants canonicalised, TEXT
  /// passed through, `user_id` stamped, nulls explicit.
  final Map<String, Object?> fields;

  /// Which legacy row (or rows, where a duplicate pair collapsed) this entity
  /// stands for. More than one is what [collapsedDuplicateRow] counts.
  final List<String> legacyRowIds;
}

// --- ADR-0025 conversions -------------------------------------------------

/// A Tag as the report names it: enough to find it, no more.
class InitialUploadTagRef {
  const InitialUploadTagRef({required this.id, required this.name});

  final String id;
  final String name;

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  @override
  bool operator ==(Object other) =>
      other is InitialUploadTagRef && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'InitialUploadTagRef($id, $name)';
}

/// Where the Label an Area converted to came from.
///
/// The three are not cosmetic: `legacy` and `spine` are merges onto a Label that
/// already exists (so the user's own Label keeps its id and colour), `minted` is
/// the only case that adds a Tag entity to the plan.
const String labelOriginLegacyTag = 'legacy';
const String labelOriginSpineTag = 'spine';
const String labelOriginMinted = 'minted';

/// One surplus Area membership, and the Label membership it became.
class AreaMembershipConversion {
  const AreaMembershipConversion({
    required this.area,
    required this.label,
    required this.labelOrigin,
    required this.collapsedOntoExistingMembership,
  });

  final InitialUploadTagRef area;
  final InitialUploadTagRef label;
  final String labelOrigin;

  /// The Outcome already carried this Label, so the junction derivation
  /// collapses the conversion onto the membership it already had. Counted as a
  /// merge, not an anomaly.
  final bool collapsedOntoExistingMembership;

  Map<String, Object?> toJson() => {
        'area': area.toJson(),
        'label': label.toJson(),
        'label_origin': labelOrigin,
        'collapsed_onto_existing_membership': collapsedOntoExistingMembership,
      };
}

/// How one multi-Area Outcome was resolved — the Weekly Review pass's worklist
/// entry.
class AreaExclusivityResolution {
  const AreaExclusivityResolution({
    required this.outcomeId,
    required this.outcomeTitle,
    required this.keptArea,
    required this.converted,
  });

  final String outcomeId;

  /// The Outcome's title, so the list reads to a human. Null where the legacy
  /// row carries none.
  final String? outcomeTitle;

  final InitialUploadTagRef keptArea;
  final List<AreaMembershipConversion> converted;

  Map<String, Object?> toJson() => {
        'outcome_id': outcomeId,
        'outcome_title': outcomeTitle,
        'kept_area': keptArea.toJson(),
        'converted': [for (final one in converted) one.toJson()],
      };
}

// --- the plan --------------------------------------------------------------

class InitialUploadPlan {
  const InitialUploadPlan({
    required this.entities,
    required this.resolutions,
    required this.anomalies,
    required this.legacyRowCountByTable,
    required this.excludedRowIdsByTable,
    required this.endorsedEntityIdsByCollection,
  });

  /// Every entity to author, in [initialUploadCollectionOrder].
  final List<PlannedEntity> entities;

  /// Every multi-Area Outcome ADR-0025 resolved.
  final List<AreaExclusivityResolution> resolutions;

  final List<InitialUploadAnomaly> anomalies;

  /// How many rows each legacy table held, before the transform.
  final Map<String, int> legacyRowCountByTable;

  /// Legacy rows the plan could not carry, per table — the rows a reviewer has
  /// to look at by hand.
  final Map<String, List<String>> excludedRowIdsByTable;

  /// Entities the spine holds that the plan deliberately does **not** re-assert,
  /// and vouches for anyway.
  ///
  /// Exactly one thing lands here: a Label an earlier pass *minted* for a
  /// converted Area. It has no legacy row, so a later run resolves the conversion
  /// onto it by name rather than planning it again — and without this the
  /// verification would read the upload's own previous output as state the source
  /// store does not have. Endorsing it is narrower than excluding the collection
  /// and louder than ignoring the difference: the ids are in the report.
  final Map<String, Set<String>> endorsedEntityIdsByCollection;

  Iterable<PlannedEntity> entitiesFor(String collection) =>
      entities.where((entity) => entity.collection == collection);

  int get areaMembershipsConverted => resolutions.fold(
        0,
        (total, resolution) => total + resolution.converted.length,
      );

  /// **Labels**, not conversions: two Outcomes converting the same Area name
  /// share one minted Label, and a counter that said "2" would read as two Tags
  /// where there is one.
  int get labelsMinted => _distinctLabelIds(labelOriginMinted).length;

  /// Labels that already existed, whichever side they were found on — a legacy
  /// Tag row, or one an earlier pass minted and the spine still holds.
  int get labelsMerged =>
      _distinctLabelIds(labelOriginLegacyTag).length +
      _distinctLabelIds(labelOriginSpineTag).length;

  /// A Label id resolves to one origin for the whole run (the resolution is
  /// cached by name), so these sets cannot overlap.
  Set<String> _distinctLabelIds(String origin) => {
        for (final resolution in resolutions)
          for (final conversion in resolution.converted)
            if (conversion.labelOrigin == origin) conversion.label.id,
      };

  /// Rows no op could carry. Non-zero means the upload is not a faithful copy of
  /// the local store, and any verdict over it says so rather than reading green.
  int get excludedRowCount => excludedRowIdsByTable.values
      .fold(0, (total, ids) => total + ids.length);

  Map<String, Object?> toJson() => {
        'planned_entity_count': entities.length,
        'legacy_row_count_by_table': legacyRowCountByTable,
        'excluded_row_count': excludedRowCount,
        'excluded_row_ids_by_table': excludedRowIdsByTable,
        'endorsed_entity_ids_by_collection': {
          for (final entry in endorsedEntityIdsByCollection.entries)
            entry.key: entry.value.toList()..sort(),
        },
        'area_exclusivity': {
          'multi_area_outcome_count': resolutions.length,
          'memberships_converted': areaMembershipsConverted,
          'labels_minted': labelsMinted,
          'labels_merged': labelsMerged,
          'resolutions': [
            for (final resolution in resolutions) resolution.toJson(),
          ],
        },
        'anomalies': [for (final anomaly in anomalies) anomaly.toJson()],
      };
}

/// The new spine's Labels, keyed by casefolded name.
///
/// What makes a re-run stable: run 1 minted a Label for a converted Area, run 2
/// finds it here and merges onto it rather than minting a second one. Same-name
/// Labels resolve by `(casefolded name, id)` — the one total order the plan uses
/// everywhere — so two Labels called "Home" cannot make the pick depend on read
/// order.
Future<Map<String, InitialUploadTagRef>> readSpineLabelTags(
  ReducedCollectionReader readReducedCollection,
) async {
  final reduced = await readReducedCollection(tagsCollection);
  final labels = <InitialUploadTagRef>[];
  for (final entry in reduced.entries) {
    if (entry.value['type'] != labelTagType) continue;
    final name = entry.value['name'];
    if (name is! String) continue;
    labels.add(InitialUploadTagRef(id: entry.key, name: name));
  }
  labels.sort((a, b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.id.compareTo(b.id);
  });
  final byName = <String, InitialUploadTagRef>{};
  for (final label in labels) {
    byName.putIfAbsent(label.name.toLowerCase(), () => label);
  }
  return byName;
}

// --- the transform ---------------------------------------------------------

/// One legacy `tags` row, indexed by id.
class _LegacyTag {
  const _LegacyTag({
    required this.id,
    required this.name,
    required this.type,
    required this.color,
  });

  final String id;
  final String name;
  final String type;
  final String? color;

  /// The total order every deterministic pick in this file uses: casefolded name
  /// first so a report reads sensibly to a human, id second so the order is
  /// total even when two Tags share a name.
  static int compare(_LegacyTag a, _LegacyTag b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.id.compareTo(b.id);
  }

  InitialUploadTagRef get ref => InitialUploadTagRef(id: id, name: name);
}

/// Build the plan for one legacy store.
///
/// [spineLabelTagsByName] is the new spine's *reduced* Labels, keyed by
/// casefolded name — what makes a re-run stable: run 1 minted a Label for a
/// converted Area, run 2 finds it here and merges onto it instead of minting a
/// second one. Pass it empty and every conversion that needs a new Label mints.
///
/// [mintTagId] is injected so a test can assert the plan is a pure function of
/// its inputs; production hands in a random UUID minter, per `ids.dart`'s rule
/// that only junctions and preferences get deterministic ids.
Future<InitialUploadPlan> buildInitialUploadPlan({
  required InitialUploadRowSource readLegacyRows,
  required String userId,
  required String preferencesWorkspaceId,
  required String Function() mintTagId,
  Map<String, InitialUploadTagRef> spineLabelTagsByName = const {},
}) async {
  final rowsByTable = <String, List<Map<String, Object?>>>{};
  for (final table in initialUploadCollectionOrder) {
    rowsByTable[table] = await readLegacyRows(table);
  }

  final anomalies = <InitialUploadAnomaly>[];
  final excluded = <String, List<String>>{};
  void exclude(String table, String? rowId) {
    (excluded[table] ??= <String>[]).add(rowId ?? '(no id)');
  }

  final tagsById = <String, _LegacyTag>{};
  for (final row in rowsByTable[tagsCollection]!) {
    final id = row['id'];
    final name = row['name'];
    final type = row['type'];
    if (id is! String || name is! String || type is! String) continue;
    tagsById[id] = _LegacyTag(
      id: id,
      name: name,
      type: type,
      color: row['color'] is String ? row['color'] as String : null,
    );
  }

  final resolution = _resolveAreaExclusivity(
    todoTagRows: rowsByTable[todoTagsCollection]!,
    todoRows: rowsByTable[todosCollection]!,
    tagsById: tagsById,
    spineLabelTagsByName: spineLabelTagsByName,
    mintTagId: mintTagId,
    userId: userId,
  );

  final entities = <PlannedEntity>[];
  for (final collection in initialUploadCollectionOrder) {
    final codec = collectionCodecs[collection]!;
    final workspace = collection == userPreferencesCollection
        ? InitialUploadWorkspace.preferences
        : InitialUploadWorkspace.gtd;
    final rows = collection == todoTagsCollection
        ? resolution.todoTagRows
        : rowsByTable[collection]!;

    // Collapse pre-derivation duplicates onto the derived entity id in row
    // order, so which of two identical junction rows "wins" is not a function
    // of iteration luck.
    final byEntityId = <String, PlannedEntity>{};
    for (final row in rows) {
      final legacyRowId = row['id'] is String ? row['id'] as String : null;
      final entityId = initialUploadEntityIdFor(
        collection: collection,
        row: row,
        preferencesWorkspaceId: preferencesWorkspaceId,
      );
      if (entityId == null) {
        anomalies.add(InitialUploadAnomaly(
          table: collection,
          kind: missingIdentityColumns,
          rowId: legacyRowId,
          column: codec.identityColumns.join(','),
        ));
        exclude(collection, legacyRowId);
        continue;
      }
      final encoded = encodeLegacyRow(
        collection: collection,
        row: row,
        userId: userId,
      );
      anomalies.addAll([
        for (final anomaly in encoded.anomalies)
          InitialUploadAnomaly(
            table: collection,
            kind: anomaly.kind,
            rowId: legacyRowId ?? entityId,
            column: anomaly.column,
            raw: anomaly.raw,
          ),
      ]);
      if (encoded.unprojectable) {
        exclude(collection, legacyRowId ?? entityId);
        continue;
      }
      final existing = byEntityId[entityId];
      if (existing == null) {
        byEntityId[entityId] = PlannedEntity(
          workspace: workspace,
          collection: collection,
          entityId: entityId,
          fields: encoded.fields,
          legacyRowIds: [?legacyRowId],
        );
        continue;
      }
      anomalies.add(InitialUploadAnomaly(
        table: collection,
        kind: collapsedDuplicateRow,
        rowId: legacyRowId ?? entityId,
        raw: 'collapsed onto $entityId',
      ));
      byEntityId[entityId] = PlannedEntity(
        workspace: workspace,
        collection: collection,
        entityId: entityId,
        fields: existing.fields,
        legacyRowIds: [...existing.legacyRowIds, ?legacyRowId],
      );
    }
    entities.addAll(byEntityId.values);

    // The Labels ADR-0025 had to mint ride along with the collection they belong
    // to, so authoring order still has the Tag before any junction naming it.
    if (collection == tagsCollection) {
      for (final minted in resolution.mintedTags) {
        entities.add(minted);
      }
    }
  }

  return InitialUploadPlan(
    entities: entities,
    resolutions: resolution.resolutions,
    anomalies: anomalies,
    legacyRowCountByTable: {
      for (final table in initialUploadCollectionOrder)
        table: rowsByTable[table]!.length,
    },
    excludedRowIdsByTable: {
      for (final entry in excluded.entries) entry.key: entry.value..sort(),
    },
    endorsedEntityIdsByCollection: {
      if (resolution.endorsedSpineLabelIds.isNotEmpty)
        tagsCollection: resolution.endorsedSpineLabelIds,
    },
  );
}

/// The derived entity id for one legacy row, or null when its identity columns
/// are not all present.
///
/// The two deterministic families of `sync/ids.dart` and nothing else: every
/// other collection keeps the legacy row's own `id`, which is what makes the
/// upload address existing entities instead of minting new ones.
String? initialUploadEntityIdFor({
  required String collection,
  required Map<String, Object?> row,
  required String preferencesWorkspaceId,
}) {
  String? text(String column) =>
      row[column] is String ? row[column] as String : null;

  switch (collection) {
    case todoTagsCollection:
      final todoId = text('todo_id');
      final tagId = text('tag_id');
      return (todoId == null || tagId == null)
          ? null
          : todoTagIdFor(todoId, tagId);
    case captureOutcomesCollection:
      final captureId = text('capture_id');
      final outcomeId = text('outcome_id');
      return (captureId == null || outcomeId == null)
          ? null
          : captureOutcomeIdFor(captureId, outcomeId);
    case captureTagsCollection:
      final captureId = text('capture_id');
      final tagId = text('tag_id');
      return (captureId == null || tagId == null)
          ? null
          : captureTagIdFor(captureId, tagId);
    case focusSessionTasksCollection:
      final sessionId = text('focus_session_id');
      final taskId = text('task_id');
      return (sessionId == null || taskId == null)
          ? null
          : focusSessionTaskIdFor(sessionId, taskId);
    case focusSessionDispositionsCollection:
      final sessionId = text('focus_session_id');
      final taskId = text('task_id');
      return (sessionId == null || taskId == null)
          ? null
          : focusSessionDispositionIdFor(sessionId, taskId);
    case userPreferencesCollection:
      final key = text('key');
      return key == null ? null : preferenceEntityId(preferencesWorkspaceId, key);
    default:
      return text('id');
  }
}

/// One row's wire fields, plus what the encoding refused.
class EncodedLegacyRow {
  const EncodedLegacyRow({
    required this.fields,
    required this.anomalies,
    required this.unprojectable,
  });

  final Map<String, Object?> fields;
  final List<InitialUploadAnomaly> anomalies;

  /// A required column could not be carried, so no op for this row could ever
  /// satisfy the projector. The caller excludes the row rather than authoring an
  /// entity that can only ever be held back.
  final bool unprojectable;
}

/// Encode one legacy row to the exact fields its op will carry.
///
/// `user_id` is **stamped** with the enrolled account rather than copied: the
/// legacy value may be the `'local'` placeholder a never-synced row was stranded
/// under — or a previous account's, since `logout()`'s reassignment is
/// best-effort — and the whole point of the upload is that the spine holds the
/// enrolled User's own rows. The stamping is a declared exclusion in the report.
EncodedLegacyRow encodeLegacyRow({
  required String collection,
  required Map<String, Object?> row,
  required String userId,
}) {
  final codec = collectionCodecs[collection]!;
  final fields = <String, Object?>{};
  final anomalies = <InitialUploadAnomaly>[];
  var unprojectable = false;

  for (final entry in codec.columns.entries) {
    final column = entry.key;
    if (column == 'user_id') {
      fields[column] = userId;
      continue;
    }
    final raw = row[column];
    final required = codec.requiredColumns.contains(column);
    if (raw == null) {
      if (required) {
        anomalies.add(InitialUploadAnomaly(
          table: collection,
          kind: nullRequiredColumn,
          column: column,
        ));
        unprojectable = true;
        continue;
      }
      // An explicit null, not an absence: the upload asserts what the local
      // store holds, including the emptiness of a column.
      fields[column] = null;
      continue;
    }
    final encoded = _encodeValue(entry.value, raw);
    if (encoded.refused) {
      anomalies.add(InitialUploadAnomaly(
        table: collection,
        kind: unencodableValue,
        column: column,
        raw: rawAsText(raw),
      ));
      if (required) unprojectable = true;
      continue;
    }
    fields[column] = encoded.value;
  }

  return EncodedLegacyRow(
    fields: fields,
    anomalies: anomalies,
    unprojectable: unprojectable,
  );
}

({Object? value, bool refused}) _encodeValue(FieldKind kind, Object raw) {
  switch (kind) {
    case FieldKind.text:
      // Including the TEXT timestamp columns: opaque pass-through, byte for
      // byte, exactly as the codec promises.
      return raw is String
          ? (value: raw, refused: false)
          : (value: null, refused: true);
    case FieldKind.integer:
      if (raw is bool) return (value: null, refused: true);
      if (raw is int) return (value: raw, refused: false);
      if (raw is double && raw.isFinite && raw == raw.roundToDouble()) {
        return (value: raw.toInt(), refused: false);
      }
      return (value: null, refused: true);
    case FieldKind.boolean:
      if (raw is bool) return (value: raw, refused: false);
      if (raw is int && (raw == 0 || raw == 1)) {
        return (value: raw == 1, refused: false);
      }
      return (value: null, refused: true);
    case FieldKind.instant:
      // The shared timestamp grammar, so a microsecond-bearing legacy string
      // and the ms-truncated wire value are the same instant by construction.
      final instant = parseTimestampUtcMs(raw);
      return instant == null
          ? (value: null, refused: true)
          : (value: instant, refused: false);
  }
}

// --- ADR-0025 -------------------------------------------------------------

class _AreaResolutionResult {
  const _AreaResolutionResult({
    required this.todoTagRows,
    required this.mintedTags,
    required this.resolutions,
    required this.endorsedSpineLabelIds,
  });

  /// The `todo_tags` rows the plan will actually author: the kept Area
  /// membership, every non-Area membership, and one row per converted Label.
  final List<Map<String, Object?>> todoTagRows;

  final List<PlannedEntity> mintedTags;
  final List<AreaExclusivityResolution> resolutions;

  /// Labels an earlier run minted, found on the spine and merged onto rather than
  /// minted again. See [InitialUploadPlan.endorsedEntityIdsByCollection].
  final Set<String> endorsedSpineLabelIds;
}

_AreaResolutionResult _resolveAreaExclusivity({
  required List<Map<String, Object?>> todoTagRows,
  required List<Map<String, Object?>> todoRows,
  required Map<String, _LegacyTag> tagsById,
  required Map<String, InitialUploadTagRef> spineLabelTagsByName,
  required String Function() mintTagId,
  required String userId,
}) {
  final titleByTodoId = <String, String?>{
    for (final row in todoRows)
      if (row['id'] case final String id)
        id: row['title'] is String ? row['title'] as String : null,
  };

  // Same-name legacy Labels resolve by the one total order this file uses, so
  // two Labels called "Home" cannot make the conversion depend on row order.
  final legacyLabelsByName = <String, _LegacyTag>{};
  for (final tag in tagsById.values.toList()..sort(_LegacyTag.compare)) {
    if (tag.type != labelTagType) continue;
    legacyLabelsByName.putIfAbsent(tag.name.toLowerCase(), () => tag);
  }

  final rowsByTodoId = <String, List<Map<String, Object?>>>{};
  final untouched = <Map<String, Object?>>[];
  for (final row in todoTagRows) {
    final todoId = row['todo_id'];
    final tagId = row['tag_id'];
    if (todoId is! String || tagId is! String) {
      // No pair, no membership to reason about. It reaches the encoder, which
      // records the missing identity and excludes it.
      untouched.add(row);
      continue;
    }
    (rowsByTodoId[todoId] ??= <Map<String, Object?>>[]).add(row);
  }

  final kept = <Map<String, Object?>>[];
  final mintedTags = <PlannedEntity>[];
  final resolutions = <AreaExclusivityResolution>[];
  // Keyed by casefolded name so one run mints at most one Label per Area name,
  // however many Outcomes convert it.
  final resolvedLabels = <String, ({InitialUploadTagRef ref, String origin})>{};
  final endorsedSpineLabelIds = <String>{};

  for (final todoId in rowsByTodoId.keys) {
    final rows = rowsByTodoId[todoId]!;
    // **Distinct Areas, not Area rows.** Two pre-derivation junction rows for
    // the same (Outcome, Area) pair are one membership — they collapse onto the
    // derivation. Counting rows here would read a duplicate as a second Area and
    // convert the Outcome's only Area into a Label.
    final areas = <String, _LegacyTag>{};
    for (final row in rows) {
      final tag = tagsById[row['tag_id'] as String];
      if (tag != null && tag.type == areaTagType) {
        areas[tag.id] = tag;
      }
    }
    if (areas.length < 2) {
      kept.addAll(rows);
      continue;
    }

    final ordered = areas.values.toList()..sort(_LegacyTag.compare);
    final keptArea = ordered.first;
    final surplusAreas = ordered.skip(1).toList();
    final surplusAreaTagIds = {for (final area in surplusAreas) area.id};
    final heldTagIds = {
      for (final row in rows)
        if (!surplusAreaTagIds.contains(row['tag_id']))
          row['tag_id'] as String,
    };

    // Every membership except the surplus Areas survives verbatim — duplicate
    // rows included, so the plan-level collapse still records them.
    for (final row in rows) {
      if (surplusAreaTagIds.contains(row['tag_id'])) continue;
      kept.add(row);
    }

    final conversions = <AreaMembershipConversion>[];
    for (final area in surplusAreas) {
      final name = area.name.toLowerCase();
      var resolved = resolvedLabels[name];
      if (resolved == null) {
        final legacy = legacyLabelsByName[name];
        final spine = spineLabelTagsByName[name];
        if (legacy != null) {
          resolved = (ref: legacy.ref, origin: labelOriginLegacyTag);
        } else if (spine != null) {
          resolved = (ref: spine, origin: labelOriginSpineTag);
          // No legacy row backs it — an earlier run minted it — so the plan
          // vouches for it instead of asserting it.
          endorsedSpineLabelIds.add(spine.id);
        } else {
          final ref = InitialUploadTagRef(id: mintTagId(), name: area.name);
          resolved = (ref: ref, origin: labelOriginMinted);
          mintedTags.add(PlannedEntity(
            workspace: InitialUploadWorkspace.gtd,
            collection: tagsCollection,
            entityId: ref.id,
            // Stamped with the enrolled account, like every other planned
            // entity — a minted Tag has no legacy row to copy it from.
            fields: {
              'name': area.name,
              'type': labelTagType,
              'color': area.color,
              'user_id': userId,
            },
            legacyRowIds: const [],
          ));
        }
        resolvedLabels[name] = resolved;
      }
      final labelTagId = resolved.ref.id;
      final alreadyHeld = heldTagIds.contains(labelTagId);
      if (!alreadyHeld) {
        heldTagIds.add(labelTagId);
        kept.add({
          // No `id`: the derivation is the identity, and a legacy id here would
          // only be a value the projector immediately realigns away.
          'todo_id': todoId,
          'tag_id': labelTagId,
          // Stamped, like every other planned row's — a converted membership has
          // no legacy row of its own to copy an owner from.
          'user_id': userId,
        });
      }
      conversions.add(AreaMembershipConversion(
        area: area.ref,
        label: resolved.ref,
        labelOrigin: resolved.origin,
        collapsedOntoExistingMembership: alreadyHeld,
      ));
    }

    resolutions.add(AreaExclusivityResolution(
      outcomeId: todoId,
      outcomeTitle: titleByTodoId[todoId],
      keptArea: keptArea.ref,
      converted: conversions,
    ));
  }

  return _AreaResolutionResult(
    todoTagRows: [...kept, ...untouched],
    mintedTags: mintedTags,
    resolutions: resolutions,
    endorsedSpineLabelIds: endorsedSpineLabelIds,
  );
}
