/// On-device Nirvana import: converts parsed items and writes them to the
/// local Drift database via [TagDao], [TodoDao] and [CaptureDao].
///
/// **Every write goes through a DAO**, so every imported entity describes itself
/// on the op-log seam and therefore syncs (issue #610). Raw `into(...)`/`update`
/// statements here would commit rows that author nothing — an import a peer
/// could never see.
///
/// **A batch is the transaction and the capturing scope.**
/// [nirvanaImportTaskBatchSize] tasks commit their rows and author their ops
/// together, then the next batch opens a fresh scope; the project-tag prologue
/// is a scope of its own. The import is
/// *not* all-or-nothing across the file, deliberately: `GtdDatabase.capturing`
/// emits only after its transaction commits, and until each op is signed and
/// queued it lives only in memory, so one whole-file scope would leave a
/// multi-thousand-op import minutes of post-commit exposure in which a kill
/// loses every op while keeping every row — unrecoverably, since the
/// initial-upload marker would already be set. Per-batch scopes make an
/// interruption a *partial* import instead: item ids are deterministic
/// ([_deterministicTodoId], `todoTagIdFor`), so re-running the same export
/// converges on the same entities and completes what was left. Nothing surfaces
/// that state to the user yet (issue #642).
///
/// A consequence worth stating: the prologue commits project tags before any
/// task batch, so an interruption between them leaves Tags with no Tasks. That
/// is harmless — an empty Tag converges on peers like any other entity — and it
/// resolves on the re-run.
///
/// This module has no dependency on [ApiService] and requires no network
/// access, so it works for unauthenticated offline users.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import '../utils/uuid.dart';
import 'package:uuid/enums.dart' show Namespace;

import '../database/gtd_database.dart';
import '../models/todo.dart' show Intent;
import 'nirvana_item.dart';
import 'nirvana_parser.dart';

/// Tasks per capturing scope — and therefore per transaction, and per burst of
/// authored ops.
///
/// Public because it is an observable property of the import rather than an
/// internal tuning knob: it is the granularity at which an interrupted import
/// stops, so the interruption/resume tests assert against it instead of
/// hard-coding a second copy of the number.
const nirvanaImportTaskBatchSize = 200;

class ImportResult {
  const ImportResult({
    required this.importedCount,
    required this.skippedCount,
    required this.projectTagsCreated,
  });

  final int importedCount;
  final int skippedCount;
  final int projectTagsCreated;
}

