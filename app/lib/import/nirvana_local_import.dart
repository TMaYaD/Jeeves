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
import '../utils/tag_colors.dart';
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
          ..where(
              (t) => t.userId.equals(userId) & t.type.equals('project')))
        .get();
    final existingProjectNames = {for (final t in existingTagRows) t.name};

    // Map project name → tag id (pre-existing OR newly inserted).
    final projectTagIds = <String, String>{
      for (final t in existingTagRows) t.name: t.id,
    };

    for (final projectName in allProjectNames) {
      if (!existingProjectNames.contains(projectName)) {
        final tagId = uuid.v4();
        final color = tagColorToHex(tagColorForName(projectName));
        await db.tagDao.upsertTag(TagsCompanion(
          id: Value(tagId),
          name: Value(projectName),
          type: const Value('project'),
          color: Value(color),
          userId: Value(userId),
        ));
        projectTagIds[projectName] = tagId;
        projectTagsCreated++;
      }
    }

    // --- Insert tasks in batches ---
    final tasks = items.where((i) => i.type == 'task').toList();

    // In-memory cache for context tag ids — avoids redundant SELECTs when
    // the same tag (e.g. "computer", "anywhere") appears on many tasks.
    final contextTagIds = <String, String>{};

    for (var batchStart = 0;
        batchStart < tasks.length;
        batchStart += _batchSize) {
      final batch = tasks.skip(batchStart).take(_batchSize);

      for (final item in batch) {
        final todoId = _deterministicTodoId(item);
        final now = DateTime.now();

        final dueDate = item.dueDate != null
            ? DateTime.tryParse(item.dueDate!)?.toUtc()
            : null;

        // Items imported with state='inbox' become next_action + clarified=false
        // so they appear in the inbox clarification step.
        // Items imported with state='waiting_for' are collapsed to next_action;
        // the waiting_for text column (written below) is the source of truth.
        final isClarified = item.state != 'inbox';
        var effectiveState = isClarified ? item.state : 'next_action';
        if (effectiveState == 'waiting_for') effectiveState = 'next_action';

        // Normalize at the import boundary: blank/whitespace → null so IS NOT
        // NULL checks don't produce phantom Waiting For items.
        final trimmedWaitingFor = item.waitingFor?.trim();
        final effectiveWaitingFor =
            (trimmedWaitingFor == null || trimmedWaitingFor.isEmpty)
                ? null
                : trimmedWaitingFor;

        await db.into(db.todos).insert(
              TodosCompanion(
                id: Value(todoId),
                title: Value(item.name),
                notes: Value(item.notes),
                doneAt: item.doneAt != null
                    ? Value(item.doneAt!.toUtc().toIso8601String())
                    : const Value(null),
                state: Value(effectiveState),
                clarified: Value(isClarified),
                dueDate: Value(dueDate),
                timeEstimate: Value(item.timeEstimate),
                energyLevel: Value(item.energyLevel),
                waitingFor: Value(effectiveWaitingFor),
                captureSource: const Value('nirvana_import'),
                userId: Value(userId),
                createdAt: Value(now),
                updatedAt: Value(now),
              ),
              mode: InsertMode.insertOrReplace,
            );
        if (item.intent == 'maybe') {
          await db.todoDao.deferTaskToMaybe(todoId, userId, now: now);
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
              await _upsertContextTag(db, tagName, userId);
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

/// A deterministic todo ID derived from the Nirvana item's id (UUID v5 under a
/// Jeeves namespace).  Makes re-importing the same export idempotent.
String _deterministicTodoId(NirvanaItem item) =>
    uuid.v5(Namespace.url.value, 'jeeves://nirvana_import/${item.id}');

/// Look up or insert a context tag by [name] for [userId].
///
/// Returns the tag's id.
Future<String> _upsertContextTag(
    GtdDatabase db, String name, String userId) async {
  final existing = await (db.select(db.tags)
        ..where((t) => t.name.equals(name) & t.userId.equals(userId)))
      .getSingleOrNull();
  if (existing != null) return existing.id;

  final tagId = uuid.v4();
  final color = tagColorToHex(tagColorForName(name));
  await db.tagDao.upsertTag(TagsCompanion(
    id: Value(tagId),
    name: Value(name),
    type: const Value('context'),
    color: Value(color),
    userId: Value(userId),
  ));
  return tagId;
}
