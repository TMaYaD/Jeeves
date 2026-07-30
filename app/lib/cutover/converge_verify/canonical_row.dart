/// Canonical row serialisation for the converge-verify check (#553 Phase 1).
///
/// **Cutover tooling — removed by #556**, together with `spec/converge_verify/`,
/// `backend/app/converge_verify/` and the settings entry that reaches the screen.
///
/// The twin of `backend/app/converge_verify/canonical.py`. Neither is the
/// reference: both are measured against the frozen, hand-authored vectors in
/// `spec/converge_verify/canonical_row_vectors.json`, which also carry the column
/// manifest both sides hardcode. A digest that depended on which side computed it
/// would make the whole check worthless, so the encoding is spelled out here
/// rather than delegated to `jsonEncode` — the two languages' JSON writers
/// disagree on control-character escaping.
///
/// Nothing in this library throws on bad data. A value a column kind refuses
/// degrades to a sentinel in the canonical string plus a [ConvergeRowAnomaly],
/// and the caller surfaces it. A throw would brick the report on the one device
/// the check exists to inspect.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

// The timestamp grammar and the refused-value spelling are protocol surface and
// live in the sync layer (`collection_codecs.dart`); this check reads them from
// there so the two cannot drift. Cutover tooling depending on the permanent sync
// layer is the correct direction.
import '../../sync/collection_codecs.dart' show parseTimestampUtcMs, rawAsText;

// --- column kinds ----------------------------------------------------------

const String verbatimText = 'verbatim_text';
const String integerColumn = 'integer';
const String booleanAsInt = 'boolean_as_int';
const String timestampUtcMs = 'timestamp_utc_ms';

// --- anomaly kinds ---------------------------------------------------------

const String unparseableTimestamp = 'unparseable_timestamp';
const String invalidBoolean = 'invalid_boolean';
const String invalidInteger = 'invalid_integer';
const String invalidText = 'invalid_text';
const String missingColumn = 'missing_column';

// --- declared exclusions ---------------------------------------------------

/// `user_id` is server-derived from the JWT on every table (docs/SYNC.md
/// ownership matrix), so the server side is JWT-scoped by construction and
/// comparing the column adds nothing.
///
/// The local side deliberately reads its tables **unfiltered** instead: a row
/// stranded at `user_id = 'local'` — one that never synced — then surfaces as a
/// local-only id, which is exactly the divergence Phase 1 must catch.
const List<String> excludedColumnsEveryTable = ['user_id'];

/// `todos.time_spent_minutes` is a dead denormalized cache — never read or
/// written (docs/SYNC.md), never carried by the op log (ADR-0030), already
/// excluded from the Phase-2 comparison (docs/TESTING.md). Phase 1's definition
/// of "converged" matches what the reseed will actually preserve, and the report
/// names the exclusion so the reviewer sees the judgment call.
const Map<String, List<String>> excludedColumnsByTable = {
  'todos': ['time_spent_minutes'],
};

// --- the manifest ----------------------------------------------------------