/// Perform an on-device Nirvana import.
///
/// [bytes] is the raw file content. [filename] is used for format detection.
/// [format] overrides auto-detection when set to 'csv' or 'json'.
/// [userId] is the local user id (may be 'local' for unauthenticated users).
/// [db] is the local Drift database.
///
/// Throws [ParseError] on structurally invalid files.
Future<ImportResult> importNirvanaLocally({
  required Uint8List bytes,
  required String filename,
  required String format,
  required String userId,
  required GtdDatabase db,
}) async {
  // Decode bytes — try UTF-8 first, fall back to latin-1.
  String content;
  try {
    content = utf8.decode(bytes);
  } catch (_) {
    // Latin-1 fallback: treat each byte as a Unicode code point directly.
    content = String.fromCharCodes(bytes);
  }

  final effectiveFormat =
      format == 'auto' ? detectFormat(filename, content) : format;

  final (List<NirvanaItem> items, int skipped) = switch (effectiveFormat) {
    'json' => parseJson(content),
    _ => parseCsv(content),
  };

  if (items.isEmpty) {
    return ImportResult(
        importedCount: 0, skippedCount: skipped, projectTagsCreated: 0);
  }

  // Build project lookups from parsed items.
  // JSON format: nirvana item UUID → project name
  final idToProject = <String, String>{};
  // CSV format: project name → project name
  final nameToProject = <String, String>{};
  final allProjectNames = <String>{};

  for (final item in items) {
    if (item.type == 'project') {
      allProjectNames.add(item.name);
      idToProject[item.id] = item.name;
      nameToProject[item.name] = item.name;
    }
  }

  int importedCount = 0;
  int projectTagsCreated = 0;

  // In-memory caches for tag ids — avoids redundant SELECTs when the same tag
  // appears on many tasks. They live **outside** the scopes so they survive
  // across batch boundaries; the tags themselves were committed by an earlier
  // scope, so a later batch's junction rows always reference live rows.
  final projectTagIds = <String, String>{};
  final contextTagIds = <String, String>{};
  final personTagIds = <String, String>{};

  // --- Scope 1: project tags ---
  await db.capturing(() async {
    final existingTagRows = await (db.select(db.tags)
          ..where((t) => t.type.equals('project')))
        .get();
    final existingProjectNames = {for (final t in existingTagRows) t.name};

    // Map project name → tag id (pre-existing OR newly inserted).
    projectTagIds.addAll({
      for (final t in existingTagRows) t.name: t.id,
    });

    for (final projectName in allProjectNames) {
      if (!existingProjectNames.contains(projectName)) {
        final tagId = await db.tagDao.findOrCreateTag(
          projectName,
          'project',
          userId,
        );
        projectTagIds[projectName] = tagId;
        projectTagsCreated++;
      }
    }
  });

  // --- Scopes 2..N: one task batch each ---
  final tasks = items.where((i) => i.type == 'task').toList();

  for (var batchStart = 0;
      batchStart < tasks.length;
      batchStart += nirvanaImportTaskBatchSize) {
    final batch = tasks.skip(batchStart).take(nirvanaImportTaskBatchSize);

    await db.capturing(() async {
      for (final item in batch) {
        final todoId = _deterministicTodoId(item);
        final now = _importInstant();

        // Unclarified Nirvana rows (Inbox and any unrecognised state) become
        // Captures, not `clarified = false` todos (issue #184, ADR-0006). Their
        // tag links become Capture tag hints — mirroring Alembic 0026 step 3,
        // which copies `todo_tags` of migrated rows into `capture_tags`.
        if (!item.clarified) {
          await _importInboxCapture(
            db,
            item,
            userId: userId,
            now: now,
            idToProject: idToProject,
            nameToProject: nameToProject,
            projectTagIds: projectTagIds,
            contextTagIds: contextTagIds,
            personTagIds: personTagIds,
          );
          importedCount++;
          continue;
        }

        final dueDate = item.dueDate != null
            ? DateTime.tryParse(item.dueDate!)?.toUtc()
            : null;

        // Normalize at the import boundary: blank/whitespace → null so IS NOT
        // NULL checks don't produce phantom Waiting For items.
        final trimmedWaitingFor = item.waitingFor?.trim();
        final effectiveWaitingFor =
            (trimmedWaitingFor == null || trimmedWaitingFor.isEmpty)
                ? null
                : trimmedWaitingFor;

        // Compare existing vs incoming person-tag set so re-importing the
        // same export is a no-op on the todo row and junction table.
        final existingPersonNames =
            await _existingPersonTagNamesForTodo(db, todoId);
        final incomingPersonNames = effectiveWaitingFor != null
            ? {effectiveWaitingFor}
            : <String>{};
        final personTagsChanged = existingPersonNames != incomingPersonNames;

        // One read serves both decisions below: whether this is a first import
        // or a re-import, and which lastClarifiedAt to carry forward.
        final existingRow = await (db.select(db.todos)
              ..where((t) => t.id.equals(todoId)))
            .getSingleOrNull();

        // Preserve lastClarifiedAt when unchanged; stamp now on any mutation
        // (both additions and removals count as clarification events).
        final DateTime? computedLastClarifiedAt =
            personTagsChanged ? now : existingRow?.lastClarifiedAt;

        // The columns the export owns, written on both the insert and the
        // update path. Everything absent here is deliberately left to the
        // insert path's defaults or, on a re-import, to whatever the user has
        // since made it.
        final exportOwnedColumns = TodosCompanion(
          title: Value(item.name),
          notes: Value(item.notes),
          doneAt: item.doneAt != null
              ? Value(item.doneAt!.toUtc().toIso8601String())
              : const Value(null),
          clarified: Value(item.clarified),
          dueDate: Value(dueDate),
          timeEstimate: Value(item.timeEstimate),
          energyLevel: Value(item.energyLevel),
          lastClarifiedAt: Value(computedLastClarifiedAt),
          captureSource: const Value('nirvana_import'),
          userId: Value(userId),
          updatedAt: Value(now),
        );

        // [TodoDao.upsertOutcome] inserts or updates in place — never
        // INSERT OR REPLACE (issue #641) — and describes the write on the
        // op-log seam, which is what makes an imported Outcome reach the user's
        // other devices (issue #610). `createColumns` carries the two birth
        // facts a re-import must not restate.
        await db.todoDao.upsertOutcome(
          id: todoId,
          createColumns: exportOwnedColumns.copyWith(
            // The next/waiting bucket state, stated outright rather than leaned
            // on the column default — the maybe/trash buckets are applied
            // through TodoDao below.
            intent: Value(Intent.next.value),
            createdAt: Value(now),
          ),
          updateColumns: exportOwnedColumns,
        );

        if (personTagsChanged) {
          // Through the DAO so a *removal* leaves a tombstone rather than mere
          // row absence: row absence is what lets a replayed assignment
          // silently re-attach the delegate on a peer.
          final targetPersonTagIds = <String>{};
          if (effectiveWaitingFor != null) {
            final personTagId = personTagIds[effectiveWaitingFor] ??
                await db.tagDao.createPersonTag(effectiveWaitingFor, userId);
            personTagIds[effectiveWaitingFor] = personTagId;
            targetPersonTagIds.add(personTagId);
          }
          // [TodoDao.setPersonTagsForTodo], not [setPersonTagsAndStamp]: the
          // conditional `last_clarified_at` above is the import's own rule, and
          // the stamping variant would override it unconditionally.
          await db.todoDao
              .setPersonTagsForTodo(todoId, targetPersonTagIds, userId);
        }
        if (item.intent == 'maybe') {
          await db.todoDao.deferTaskToMaybe(todoId, now: now);
        } else if (item.intent == 'trash') {
          await db.todoDao.setIntent(todoId, Intent.trash, now: now);
        }

        // Resolve project tag for this task.
        String? projectTagId;
        if (item.parentId != null && idToProject.containsKey(item.parentId)) {
          projectTagId = projectTagIds[idToProject[item.parentId]!];
        } else if (item.parentName != null &&
            nameToProject.containsKey(item.parentName)) {
          projectTagId = projectTagIds[nameToProject[item.parentName]!];
        }

        if (projectTagId != null) {
          await db.tagDao.assignTag(todoId, projectTagId, userId);
        }

        // Upsert generic (context) tags.
        for (final tagName in item.tags) {
          final tagId = contextTagIds[tagName] ??
              await db.tagDao.findOrCreateTag(tagName, 'context', userId);
          contextTagIds[tagName] = tagId;
          await db.tagDao.assignTag(todoId, tagId, userId);
        }

        importedCount++;
      }
    });
  }

  return ImportResult(
    importedCount: importedCount,
    skippedCount: skipped,
    projectTagsCreated: projectTagsCreated,
  );
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Import one unclarified Nirvana row as an Inbox [Captures] row plus its tag
/// hints. Uses the same deterministic id as [_deterministicTodoId] so a
/// re-import lands on the exact row Alembic 0026 migrated (which preserved
/// `todos.id` as `captures.id`); a re-import updates that row in place to
/// stay idempotent.
Future<void> _importInboxCapture(
  GtdDatabase db,
  NirvanaItem item, {
  required String userId,
  required DateTime now,
  required Map<String, String> idToProject,
  required Map<String, String> nameToProject,
  required Map<String, String> projectTagIds,
  required Map<String, String> contextTagIds,
  required Map<String, String> personTagIds,
}) async {
  final captureId = _deterministicTodoId(item);

  // Preserve clarification across a re-import: if this Capture was already
  // imported and the user has since clarified it (clarified_at stamped, and
  // possibly capture_outcomes carved out), a fresh import must not reset it to
  // the Inbox. [CaptureDao.upsertCapture] updates in place rather than
  // INSERT OR REPLACE, and describes the write on the op-log seam so the
  // imported Capture reaches the user's other devices (issue #610). Neither
  // companion names `clarified_at`, so a brand-new Capture keeps the NULL
  // default (unclarified — in the Inbox) and a clarified one keeps its stamp.
  final exportOwnedColumns = CapturesCompanion(
    title: Value(item.name),
    notes: Value(item.notes),
    captureSource: const Value('nirvana_import'),
    userId: Value(userId),
    updatedAt: Value(now),
  );
  await db.captureDao.upsertCapture(
    id: captureId,
    createColumns: exportOwnedColumns.copyWith(createdAt: Value(now)),
    updateColumns: exportOwnedColumns,
  );

  // Project tag hint.
  String? projectTagId;
  if (item.parentId != null && idToProject.containsKey(item.parentId)) {
    projectTagId = projectTagIds[idToProject[item.parentId]!];
  } else if (item.parentName != null &&
      nameToProject.containsKey(item.parentName)) {
    projectTagId = projectTagIds[nameToProject[item.parentName]!];
  }
  if (projectTagId != null) {
    await db.captureDao.assignTagHint(captureId, projectTagId, userId);
  }

  // Context (generic) tag hints.
  for (final tagName in item.tags) {
    final tagId = contextTagIds[tagName] ??
        await db.tagDao.findOrCreateTag(tagName, 'context', userId);
    contextTagIds[tagName] = tagId;
    await db.captureDao.assignTagHint(captureId, tagId, userId);
  }

  // Person (Waiting For) tag hint.
  final trimmedWaitingFor = item.waitingFor?.trim();
  if (trimmedWaitingFor != null && trimmedWaitingFor.isNotEmpty) {
    final personTagId = personTagIds[trimmedWaitingFor] ??
        await db.tagDao.createPersonTag(trimmedWaitingFor, userId);
    personTagIds[trimmedWaitingFor] = personTagId;
    await db.captureDao.assignTagHint(captureId, personTagId, userId);
  }
}

/// A deterministic todo ID derived from the Nirvana item's id (UUID v5 under a
/// Jeeves namespace).  Makes re-importing the same export idempotent.
String _deterministicTodoId(NirvanaItem item) =>
    uuid.v5(Namespace.url.value, 'jeeves://nirvana_import/${item.id}');

/// The import's own clock, minted at the grain the op log carries: UTC, floored
/// to whole milliseconds.
///
/// A bare `DateTime.now()` is local-time and microsecond-grained, and
/// `encodeInstant` normalises both away on the wire. That was invisible while
/// the import authored nothing, but now that it does, a peer's projector would
/// write back `2026-07-31T17:01:13.709Z` where this store holds
/// `2026-07-31T22:31:13.709570 +05:30` — the same instant under two spellings,
/// which the text `ORDER BY created_at` in the GTD list reads as two different
/// orderings. Minting the value at the wire's grain makes the row a peer
/// projects byte-identical to the row the importer kept.
DateTime _importInstant() => DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch,
      isUtc: true,
    );

/// Returns the set of person-tag names currently linked to [todoId].
Future<Set<String>> _existingPersonTagNamesForTodo(
    GtdDatabase db, String todoId) async {
  final rows = await (db.select(db.todoTags).join([
    innerJoin(db.tags, db.tags.id.equalsExp(db.todoTags.tagId)),
  ])
        ..where(
            db.todoTags.todoId.equals(todoId) &
            db.tags.type.equals('person')))
      .get();
  return {for (final r in rows) r.readTable(db.tags).name};
}
