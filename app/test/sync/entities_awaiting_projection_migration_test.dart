/// The sync store's upgrade path, with the record of owed projections in it.
///
/// v16 added one table, `entities_awaiting_projection`. The upgrade must add that
/// table and touch nothing else: a device that already holds a log keeps every
/// byte of it.
@TestOn('!browser')
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/sync_database.dart';

import 'harness/resolution_columns.dart';

void main() {
  test('an upgrade from v15 adds the table and keeps the reduced state', () async {
    final directory =
        await Directory.systemTemp.createTemp('awaiting-projection-migration');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/sync.sqlite');

    final current = SyncDatabase(NativeDatabase(file));
    var currentClosed = false;
    Future<void> closeCurrent() async {
      if (currentClosed) return;
      currentClosed = true;
      await current.close();
    }

    addTearDown(closeCurrent);
    await current.customStatement(
      'INSERT INTO reduced_fields (collection, entity_id, field, value_json) '
      'VALUES (?, ?, ?, ?)',
      ['todos', 'outcome-1', 'title', '"Ship it"'],
    );
    await current.customStatement(
      'INSERT INTO plugin_cursors (plugin_id, acknowledged_sequence) VALUES (?, ?)',
      ['vault', 7],
    );

    // The store as a device that has not upgraded yet: v15, without the table.
    await dropColumnsAddedAfter(current, 15);
    await current.customStatement('PRAGMA user_version = 15');
    await closeCurrent();

    final upgraded = SyncDatabase(NativeDatabase(file));
    var upgradedClosed = false;
    Future<void> closeUpgraded() async {
      if (upgradedClosed) return;
      upgradedClosed = true;
      await upgraded.close();
    }

    addTearDown(closeUpgraded);
    // The first query opens the store and runs the upgrade.
    await upgraded.customSelect('SELECT 1').get();

    final tables = await upgraded.customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name = 'entities_awaiting_projection'",
    ).get();
    expect(tables, hasLength(1), reason: 'the upgrade adds the record table');
    expect(await upgraded.select(upgraded.entitiesAwaitingProjection).get(),
        isEmpty);

    final fields = await upgraded.customSelect(
      'SELECT value_json FROM reduced_fields',
    ).get();
    expect(fields.single.read<String>('value_json'), '"Ship it"');
    final cursors = await upgraded.customSelect(
      'SELECT acknowledged_sequence FROM plugin_cursors',
    ).get();
    expect(cursors.single.read<int>('acknowledged_sequence'), 7);

    final version = await upgraded.customSelect('PRAGMA user_version').get();
    expect(version.single.read<int>('user_version'),
        SyncDatabase.supportedSchemaVersion);

    await closeUpgraded();
  });
}
