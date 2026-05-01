import 'package:build/build.dart';

Builder powersyncSchemaBuilder(BuilderOptions options) =>
    _PowersyncSchemaBuilder();

class _PowersyncSchemaBuilder implements Builder {
  @override
  final buildExtensions = const {
    'lib/database/gtd_database.g.dart': ['lib/database/powersync_schema.g.dart'],
  };

  static const _typeMap = {
    'String': 'text',
    'int': 'integer',
    'bool': 'integer',
    'DateTime': 'text', // PS replicates Postgres ISO-8601 text regardless of local storage
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    // Read tables.dart to discover which Dart classes carry `with Synced`.
    // readAsString() creates an implicit build dependency so a change to
    // tables.dart triggers a rebuild of this output.
    final tablesAsset = AssetId(
      buildStep.inputId.package,
      'lib/database/tables.dart',
    );
    final tablesSource = await buildStep.readAsString(tablesAsset);

    final syncedRegex = RegExp(
      r'class\s+(\w+)\s+extends\s+Table\b[^{]*\bSynced\b',
    );
    final syncedClasses = syncedRegex
        .allMatches(tablesSource)
        .map((m) => m.group(1)!)
        .toSet();

    // Parse gtd_database.g.dart — split into per-class regions then extract
    // the SQL table name and column list from each region.
    final gSource = await buildStep.readAsString(buildStep.inputId);

    final classHeaderRegex = RegExp(
      r'^class \$(\w+)Table extends (\w+)',
      multiLine: true,
    );
    final tableNameRegex = RegExp(r"static const String \$name = '(\w+)';");
    // Matches GeneratedColumn<DartType>(\n  'sql_name', — captures type and name.
    final columnRegex = RegExp(r"GeneratedColumn<(\w+)>\s*\(\s*'([^']+)'");
    // Detects column shapes not handled by columnRegex so they fail loudly
    // instead of being silently skipped if Drift's code emission evolves.
    final unsupportedColumnShapeRegex = RegExp(
      r'GeneratedColumnWithTypeConverter<',
    );

    // Pairs of (sqlTableName, columns) for every synced table.
    final tables = <(String, List<(String, String)>)>[];

    // Track which `Synced` classes the regex actually matched so we can fail
    // the build if Drift's generated code shape changes and silently drops one.
    final matchedSyncedClasses = <String>{};

    final headerMatches = classHeaderRegex.allMatches(gSource).toList();
    for (var i = 0; i < headerMatches.length; i++) {
      final match = headerMatches[i];
      final parentClass = match.group(2)!;

      if (!syncedClasses.contains(parentClass)) continue;

      final regionStart = match.start;
      final regionEnd =
          i + 1 < headerMatches.length
              ? headerMatches[i + 1].start
              : gSource.length;
      final region = gSource.substring(regionStart, regionEnd);

      final tableNameMatch = tableNameRegex.firstMatch(region);
      if (tableNameMatch == null) {
        throw StateError(
          'powersync_schema_builder: matched synced class "$parentClass" but '
          'could not extract `\$name` via tableNameRegex from its region in '
          'gtd_database.g.dart — update tableNameRegex in '
          'powersync_schema_builder.dart.',
        );
      }
      final sqlTableName = tableNameMatch.group(1)!;
      matchedSyncedClasses.add(parentClass);

      if (unsupportedColumnShapeRegex.hasMatch(region)) {
        throw StateError(
          'powersync_schema_builder: table "$sqlTableName" contains '
          '`GeneratedColumnWithTypeConverter`, which is not handled by '
          'columnRegex. Update column parsing/type mapping in '
          'powersync_schema_builder.dart.',
        );
      }

      // Collect columns; dedup by SQL name in case of duplicate appearances.
      final seen = <String>{};
      final columns = <(String, String)>[];
      for (final colMatch in columnRegex.allMatches(region)) {
        final dartType = colMatch.group(1)!;
        final sqlName = colMatch.group(2)!;

        if (sqlName == 'id') continue; // PowerSync auto-injects the id column
        if (!seen.add(sqlName)) continue;

        final psType = _typeMap[dartType];
        if (psType == null) {
          throw Exception(
            'Unknown Dart type "$dartType" for column "$sqlName" in table '
            '"$sqlTableName". Add it to _typeMap in powersync_schema_builder.dart.',
          );
        }

        columns.add((psType, sqlName));
      }

      tables.add((sqlTableName, columns));
    }

    final missingSyncedClasses = syncedClasses.difference(matchedSyncedClasses);
    if (missingSyncedClasses.isNotEmpty) {
      throw StateError(
        'powersync_schema_builder: failed to derive PowerSync tables for '
        'synced Drift classes ${missingSyncedClasses.toList()..sort()}. '
        'The generated code in gtd_database.g.dart did not match the expected '
        'class-header / column shape — update the regexes in '
        'powersync_schema_builder.dart.',
      );
    }

    // Emit the generated file.
    final buf = StringBuffer()
      ..writeln('// GENERATED — do not edit by hand.')
      ..writeln(
        '// Derived from lib/database/gtd_database.g.dart by the powersync_schema_builder.',
      )
      ..writeln('// Run: dart run build_runner build')
      ..writeln()
      ..writeln("import 'package:powersync/powersync.dart' as ps;")
      ..writeln()
      ..writeln('const powersyncSchema = ps.Schema([');

    for (final (tableName, columns) in tables) {
      buf.writeln("  ps.Table('$tableName', [");
      for (final (psType, colName) in columns) {
        buf.writeln("    ps.Column.$psType('$colName'),");
      }
      buf.writeln('  ]),');
    }

    buf.writeln(']);');

    final output = AssetId(
      buildStep.inputId.package,
      'lib/database/powersync_schema.g.dart',
    );
    await buildStep.writeAsString(output, buf.toString());
  }
}
