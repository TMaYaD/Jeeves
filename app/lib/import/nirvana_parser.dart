/// CSV and JSON parsers that produce [NirvanaItem] lists.
///
/// Bucketing in Jeeves is driven by `clarified` + `intent` + `doneAt` +
/// person-tags; this parser sets those four fields directly per the per-state
/// table in `docs/REQUIREMENTS.md` (Epic 11: Data Portability & Migration).
/// States with no direct equivalent
/// (Scheduled / Repeating / Reference) are coerced to `intent='maybe'` plus an
/// `@scheduled` / `@repeating` / `@reference` context tag so the original
/// Nirvana category remains identifiable after import.
library;

import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'nirvana_item.dart';

const _uuid = Uuid();

/// Derive a stable Nirvana item ID for CSV rows (which have no native ID).
///
/// Uses UUID v5 of "name|type|parentName" under a fixed namespace so that
/// re-importing the same CSV row always produces the same id, making
/// CSV imports idempotent.
String _csvItemId(String name, String type, String? parentName) =>
    _uuid.v5(Namespace.url.value, 'jeeves://csv_item/$type/${parentName ?? ""}/$name');

// ---------------------------------------------------------------------------
// State classification — CSV
// ---------------------------------------------------------------------------

// Recognised CSV literals that imply the item has been clarified in Nirvana.
// Anything outside this set (incl. the explicit 'inbox' literal and any
// unrecognised value such as the project-only 'active') is treated as inbox —
// `clarified=false` — so unknowns surface for review rather than slipping
// silently into active lists.
const _csvClarifiedStates = {
  'next',
  'waiting',
  'someday',
  'inactive/later',
  'scheduled',
  'scheduled/repeating',
  'reference',
  'trash',
  'logbook',
};

// CSV literals → Maybe (intent='maybe').
const _csvMaybeStates = {
  'someday',
  'inactive/later',
  'scheduled',
  'scheduled/repeating',
  'reference',
};

// CSV literals → Trash (intent='trash').
const _csvTrashStates = {'trash'};

// CSV literal → context tag added so states with no direct Jeeves equivalent
// remain identifiable after import.
const _csvAutoTags = <String, String>{
  'scheduled': '@scheduled',
  'scheduled/repeating': '@repeating',
  'reference': '@reference',
};

// ---------------------------------------------------------------------------
// State classification — JSON
// ---------------------------------------------------------------------------

// Recognised JSON state ints that imply the item has been clarified in
// Nirvana. State 0 (Inbox) and any unrecognised int (e.g. 11 for active
// projects) default to `clarified=false` so unknowns surface for review.
const _jsonClarifiedStateInts = {1, 2, 3, 4, 5, 6, 7, 9, 10};
const _jsonMaybeStateInts = {3, 4, 5, 9, 10};
const _jsonTrashStateInts = {6};

const _jsonAutoTags = <int, String>{
  3: '@scheduled',
  9: '@repeating',
  10: '@reference',
};