/// Ordered `(column, kind)` pairs per synced table.
///
/// Column order is alphabetical so neither side's declaration order (Drift's vs
/// SQLAlchemy's) can silently become the contract.
/// `test/cutover/canonical_row_test.dart` asserts this map against both the
/// frozen spec and the live [powersyncSchema], so a newly synced column fails the
/// suite instead of going quietly unverified.
const Map<String, List<(String, String)>> canonicalRowManifest = {
  'todos': [
    ('capture_source', verbatimText),
    ('clarified', booleanAsInt),
    ('created_at', timestampUtcMs),
    ('done_at', timestampUtcMs),
    ('due_date', timestampUtcMs),
    ('energy_level', verbatimText),
    ('id', verbatimText),
    ('intent', verbatimText),
    ('last_clarified_at', timestampUtcMs),
    ('last_next_action_completion_at', timestampUtcMs),
    ('location_id', verbatimText),
    ('notes', verbatimText),
    ('priority', integerColumn),
    ('time_estimate', integerColumn),
    ('title', verbatimText),
    ('updated_at', timestampUtcMs),
  ],
  'tags': [
    ('color', verbatimText),
    ('id', verbatimText),
    ('name', verbatimText),
    ('type', verbatimText),
  ],
  'todo_tags': [
    ('id', verbatimText),
    ('tag_id', verbatimText),
    ('todo_id', verbatimText),
  ],
  'actions': [
    ('created_at', timestampUtcMs),
    ('done_at', timestampUtcMs),
    ('energy_level', verbatimText),
    ('id', verbatimText),
    ('outcome_id', verbatimText),
    ('position', integerColumn),
    ('role', verbatimText),
    ('text', verbatimText),
    ('time_estimate', integerColumn),
    ('updated_at', timestampUtcMs),
  ],
  'focus_sessions': [
    ('current_task_id', verbatimText),
    ('ended_at', timestampUtcMs),
    ('id', verbatimText),
    ('started_at', timestampUtcMs),
  ],
  'time_logs': [
    ('action_id', verbatimText),
    ('ended_at', timestampUtcMs),
    ('focus_session_id', verbatimText),
    ('id', verbatimText),
    ('started_at', timestampUtcMs),
    ('task_id', verbatimText),
  ],
  'focus_session_tasks': [
    ('disposition', verbatimText),
    ('focus_session_id', verbatimText),
    ('id', verbatimText),
    ('position', integerColumn),
    ('task_id', verbatimText),
  ],
  'focus_session_dispositions': [
    ('disposition', verbatimText),
    ('focus_session_id', verbatimText),
    ('id', verbatimText),
    ('task_id', verbatimText),
  ],
  'user_preferences': [
    ('id', verbatimText),
    ('key', verbatimText),
    ('updated_at', timestampUtcMs),
    ('value', verbatimText),
  ],
  'captures': [
    ('capture_source', verbatimText),
    ('clarified_at', timestampUtcMs),
    ('created_at', timestampUtcMs),
    ('id', verbatimText),
    ('notes', verbatimText),
    ('title', verbatimText),
    ('updated_at', timestampUtcMs),
  ],
  'capture_outcomes': [
    ('capture_id', verbatimText),
    ('created_at', timestampUtcMs),
    ('id', verbatimText),
    ('outcome_id', verbatimText),
  ],
  'capture_tags': [
    ('capture_id', verbatimText),
    ('id', verbatimText),
    ('tag_id', verbatimText),
  ],
};

/// The tables the check compares, in a stable order for the report.
const List<String> convergeVerifyTables = [
  'todos',
  'tags',
  'todo_tags',
  'actions',
  'focus_sessions',
  'time_logs',
  'focus_session_tasks',
  'focus_session_dispositions',
  'user_preferences',
  'captures',
  'capture_outcomes',
  'capture_tags',
];

/// Bumped only alongside a change to `spec/converge_verify/`.
const int convergeVerifySpecVersion = 1;

// --- results ---------------------------------------------------------------

/// A value the manifest's column kind refused, named so a reviewer can go look.
class ConvergeRowAnomaly {
  const ConvergeRowAnomaly({
    required this.column,
    required this.kind,
    required this.raw,
    this.rowId,
  });

  final String column;
  final String kind;
  final String? raw;

  /// Filled in by the report builder, which knows the row's identity.
  final String? rowId;

  ConvergeRowAnomaly withRowId(String? id) => ConvergeRowAnomaly(
        column: column,
        kind: kind,
        raw: raw,
        rowId: id,
      );

  Map<String, Object?> toJson() => {
        if (rowId != null) 'row_id': rowId,
        'column': column,
        'kind': kind,
        'raw': raw,
      };

  @override
  String toString() => 'ConvergeRowAnomaly($rowId, $column, $kind, $raw)';

  @override
  bool operator ==(Object other) =>
      other is ConvergeRowAnomaly &&
      other.column == column &&
      other.kind == kind &&
      other.raw == raw &&
      other.rowId == rowId;

  @override
  int get hashCode => Object.hash(column, kind, raw, rowId);
}

class CanonicalRow {
  const CanonicalRow({
    required this.canonical,
    required this.digest,
    required this.anomalies,
  });

  final String canonical;
  final String digest;
  final List<ConvergeRowAnomaly> anomalies;
}

// --- the canonical encoder -------------------------------------------------

const Map<int, String> _textEscapes = {
  0x22: r'\"',
  0x5c: r'\\',
  0x08: r'\b',
  0x09: r'\t',
  0x0a: r'\n',
  0x0c: r'\f',
  0x0d: r'\r',
};

const String _lowercaseHexDigits = '0123456789abcdef';

