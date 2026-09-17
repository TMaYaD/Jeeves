/// Dry run of a *real* export file through the real importer.
///
/// Every other test in this directory builds the file it imports, so the suite
/// can only prove the importer handles documents we thought to write. The
/// migration this format exists for runs **once**, against a file nobody on the
/// project has seen. This is the check that closes that gap, and it is meant to
/// be run by hand before the cutover, not by CI:
///
/// ```
/// cd app && flutter test test/import/real_export_dry_run_test.dart \
///   --dart-define=jeeves_export_file=/path/to/your-export.json
/// ```
///
/// Nothing is written anywhere you can see: the file is imported into a fresh
/// in-memory store that is discarded when the test ends, and your own database
/// is never opened. A pass means the file imports clean; a failure names what
/// would have been lost, in the same words the app would use.
///
/// Without the define the test is skipped, so CI neither needs a file nor
/// quietly reports a green it did not earn.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/import/jeeves_export.dart';
import 'package:jeeves/import/nirvana_local_import.dart' show ImportResult;
import 'package:jeeves/import/nirvana_parser.dart' show ParseError;
import 'package:jeeves/sync/domain_op_capture.dart' show NoopDomainOpCapture;

import '../test_helpers.dart';

/// Path to the export file to check, from `--dart-define=jeeves_export_file=`.
const String _exportFilePath = String.fromEnvironment('jeeves_export_file');

/// The account the dry run imports as. An import remaps every row's `user_id`
/// to the importing account, so this is also the id the re-export reads back
/// by — and why `user_id` is the one field the comparison below ignores.
const String _dryRunUserId = 'dry-run-user';

const String _howToRun = 'Pass the file to check: flutter test '
    'test/import/real_export_dry_run_test.dart '
    '--dart-define=jeeves_export_file=/path/to/export.json';

void main() {
  configureSqliteForTests();

  test(
    'a real export file imports clean, and nothing is lost on the way in',
    () async {
      final file = File(_exportFilePath);
      if (!file.existsSync()) {
        fail('No file at $_exportFilePath. $_howToRun');
      }
      final content = await file.readAsString();
      stdout.writeln('Checking ${file.path} '
          '(${await file.length()} bytes) — nothing is written to your own '
          'database.');

      if (!isJeevesExport(content)) {
        fail('$_exportFilePath is not a Jeeves export. A Jeeves export is a '
            'JSON object carrying a "$jeevesExportEnvelopeKey" version and a '
            '"$jeevesExportCollectionsKey" map. A Nirvana export is a bare '
            'JSON list and goes in through the Nirvana importer instead.');
      }

      final db = GtdDatabase(
        NativeDatabase.memory(),
        opCapture: const NoopDomainOpCapture(),
      );
      addTearDown(db.close);

      final ImportResult result;
      try {
        result = await importJeevesExport(
          content: content,
          userId: _dryRunUserId,
          db: db,
        );
      } on ParseError catch (e) {
        fail('This build REFUSES the file, and would import none of it:\n\n'
            '  ${e.message}\n\n'
            'That refusal is the fix working, not a crash: a file this build '
            'cannot fully read is refused whole rather than imported in part. '
            'Do not run the migration against this file until the reason above '
            'is resolved.');
      }

      stdout.writeln('Accepted. Outcomes imported: ${result.importedCount}; '
          'rows skipped: ${result.skippedCount}.');
      expect(
        result.skippedCount,
        0,
        reason: 'The file carried ${result.skippedCount} row(s) this build '
            'could not write — a row with no usable id, or a junction whose '
            'domain key resolved to nothing. They are counted rather than '
            'hidden, but they would not survive the migration.',
      );

      // The real question is not "did it throw" but "is everything still
      // there". Re-export the store the import just filled and compare it,
      // row for row, against the file that went in.
      final roundTripped = await buildJeevesExport(
        db: db,
        userId: _dryRunUserId,
      );
      final before = _rowsById(content: content);
      final after = _rowsById(document: roundTripped);

      final report = <String>[];
      for (final name in {...before.keys, ...after.keys}.toList()..sort()) {
        final source = before[name] ?? const {};
        final stored = after[name] ?? const {};
        final missing = source.keys.where((id) => !stored.containsKey(id));
        final changed = source.keys
            .where((id) => stored.containsKey(id))
            .where((id) => !_sameRow(source[id]!, stored[id]!));
        stdout.writeln('  $name: ${source.length} in file, '
            '${stored.length} after import');
        if (missing.isNotEmpty) {
          report.add('$name: ${missing.length} row(s) did not survive the '
              'import (first: ${missing.take(3).join(', ')})');
        }
        if (changed.isNotEmpty) {
          report.add('$name: ${changed.length} row(s) came back with different '
              'fields (first: ${changed.take(3).join(', ')})');
        }
      }
      expect(
        report,
        isEmpty,
        reason: 'The import did not preserve the file:\n  '
            '${report.join('\n  ')}',
      );
      stdout.writeln('Round trip clean — every row in the file is in the store '
          'afterwards, with the same fields.');
    },
    skip: _exportFilePath.isEmpty
        ? 'No export file given, so there is nothing to dry-run. $_howToRun'
        : false,
  );
}

/// `{collection name: {row id: row}}` for either an export file's JSON text or
/// an already-built export document, keyed by the name the *file* spells.
Map<String, Map<String, Map<String, Object?>>> _rowsById({
  String? content,
  Map<String, Object?>? document,
}) {
  final Map<Object?, Object?> decoded =
      document ?? (jsonDecode(content!) as Map);
  final collections = decoded[jeevesExportCollectionsKey] as Map;
  final out = <String, Map<String, Map<String, Object?>>>{};
  for (final entry in collections.entries) {
    // Both sides are keyed by the collection this build stores the rows in, so
    // a file written before a rename lines up with a store written after one.
    final name = resolveJeevesExportCollection('${entry.key}') ?? '${entry.key}';
    final rows = entry.value;
    if (rows is! List) continue;
    out[name] = {
      for (final row in rows)
        if (row is Map && row['id'] is String)
          row['id'] as String: {
            for (final field in row.entries) '${field.key}': field.value,
          },
    };
  }
  return out;
}

/// Whether two wire rows carry the same fields, ignoring `user_id` — which an
/// import deliberately rewrites to the importing account.
bool _sameRow(Map<String, Object?> before, Map<String, Object?> after) {
  final keys = {...before.keys, ...after.keys}..remove('user_id');
  return keys.every((key) => before[key] == after[key]);
}