const _jsonEnergyMap = <int, String?>{
  0: null,
  1: 'low',
  2: 'medium',
  3: 'high',
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class ParseError implements Exception {
  const ParseError(this.message);
  final String message;

  @override
  String toString() => 'ParseError: $message';
}

List<String> _parseCsvTags(String raw) =>
    raw.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();

/// Convert Nirvana date strings like '2024-4-3' to 'YYYY-MM-DD'.
String? _parseCsvDate(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  try {
    final parts = trimmed.split('-');
    if (parts.length != 3) return null;
    final year = int.parse(parts[0]);
    final month = int.parse(parts[1]);
    final day = int.parse(parts[2]);
    // Validate by constructing (throws RangeError if invalid).
    DateTime(year, month, day);
    return '${year.toString().padLeft(4, '0')}-'
        '${month.toString().padLeft(2, '0')}-'
        '${day.toString().padLeft(2, '0')}';
  } catch (_) {
    return null;
  }
}

int? _parseInt(dynamic raw) {
  if (raw == null) return null;
  final v = raw is int ? raw : int.tryParse(raw.toString());
  if (v == null || v <= 0) return null;
  return v;
}

// ---------------------------------------------------------------------------
// Minimal RFC-4180 CSV parser
// ---------------------------------------------------------------------------

/// Splits [content] into rows of fields following RFC 4180.
///
/// Handles:
/// - Quoted fields (double-quote delimiters)
/// - Escaped double-quotes (`""`)
/// - Embedded newlines inside quoted fields
List<List<String>> _parseCsvRaw(String content) {
  final rows = <List<String>>[];
  final fields = <String>[];
  final current = StringBuffer();
  var inQuotes = false;
  var i = 0;

  while (i < content.length) {
    final ch = content[i];

    if (inQuotes) {
      if (ch == '"') {
        // Peek ahead for escaped quote
        if (i + 1 < content.length && content[i + 1] == '"') {
          current.write('"');
          i += 2;
          continue;
        }
        inQuotes = false;
        i++;
        continue;
      }
      current.write(ch);
      i++;
    } else {
      if (ch == '"') {
        inQuotes = true;
        i++;
      } else if (ch == ',') {
        fields.add(current.toString());
        current.clear();
        i++;
      } else if (ch == '\r') {
        // \r\n or bare \r
        fields.add(current.toString());
        current.clear();
        rows.add(List.of(fields));
        fields.clear();
        i++;
        if (i < content.length && content[i] == '\n') i++;
      } else if (ch == '\n') {
        fields.add(current.toString());
        current.clear();
        rows.add(List.of(fields));
        fields.clear();
        i++;
      } else {
        current.write(ch);
        i++;
      }
    }
  }

  // Last field / row (file may not end with newline)
  fields.add(current.toString());
  if (fields.any((f) => f.isNotEmpty)) {
    rows.add(fields);
  }

  return rows;
}

// ---------------------------------------------------------------------------
// Public parsers
// ---------------------------------------------------------------------------

/// Parse a Nirvana CSV export.
///
/// Returns `(items, skippedCount)`. Skipped rows are those with an empty NAME
/// or an unrecognised TYPE.
(List<NirvanaItem>, int) parseCsv(String content) {
  final rawRows = _parseCsvRaw(content);
  if (rawRows.isEmpty) return (const [], 0);

  final headerRow = rawRows.first.map((h) => h.trim().toUpperCase()).toList();

  int col(String name) => headerRow.indexOf(name);
  final nameIdx = col('NAME');
  final typeIdx = col('TYPE');
  final stateIdx = col('STATE');
  final completedIdx = col('COMPLETED');
  final notesIdx = col('NOTES');
  final tagsIdx = col('TAGS');
  final timeIdx = col('TIME');
  final energyIdx = col('ENERGY');
  final waitingForIdx = col('WAITINGFOR');
  final dueDateIdx = col('DUEDATE');
  final parentIdx = col('PARENT');

  if (nameIdx < 0 || typeIdx < 0) {
    throw const ParseError('CSV is missing required NAME or TYPE columns');
  }

  String field(List<String> row, int idx) =>
      (idx >= 0 && idx < row.length) ? row[idx].trim() : '';

  final items = <NirvanaItem>[];
  var skipped = 0;

  for (final row in rawRows.skip(1)) {
    final name = field(row, nameIdx);
    if (name.isEmpty) {
      skipped++;
      continue;
    }

    final rawType = field(row, typeIdx).toLowerCase();
    final String itemType;
    if (rawType == 'task') {
      itemType = 'task';
    } else if (rawType == 'project') {
      itemType = 'project';
    } else {
      skipped++;
      continue;
    }

    final lcState = field(row, stateIdx).toLowerCase();
    final rawCompleted = field(row, completedIdx);
    final completed = rawCompleted.isNotEmpty;

    DateTime? doneAt;
    if (completed) {
      final parsedDate = _parseCsvDate(rawCompleted);
      doneAt = parsedDate != null
          ? DateTime.parse('${parsedDate}T00:00:00Z')
          : DateTime.now().toUtc();
    }

    final clarified = _csvClarifiedStates.contains(lcState);

    final String intent;
    if (completed) {
      intent = 'next';
    } else if (_csvTrashStates.contains(lcState)) {
      intent = 'trash';
    } else if (_csvMaybeStates.contains(lcState)) {
      intent = 'maybe';
    } else {
      intent = 'next';
    }

    final autoTag = completed ? null : _csvAutoTags[lcState];
    final tags = [
      ..._parseCsvTags(field(row, tagsIdx)),
      ?autoTag,
    ];

    final parentRaw = field(row, parentIdx);
    final parentName =
        parentRaw.isEmpty || parentRaw.toLowerCase() == 'standalone'
            ? null
            : parentRaw;

    final energyRaw = field(row, energyIdx).toLowerCase();
    final energyLevel =
        ['low', 'medium', 'high'].contains(energyRaw) ? energyRaw : null;

    items.add(NirvanaItem(
      id: _csvItemId(name, itemType, parentName),
      name: name,
      type: itemType,
      clarified: clarified,
      intent: intent,
      doneAt: doneAt,
      notes: notesIdx >= 0 && notesIdx < row.length
          ? (row[notesIdx].trim().isNotEmpty ? row[notesIdx].trim() : null)
          : null,
      tags: tags,
      energyLevel: energyLevel,
      timeEstimate: _parseInt(field(row, timeIdx)),
      dueDate: _parseCsvDate(field(row, dueDateIdx)),
      parentId: null,
      parentName: parentName,
      waitingFor: field(row, waitingForIdx).isNotEmpty
          ? field(row, waitingForIdx)
          : null,
    ));
  }

  return (items, skipped);
}

/// Parse a Nirvana JSON export.
///
/// Returns `(items, skippedCount)`. Filters out deleted and cancelled rows.
(List<NirvanaItem>, int) parseJson(String content) {
  final dynamic data;
  try {
    data = jsonDecode(content);
  } catch (e) {
    throw ParseError('Invalid JSON: $e');
  }

  if (data is! List) {
    throw const ParseError('JSON export must be a list of items');
  }

  final items = <NirvanaItem>[];
  var skipped = 0;

  for (final row in data) {
    if (row is! Map) {
      skipped++;
      continue;
    }

    final cancelled = row['cancelled'];
    final deleted = row['deleted'];
    if ((cancelled != null && cancelled != 0 && cancelled != false) ||
        (deleted != null && deleted != 0 && deleted != false)) {
      skipped++;
      continue;
    }

    final nameRaw = row['name'];
    final name = nameRaw is String ? nameRaw.trim() : '';
    if (name.isEmpty) {
      skipped++;
      continue;
    }

    final rawType = row['type'];
    final String itemType;
    if (rawType == 1) {
      itemType = 'project';
    } else if (rawType == 0) {
      itemType = 'task';
    } else {
      skipped++;
      continue;
    }

    final rawState = row['state'];
    final rawStateInt = rawState is int ? rawState : 0;

    final completedTs = row['completed'];
    final completed =
        completedTs != null && completedTs != 0 && completedTs != false;
    DateTime? doneAt;
    if (completed) {
      doneAt = completedTs is int && completedTs > 0
          ? DateTime.fromMillisecondsSinceEpoch(completedTs * 1000, isUtc: true)
          : DateTime.now().toUtc();
    }

    final clarified = _jsonClarifiedStateInts.contains(rawStateInt);

    final String intent;
    if (completed) {
      intent = 'next';
    } else if (_jsonTrashStateInts.contains(rawStateInt)) {
      intent = 'trash';
    } else if (_jsonMaybeStateInts.contains(rawStateInt)) {
      intent = 'maybe';
    } else {
      intent = 'next';
    }

    final autoTag = completed ? null : _jsonAutoTags[rawStateInt];

    // Tags: Nirvana stores as ",tag1,tag2," — strip leading/trailing commas.
    final rawTagsStr = row['tags'];
    final tagsStr = rawTagsStr is String ? rawTagsStr : '';
    final tags = [
      ...tagsStr
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty),
      ?autoTag,
    ];

    final energyRaw = row['energy'];
    final energyLevel =
        _jsonEnergyMap[energyRaw is int ? energyRaw : 0];

    final etimeRaw = row['etime'];
    final timeEstimate =
        etimeRaw is int && etimeRaw > 0 ? etimeRaw : null;

    final duedateRaw = row['duedate'];
    final dueDate = duedateRaw is String && duedateRaw.trim().isNotEmpty
        ? _parseCsvDate(duedateRaw.trim())
        : null;

    final parentIdRaw = row['parentid'];
    final String? parentId = parentIdRaw is String && parentIdRaw.isNotEmpty
        ? parentIdRaw
        : null;

    final idRaw = row['id'];
    final id = idRaw is String && idRaw.isNotEmpty ? idRaw : _uuid.v4();

    final noteRaw = row['note'];
    final notes =
        noteRaw is String && noteRaw.trim().isNotEmpty ? noteRaw.trim() : null;

    final waitingForRaw = row['waitingfor'];
    final waitingFor = waitingForRaw is String && waitingForRaw.trim().isNotEmpty
        ? waitingForRaw.trim()
        : null;

    items.add(NirvanaItem(
      id: id,
      name: name,
      type: itemType,
      clarified: clarified,
      intent: intent,
      doneAt: doneAt,
      notes: notes,
      tags: tags,
      energyLevel: energyLevel,
      timeEstimate: timeEstimate,
      dueDate: dueDate,
      parentId: parentId,
      parentName: null,
      waitingFor: waitingFor,
    ));
  }

  return (items, skipped);
}

/// Auto-detect format from [filename] extension, falling back to content sniff.
String detectFormat(String filename, String content) {
  final lower = filename.toLowerCase();
  if (lower.endsWith('.json')) return 'json';
  if (lower.endsWith('.csv')) return 'csv';
  final stripped = content.trimLeft();
  return stripped.startsWith('[') || stripped.startsWith('{') ? 'json' : 'csv';
}