/// A double-quoted JSON string under the spec's exact escape table.
///
/// Hand-rolled rather than `jsonEncode`: Dart's encoder spells a C0 control that
/// has no short escape with uppercase hex, Python's with lowercase, and the
/// digest may not depend on which side computed it.
String encodeCanonicalText(String value) {
  final buffer = StringBuffer('"');
  for (final unit in value.codeUnits) {
    final escape = _textEscapes[unit];
    if (escape != null) {
      buffer.write(escape);
    } else if (unit < 0x20) {
      buffer
        ..write(r'\u00')
        ..write(_lowercaseHexDigits[(unit >> 4) & 0xf])
        ..write(_lowercaseHexDigits[unit & 0xf]);
    } else {
      // Code units, so a surrogate pair is written half by half and reassembles
      // into the original character.
      buffer.writeCharCode(unit);
    }
  }
  buffer.write('"');
  return buffer.toString();
}

String _sentinel(String kind, Object? value) {
  if (kind == missingColumn) return '{"missing_column":true}';
  return '{${encodeCanonicalText(kind)}:${encodeCanonicalText(rawAsText(value))}}';
}

// --- per-column encoding ---------------------------------------------------

/// `(encoded, refusalKind)` for one column value.
(String, String?) _encodeColumn(String kind, Object? value) {
  if (value == null) return ('null', null);

  switch (kind) {
    case verbatimText:
      if (value is String) return (encodeCanonicalText(value), null);
      return (_sentinel(invalidText, value), invalidText);

    case integerColumn:
      if (value is bool) return (_sentinel(invalidInteger, value), invalidInteger);
      if (value is int) return ('$value', null);
      if (value is double && value.isFinite && value == value.roundToDouble()) {
        return ('${value.toInt()}', null);
      }
      return (_sentinel(invalidInteger, value), invalidInteger);

    case booleanAsInt:
      if (value is bool) return (value ? '1' : '0', null);
      if (value is int && (value == 0 || value == 1)) return ('$value', null);
      return (_sentinel(invalidBoolean, value), invalidBoolean);

    case timestampUtcMs:
      final instant = parseTimestampUtcMs(value);
      if (instant != null) return (encodeCanonicalText(instant), null);
      return (_sentinel(unparseableTimestamp, value), unparseableTimestamp);

    default:
      // Unreachable while the manifest and the kind constants agree, and the
      // vector suite asserts they do. Degrade rather than throw, on principle.
      return (_sentinel(invalidText, value), invalidText);
  }
}

/// The canonical string, its SHA-256 digest, and any per-row anomalies.
CanonicalRow canonicalRow(String table, Map<String, Object?> values) {
  final manifest = canonicalRowManifest[table]!;
  final encoded = <String>[];
  final anomalies = <ConvergeRowAnomaly>[];
  for (final (column, kind) in manifest) {
    if (!values.containsKey(column)) {
      encoded.add(_sentinel(missingColumn, null));
      anomalies.add(ConvergeRowAnomaly(
        column: column,
        kind: missingColumn,
        raw: null,
      ));
      continue;
    }
    final raw = values[column];
    final (piece, refusal) = _encodeColumn(kind, raw);
    encoded.add(piece);
    if (refusal != null) {
      anomalies.add(ConvergeRowAnomaly(
        column: column,
        kind: refusal,
        raw: rawAsText(raw),
      ));
    }
  }
  final canonical = '[${encoded.join(',')}]';
  return CanonicalRow(
    canonical: canonical,
    digest: sha256.convert(utf8.encode(canonical)).toString(),
    anomalies: anomalies,
  );
}

/// The declared exclusions, published in the report so a reviewer sees them.
Map<String, List<String>> excludedColumnsReport() => {
      '*': excludedColumnsEveryTable,
      ...excludedColumnsByTable,
    };

/// The digest over a whole per-table `id -> row_digest` map.
///
/// Used for the read-only proof — one short line the screen can show before and
/// after a run — and as a cheap "these two maps are the same" comparison.
String convergeMapDigest(Map<String, String> rowDigests) {
  final entries = rowDigests.keys.toList()..sort();
  final buffer = StringBuffer('[');
  for (var index = 0; index < entries.length; index++) {
    if (index > 0) buffer.write(',');
    buffer
      ..write('[')
      ..write(encodeCanonicalText(entries[index]))
      ..write(',')
      ..write(encodeCanonicalText(rowDigests[entries[index]]!))
      ..write(']');
  }
  buffer.write(']');
  return sha256.convert(utf8.encode(buffer.toString())).toString();
}
