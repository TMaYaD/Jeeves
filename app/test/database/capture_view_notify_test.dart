/// ADR-0010 regression test for the Capture views (issue #184).
///
/// In production `captures` / `capture_outcomes` / `capture_tags` are PowerSync
/// **views** with INSTEAD OF triggers, so a Drift write against them reports
/// `changes() == 0` and Drift never fires its own stream invalidation. The
/// async `SqliteAsyncDriftConnection` bridge names the *backing* tables, not the
/// views, so it cannot refresh view-backed watchers either. The only thing that
/// keeps `watchInbox` live after a `CaptureDao` write is
/// [GtdDatabase.notifyCapturesViewWrite] — this test proves a new `CaptureDao`
/// write that forgets the call would silently freeze the Inbox, exactly the
/// foot-gun ADR-0010 documents.
@TestOn('!browser')
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_async/sqlite_async.dart';

import 'package:jeeves/database/gtd_database.dart';

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met within $timeout', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Rewrites [table] from a real table into a PowerSync-style view over a
/// `<table>_data` backing table with INSTEAD OF triggers, mirroring what
/// `powersync_replace_schema` installs in production.
Future<void> _convertToView(SqliteDatabase raw, String table) async {
  final info = await raw.getAll('PRAGMA table_info($table)');
  final cols = info.map((r) => r['name'] as String).toList();
  final colList = cols.join(', ');
  final newValues = cols.map((c) => 'NEW.$c').join(', ');
  final setClause =
      cols.where((c) => c != 'id').map((c) => '$c = NEW.$c').join(', ');
  final data = '${table}_data';

  await raw.writeTransaction((tx) async {
    await tx.execute('ALTER TABLE $table RENAME TO $data');
    await tx.execute('CREATE VIEW $table AS SELECT $colList FROM $data');
    await tx.execute('''
CREATE TRIGGER ${table}_insert INSTEAD OF INSERT ON $table BEGIN
  INSERT INTO $data ($colList) VALUES ($newValues);
END;''');
    await tx.execute('''
CREATE TRIGGER ${table}_update INSTEAD OF UPDATE ON $table BEGIN
  UPDATE $data SET $setClause WHERE id = OLD.id;
END;''');
    await tx.execute('''
CREATE TRIGGER ${table}_delete INSTEAD OF DELETE ON $table BEGIN
  DELETE FROM $data WHERE id = OLD.id;
END;''');
  });
}

void main() {
  late Directory tempDir;
  late String dbPath;
  late SqliteDatabase raw;
  late GtdDatabase db;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('jeeves_184_');
    dbPath = '${tempDir.path}/jeeves.sqlite';

    raw = SqliteDatabase(path: dbPath);
    await raw.initialize();

    // First open: let Drift's migrator build the schema as real tables.
    final bootstrap = GtdDatabase(SqliteAsyncDriftConnection(raw));
    await bootstrap.customSelect('SELECT 1').get();
    await bootstrap.close();

    // Swap the Capture tables for views + INSTEAD OF triggers (production shape).
    await _convertToView(raw, 'captures');
    await _convertToView(raw, 'capture_tags');
    await _convertToView(raw, 'capture_outcomes');

    // Reopen: user_version already matches, so no migration runs and the DAO
    // now reads/writes the views through the async bridge.
    db = GtdDatabase(SqliteAsyncDriftConnection(raw));
  });

  tearDown(() async {
    await db.close();
    await raw.close();
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort cleanup
    }
  });

  test(
    'inserting and stamping a Capture refreshes the Inbox watcher even when '
    'the async bridge never names the captures view',
    () async {
      final inbox = <List<Capture>>[];
      final sub = db.captureDao.watchInbox().listen(inbox.add);
      addTearDown(sub.cancel);

      await _waitUntil(() => inbox.isNotEmpty);
      expect(inbox.last, isEmpty);

      await db.captureDao.insertCapture(CapturesCompanion(
        id: const Value('c1'),
        title: const Value('Draft the quarterly plan'),
        createdAt: Value(DateTime.now()),
        userId: const Value('user-1'),
      ));

      // Without notifyCapturesViewWrite this wait times out — the view INSERT
      // reports changes()==0 and the bridge only names `captures_data`.
      await _waitUntil(() => inbox.last.length == 1);
      expect(inbox.last.map((c) => c.id), ['c1']);

      // Stamping (an UPDATE on the view) must drop it from the Inbox live.
      await db.captureDao.stampClarified('c1');
      await _waitUntil(() => inbox.last.isEmpty);
      expect(inbox.last, isEmpty);
    },
  );

  test(
    'tag-hint and provenance-link writes on the capture_tags / '
    'capture_outcomes views refresh their watchers',
    () async {
      await db.captureDao.insertCapture(CapturesCompanion(
        id: const Value('c1'),
        title: const Value('Draft the quarterly plan'),
        createdAt: Value(DateTime.now()),
        userId: const Value('user-1'),
      ));

      // Watcher over the capture_tags view: Inbox filtered by a tag hint.
      final tagged = <List<Capture>>[];
      final subTag =
          db.captureDao.watchInbox(tagIds: {'tag-1'}).listen(tagged.add);
      addTearDown(subTag.cancel);
      await _waitUntil(() => tagged.isNotEmpty);
      expect(tagged.last, isEmpty);

      await db.captureDao.assignTagHint('c1', 'tag-1', 'user-1');
      await _waitUntil(() => tagged.last.length == 1);
      expect(tagged.last.map((c) => c.id), ['c1']);

      await db.captureDao.removeTagHint('c1', 'tag-1');
      await _waitUntil(() => tagged.last.isEmpty);
      expect(tagged.last, isEmpty);

      // Watcher over the capture_outcomes view: provenance for an Outcome.
      final prov = <List<Capture>>[];
      final subProv =
          db.captureDao.watchCapturesForOutcome('o1').listen(prov.add);
      addTearDown(subProv.cancel);
      await _waitUntil(() => prov.isNotEmpty);
      expect(prov.last, isEmpty);

      await db.captureDao.linkOutcome('c1', 'o1', 'user-1');
      await _waitUntil(() => prov.last.length == 1);
      expect(prov.last.map((c) => c.id), ['c1']);

      await db.captureDao.unlinkOutcome('c1', 'o1');
      await _waitUntil(() => prov.last.isEmpty);
      expect(prov.last, isEmpty);
    },
  );
}
