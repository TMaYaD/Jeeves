/// The sync store's upgrade path, with the vault's base copies in it.
///
/// The vault added one table to the sync store: `vault_page_bases`, its private
/// copies of the pages it wrote. The upgrade must add that table and touch
/// nothing else — a device that already holds a log keeps every byte of it.
///
/// The test upgrades a real store on disk: it is opened at the current version,
/// taken back to the previous one, and opened again. What the upgrade must not
/// lose is checked row by row.
@TestOn('!browser')
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/sync_database.dart';

void main() {
  test('an upgrade from the previous version keeps every row and adds the table',
      () async {
    final directory = await Directory.systemTemp.createTemp('vault-migration');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/sync.sqlite');

    // A store at the current version, holding a row of every kind the upgrade
    // must not touch: a cursor, a sequence entry, a reduced field with its
    // clock, and a tombstone.
    final current = SyncDatabase(NativeDatabase(file));
    await current.customStatement(
      'INSERT INTO plugin_cursors (plugin_id, acknowledged_sequence) VALUES (?, ?)',
      ['vault', 7],
    );
    await current.customStatement(
      'INSERT INTO change_sequence (change_id, source, change_json) VALUES (?, ?, ?)',
      ['change-1', 'local', '{"collection":"todos"}'],
    );
    await current.customStatement(
      'INSERT INTO reduced_fields (collection, entity_id, field, value_json) '
      'VALUES (?, ?, ?, ?)',
      ['todos', 'outcome-1', 'title', '"Ship it"'],
    );
    await current.customStatement(
      'INSERT INTO field_clocks (collection, entity_id, field, wall_ms, counter, '
      'member_id_hex) VALUES (?, ?, ?, ?, ?, ?)',
      ['todos', 'outcome-1', 'title', 1700000000000, 1, 'aabb'],
    );
    await current.customStatement(
      'INSERT INTO row_tombstones (collection, entity_id, wall_ms, counter, '
      'member_id_hex) VALUES (?, ?, ?, ?, ?)',
      ['todos', 'outcome-2', 1700000000000, 1, 'aabb'],
    );

    // The store as a device that has not upgraded yet: the previous version,
    // without the vault's table. The version is set back after the store is
    // opened, so the downgrade is never read as an upgrade in progress.
    await current.customStatement('DROP TABLE vault_page_bases');
    await current.customStatement('PRAGMA user_version = 11');
    await current.close();

    final upgraded = SyncDatabase(NativeDatabase(file));
    // The first query opens the store and runs the upgrade.
    await upgraded.customSelect('SELECT 1').get();

    // The table is there.
    final tables = await upgraded.customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'vault_page_bases'",
    ).get();
    expect(tables, hasLength(1), reason: 'the upgrade adds the base table');

    // Every row is still there, unchanged.
    final cursors = await upgraded.customSelect(
      'SELECT plugin_id, acknowledged_sequence FROM plugin_cursors',
    ).get();
    expect(cursors, hasLength(1));
    expect(cursors.single.read<String>('plugin_id'), 'vault');
    expect(cursors.single.read<int>('acknowledged_sequence'), 7);

    final sequence = await upgraded.customSelect(
      'SELECT change_id, source, change_json FROM change_sequence',
    ).get();
    expect(sequence, hasLength(1));
    expect(sequence.single.read<String>('change_id'), 'change-1');
    expect(sequence.single.read<String>('source'), 'local');
    expect(sequence.single.read<String>('change_json'), '{"collection":"todos"}');

    final fields = await upgraded.customSelect(
      'SELECT collection, entity_id, field, value_json FROM reduced_fields',
    ).get();
    expect(fields, hasLength(1));
    expect(fields.single.read<String>('value_json'), '"Ship it"');

    final clocks = await upgraded.customSelect(
      'SELECT collection, entity_id, field, wall_ms, counter, member_id_hex '
      'FROM field_clocks',
    ).get();
    expect(clocks, hasLength(1));
    expect(clocks.single.read<int>('wall_ms'), 1700000000000);
    expect(clocks.single.read<int>('counter'), 1);
    expect(clocks.single.read<String>('member_id_hex'), 'aabb');

    final tombstones = await upgraded.customSelect(
      'SELECT collection, entity_id FROM row_tombstones',
    ).get();
    expect(tombstones, hasLength(1));
    expect(tombstones.single.read<String>('entity_id'), 'outcome-2');

    // And the store is at the current version now.
    final version = await upgraded.customSelect('PRAGMA user_version').get();
    expect(version.single.read<int>('user_version'), 12);

    await upgraded.close();
  });
}
