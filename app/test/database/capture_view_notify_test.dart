/// View-notify regression test for the Capture tables (issue #184).
///
/// Over the **production topology**: `jeeves_domain.sqlite` on disk through
/// `sqlite_async`, every synced name a real table Drift created (#595). The
/// PowerSync-view emulation this file used to install went with the engine.
///
/// What it still proves is that the Inbox stays live across writes Drift's own
/// invalidation does not cover: `watchInbox` reads across `captures` and
/// `capture_tags`, and provenance reads `capture_outcomes`, so a write to one has
/// to refresh watchers naming another. [GtdDatabase.notifyCapturesViewWrite]
/// notifies all three as one group, and a new `CaptureDao` write that forgets the
/// call is the foot-gun this notify exists for.
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

    // Drift builds the whole schema as real tables on first open — the store's
    // production shape since #595.
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
    'inserting and stamping a Capture refreshes the Inbox watcher',
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

      // `watchInbox` reads across `captures` and `capture_tags`, which is why
      // the group notify rather than Drift's per-table invalidation is the
      // contract here.
      await _waitUntil(() => inbox.last.length == 1);
      expect(inbox.last.map((c) => c.id), ['c1']);

      // Stamping must drop it from the Inbox live.
      await db.captureDao.stampClarified('c1');
      await _waitUntil(() => inbox.last.isEmpty);
      expect(inbox.last, isEmpty);
    },
  );

  test(
    'tag-hint and provenance-link writes refresh watchers that name a '
    'different Capture table',
    () async {
      await db.captureDao.insertCapture(CapturesCompanion(
        id: const Value('c1'),
        title: const Value('Draft the quarterly plan'),
        createdAt: Value(DateTime.now()),
        userId: const Value('user-1'),
      ));

      // Reads `captures` joined to `capture_tags`: Inbox filtered by a hint.
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

      // Reads `captures` joined to `capture_outcomes`: an Outcome provenance.
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
