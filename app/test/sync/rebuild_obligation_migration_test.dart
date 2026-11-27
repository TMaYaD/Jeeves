/// The sync store's upgrade path, with the marker of an owed grant re-check in it.
///
/// v17 added one nullable column, `sync_cursors.rebuild_required_at`. The upgrade
/// must add it, null, and touch nothing else: a device that already holds a
/// cursor keeps it.
@TestOn('!browser')
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/sync_database.dart';

import 'harness/resolution_columns.dart';

void main() {
  test('an upgrade from v16 adds the marker, null, and keeps the cursor',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('rebuild-obligation-migration');
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
      'INSERT INTO sync_cursors (workspace_id, last_seq, last_sync_completed_at) '
      'VALUES (?, ?, ?)',
      ['workspace-1', 42, 1700000000],
    );

    // The store as a device that has not upgraded yet: v16, without the column.
    await dropColumnsAddedAfter(current, 16);
    await current.customStatement('PRAGMA user_version = 16');
    await closeCurrent();

    final upgraded = SyncDatabase(NativeDatabase(file));
    var upgradedClosed = false;
    Future<void> closeUpgraded() async {
      if (upgradedClosed) return;
      upgradedClosed = true;
      await upgraded.close();
    }

    addTearDown(closeUpgraded);
    final rows = await upgraded.select(upgraded.syncCursors).get();
    expect(rows, hasLength(1));
    expect(rows.single.lastSeq, 42, reason: 'the cursor survives the upgrade');
    expect(rows.single.lastSyncCompletedAt, isNotNull);
    expect(rows.single.rebuildRequiredAt, isNull,
        reason: 'nothing a previous build held in memory is recoverable');

    final version = await upgraded.customSelect('PRAGMA user_version').get();
    expect(version.single.read<int>('user_version'),
        SyncDatabase.supportedSchemaVersion);

    await closeUpgraded();
  });
}
