/// The plugin is a carrier: a source scan, and the additive migration.
@TestOn('!browser')
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/sync_database.dart';

void main() {
  test('nothing under sync/folder names merge state, the merge core or the host service',
      () {
    const forbidden = [
      'reduced_fields',
      'field_clocks',
      'row_tombstones',
      'change_sequence',
      'plugin_cursors',
      'reducedFields',
      'fieldClocks',
      'rowTombstones',
      'changeSequence',
      'pluginCursors',
      'MergeCore',
      'MergeState',
      'SyncHostService',
      'DomainProjector',
      'DomainReconciler',
      'Reducer',
      'GtdDatabase',
    ];
    final offenders = <String>[];
    for (final entity in Directory('lib/sync/folder').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final text = entity.readAsStringSync();
      for (final word in forbidden) {
        if (text.contains(word)) offenders.add('${entity.path} names $word');
      }
      for (final match in RegExp(r'''^import\s+['"]([^'"]+)['"]''', multiLine: true)
          .allMatches(text)) {
        final import = match.group(1)!;
        if (import.contains('host/sync_host_service') ||
            import.contains('host/merge_') ||
            import.contains('reducer.dart') ||
            import.contains('domain_')) {
          offenders.add('${entity.path} imports $import');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('a v11 sync store upgrades to v12 keeping every row, and the new tables start empty',
      () async {
    final directory = Directory.systemTemp.createTempSync('sync-v11-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/sync.sqlite');

    final seed = SyncDatabase(NativeDatabase(file));
    await seed.customStatement('DROP TABLE folder_sync_bindings');
    await seed.customStatement('DROP TABLE folder_pending_appends');
    await seed.customStatement('DROP TABLE folder_peers');
    await seed.customStatement(
        "INSERT INTO reduced_fields (collection, entity_id, field, value_json) "
        "VALUES ('todos', 't1', 'title', '\"Ship it\"')");
    await seed.customStatement(
        "INSERT INTO field_clocks (collection, entity_id, field, wall_ms, counter, member_id_hex) "
        "VALUES ('todos', 't1', 'title', 5, 0, '${'a' * 32}')");
    await seed.customStatement(
        "INSERT INTO change_sequence (change_id, source, change_json) VALUES ('c1', 'local', '{}')");
    await seed.customStatement(
        "INSERT INTO plugin_cursors (plugin_id, acknowledged_sequence) VALUES ('p', 0)");
    await seed.customStatement('PRAGMA user_version = 11');
    await seed.close();

    final upgraded = SyncDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final tables = (await upgraded
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
            .get())
        .map((row) => row.read<String>('name'));
    expect(tables, containsAll([
      'folder_sync_bindings',
      'folder_pending_appends',
      'folder_peers',
    ]));
    for (final table in ['folder_sync_bindings', 'folder_pending_appends', 'folder_peers']) {
      expect(await upgraded.customSelect('SELECT 1 FROM $table').get(), isEmpty);
    }
    expect(await upgraded.customSelect('SELECT 1 FROM reduced_fields').get(), hasLength(1));
    expect(await upgraded.customSelect('SELECT 1 FROM field_clocks').get(), hasLength(1));
    expect(await upgraded.customSelect('SELECT 1 FROM change_sequence').get(), hasLength(1));
    expect(await upgraded.customSelect('SELECT 1 FROM plugin_cursors').get(), hasLength(1));
  });
}
