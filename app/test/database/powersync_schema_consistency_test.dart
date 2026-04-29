/// Regression guard: every table in [powersyncSchema] must have a Drift-side
/// `id` column that is non-nullable TEXT with a declared UNIQUE constraint,
/// and the non-`id` column set must match the PowerSync column list exactly.
///
/// Prevents a class of bugs where the Drift schema and PowerSync schema drift
/// apart silently — the most recent example being focus_session_tasks missing
/// an `id` column entirely, which caused SqliteException(1811) at runtime.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart' as ps;

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/database/powersync_schema.dart';
import '../test_helpers.dart';

/// Maps a Drift [GeneratedColumn] to its canonical storage-type string for
/// comparison with PowerSync column types.
///
/// Uses 'text' for DateTime because [GtdDatabase] is configured with
/// storeDateTimeAsText: true.
String _driftStorageType(GeneratedColumn<Object> col) {
  if (col is GeneratedColumn<DateTime>) return 'text';
  if (col is GeneratedColumn<bool>) return 'integer';
  if (col is GeneratedColumn<int>) return 'integer';
  if (col is GeneratedColumn<double>) return 'real';
  if (col is GeneratedColumn<String>) return 'text';
  return 'unknown';
}

/// Maps a PowerSync [ps.ColumnType] to the same canonical storage-type string.
String _psStorageType(ps.ColumnType type) => type.sqlite.toLowerCase();

void main() {
  setUpAll(configureSqliteForTests);

  test(
    'every synced Drift table has id UNIQUE NOT NULL and matching PowerSync columns',
    () async {
      final db = GtdDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final psByName = {for (final t in powersyncSchema.tables) t.name: t};

      final failures = <String>[];

      for (final table in db.allTables) {
        final tableName = table.actualTableName;
        final psTable = psByName[tableName];
        if (psTable == null) continue; // local-only table, skip

        // ------------------------------------------------------------------
        // Check A — `id` column present and non-nullable TEXT
        // ------------------------------------------------------------------
        final idCol = table.columnsByName['id'];
        if (idCol == null) {
          failures.add('$tableName: missing `id` column');
        } else if (idCol.$nullable) {
          failures.add('$tableName: `id` column must be NOT NULL');
        } else if (_driftStorageType(idCol) != 'text') {
          failures.add('$tableName: `id` column must be TEXT');
        }

        // ------------------------------------------------------------------
        // Check B — `id` is declared UNIQUE
        // ------------------------------------------------------------------
        {
          final indexes = await db
              .customSelect('PRAGMA index_list($tableName)')
              .get();

          bool foundUniqueOnId = false;
          for (final idx in indexes) {
            if (idx.read<int>('unique') != 1) continue;
            final indexName = idx.read<String>('name');
            final indexCols = await db
                .customSelect('PRAGMA index_info($indexName)')
                .get();
            final colNames =
                indexCols.map((r) => r.read<String>('name')).toList();
            if (colNames.length == 1 && colNames.first == 'id') {
              foundUniqueOnId = true;
              break;
            }
          }

          if (!foundUniqueOnId) {
            failures.add(
              '$tableName: `id` column has no single-column UNIQUE index '
              '(PowerSync triggers require id to be unique)',
            );
          }
        }

        // ------------------------------------------------------------------
        // Check C — non-`id` column set matches PowerSync
        // ------------------------------------------------------------------
        final driftCols = {
          for (final entry in table.columnsByName.entries)
            if (entry.key != 'id')
              entry.value.name: _driftStorageType(entry.value),
        };

        final psCols = {
          for (final col in psTable.columns)
            col.name: _psStorageType(col.type),
        };

        final onlyInDrift = driftCols.keys.toSet()..removeAll(psCols.keys);
        final onlyInPs = psCols.keys.toSet()..removeAll(driftCols.keys);
        final typeMismatches = {
          for (final name in driftCols.keys)
            if (psCols.containsKey(name) && driftCols[name] != psCols[name])
              name: '${driftCols[name]} (Drift) vs ${psCols[name]} (PS)',
        };

        if (onlyInDrift.isNotEmpty ||
            onlyInPs.isNotEmpty ||
            typeMismatches.isNotEmpty) {
          final detail = [
            if (onlyInDrift.isNotEmpty) 'only in Drift: $onlyInDrift',
            if (onlyInPs.isNotEmpty) 'only in PowerSync: $onlyInPs',
            if (typeMismatches.isNotEmpty) 'type mismatch: $typeMismatches',
          ].join('; ');
          failures.add('$tableName: column mismatch — $detail');
        }
      }

      if (failures.isNotEmpty) {
        fail(
          'PowerSync↔Drift schema consistency failures:\n'
          '${failures.map((f) => '  • $f').join('\n')}',
        );
      }
    },
  );
}
