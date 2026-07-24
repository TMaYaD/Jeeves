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
import 'package:jeeves/database/powersync_schema.g.dart';
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

/// Mirror of `_indexes` in `lib/tool/builders/powersync_schema_builder.dart`:
/// the local-only indexes the generated schema must declare, keyed by table.
///
/// Column parity alone would not catch a dropped index — the schema would still
/// be *consistent*, just quietly full-scanning. `actions(outcome_id, role)`
/// backs the "has a current Action" EXISTS predicate behind the Next List and
/// the re-clarification queue (ADR-0001 story 3), which runs once per candidate
/// Outcome on every re-emission, so its absence is a performance regression no
/// other assertion would notice.
const _requiredIndexes = <String, List<List<String>>>{
  'actions': [
    ['outcome_id', 'role'],
  ],
};

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
        if (psTable == null) {
          // A `Synced` Drift table without a PowerSync counterpart means the
          // schema generator silently dropped it — fail loudly. Local-only
          // tables (no `Synced` mixin) are legitimately absent and skipped.
          if (table is Synced) {
            failures.add('$tableName: missing from generated PowerSync schema');
          }
          continue;
        }

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

      // --------------------------------------------------------------------
      // Check D — declared PowerSync indexes are present and well-formed
      // --------------------------------------------------------------------
      for (final entry in _requiredIndexes.entries) {
        final psTable = psByName[entry.key];
        if (psTable == null) {
          failures.add(
            '${entry.key}: required index declared for a table missing from '
            'the generated PowerSync schema',
          );
          continue;
        }
        final declared = {
          for (final idx in psTable.indexes)
            idx.columns.map((c) => c.column).toList().join(','),
        };
        for (final wanted in entry.value) {
          if (!declared.contains(wanted.join(','))) {
            failures.add(
              '${entry.key}: missing PowerSync index on (${wanted.join(', ')}) '
              '— declared: ${declared.isEmpty ? '(none)' : declared.join(' | ')}',
            );
          }
        }
      }

      // Every declared index must name real Drift columns, so a column rename
      // fails here rather than at `powersync_replace_schema` time on a device.
      for (final psTable in powersyncSchema.tables) {
        final driftTable = db.allTables.firstWhere(
          (t) => t.actualTableName == psTable.name,
          orElse: () => throw StateError(
            'PowerSync table ${psTable.name} has no Drift counterpart',
          ),
        );
        for (final idx in psTable.indexes) {
          for (final col in idx.columns) {
            if (!driftTable.columnsByName.containsKey(col.column)) {
              failures.add(
                '${psTable.name}: index ${idx.name} references unknown column '
                '${col.column}',
              );
            }
          }
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
