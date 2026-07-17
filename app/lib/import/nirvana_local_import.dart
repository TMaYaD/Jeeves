/// On-device Nirvana import: converts parsed items and writes them to the
/// local Drift database via [TagDao] and [InboxDao]/[TodoDao].
///
/// The import is fully transactional at the local-DB level — a mid-file
/// failure leaves the database unchanged.  Writes are batched for large
/// exports to avoid holding an excessively large transaction frame in memory.
///
/// This module has no dependency on [ApiService] and requires no network
/// access, so it works for unauthenticated offline users.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart' show uuid;
import 'package:uuid/enums.dart' show Namespace;

import '../database/daos/tag_dao.dart' show todoTagIdFor;
import '../database/gtd_database.dart';
import '../models/todo.dart' show Intent;
import 'nirvana_item.dart';
import 'nirvana_parser.dart';

const _batchSize = 200;

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

  // All writes inside a single transaction for atomicity.
  int importedCount = 0;
  int projectTagsCreated = 0;

  await db.transaction(() async {
    // --- Upsert project tags ---
    final existingTagRows = await (db.select(db.tags)
          ..where((t) => t.type.equals('project')))
        .get();
    final existingProjectNames = {for (final t in existingTagRows) t.name};

    // Map project name → tag id (pre-existing OR newly inserted).
    final projectTagIds = <String, String>{
      for (final t in existingTagRows) t.name: t.id,
    };

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

    // --- Insert tasks in batches ---
    final tasks = items.where((i) => i.type == 'task').toList();

    // In-memory caches for tag ids — avoids redundant SELECTs when
    // the same tag appears on many tasks.
    final contextTagIds = <String, String>{};
    final personTagIds = <String, String>{};

    for (var batchStart = 0;
        batchStart < tasks.length;
        batchStart += _batchSize) {
      final batch = tasks.skip(batchStart).take(_batchSize);

      for (final item in batch) {
        final todoId = _deterministicTodoId(item);
        final now = DateTime.now();

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

        // Preserve lastClarifiedAt when unchanged; stamp now on any mutation
        // (both additions and removals count as clarification events).
        DateTime? computedLastClarifiedAt;
        if (personTagsChanged) {
          computedLastClarifiedAt = now.toUtc();
        } else {
          final existingRow = await (db.select(db.todos)
                ..where((t) => t.id.equals(todoId)))
              .getSingleOrNull();
          computedLastClarifiedAt = existingRow?.lastClarifiedAt;
        }

        await db.into(db.todos).insert(
              TodosCompanion(
                id: Value(todoId),
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
                createdAt: Value(now),
                updatedAt: Value(now),
              ),
              mode: InsertMode.insertOrReplace,
            );

        if (personTagsChanged) {
          await _deletePersonTagLinksForTodo(db, todoId);
          if (effectiveWaitingFor != null) {
            final personTagId = personTagIds[effectiveWaitingFor] ??
                await db.tagDao.createPersonTag(effectiveWaitingFor, userId);
            personTagIds[effectiveWaitingFor] = personTagId;
            await db.into(db.todoTags).insert(
                  TodoTagsCompanion(
                    id: Value(todoTagIdFor(todoId, personTagId)),
                    todoId: Value(todoId),
                    tagId: Value(personTagId),
                    userId: Value(userId),
                  ),
                  mode: InsertMode.insertOrReplace,
                );
          }
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
          await db.into(db.todoTags).insert(
                TodoTagsCompanion(
                  id: Value(todoTagIdFor(todoId, projectTagId)),
                  todoId: Value(todoId),
                  tagId: Value(projectTagId),
                  userId: Value(userId),
                ),
                mode: InsertMode.insertOrReplace,
              );
        }

        // Upsert generic (context) tags.
        for (final tagName in item.tags) {
          final tagId = contextTagIds[tagName] ??
              await db.tagDao.findOrCreateTag(tagName, 'context', userId);
          contextTagIds[tagName] = tagId;
          await db.into(db.todoTags).insert(
                TodoTagsCompanion(
                  id: Value(todoTagIdFor(todoId, tagId)),
                  todoId: Value(todoId),
                  tagId: Value(tagId),
                  userId: Value(userId),
                ),
                mode: InsertMode.insertOrReplace,
              );
        }

        importedCount++;
      }
    }
  });

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
  // possibly capture_outcomes carved out), a fresh import must not reset it
  // to the Inbox. Update in place rather than INSERT OR REPLACE: REPLACE is
  // delete-then-insert in SQLite, which would fire the ON DELETE CASCADE on
  // capture_outcomes / capture_tags wherever foreign_keys enforcement is on
  // and silently drop the user's provenance links. Updating leaves
  // created_at, clarified_at, and the child rows untouched; a brand-new
  // Capture keeps the NULL clarified_at default (unclarified — in the Inbox).
  final existing = await db.captureDao.getCapture(captureId);

  if (existing == null) {
    await db.into(db.captures).insert(
          CapturesCompanion(
            id: Value(captureId),
            title: Value(item.name),
            notes: Value(item.notes),
            captureSource: const Value('nirvana_import'),
            userId: Value(userId),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
  } else {
    await (db.update(db.captures)..where((c) => c.id.equals(captureId))).write(
      CapturesCompanion(
        title: Value(item.name),
        notes: Value(item.notes),
        captureSource: const Value('nirvana_import'),
        userId: Value(userId),
        updatedAt: Value(now),
      ),
    );
  }
  db.notifyCapturesViewWrite();

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

/// Deletes all person-typed tag links for [todoId], leaving project/context
/// links untouched.
Future<void> _deletePersonTagLinksForTodo(
    GtdDatabase db, String todoId) async {
  final rows = await (db.select(db.todoTags).join([
    innerJoin(db.tags, db.tags.id.equalsExp(db.todoTags.tagId)),
  ])
        ..where(
            db.todoTags.todoId.equals(todoId) &
            db.tags.type.equals('person')))
      .get();
  final ids = rows.map((r) => r.readTable(db.todoTags).id).toList();
  if (ids.isNotEmpty) {
    await (db.delete(db.todoTags)..where((tt) => tt.id.isIn(ids))).go();
  }
}
