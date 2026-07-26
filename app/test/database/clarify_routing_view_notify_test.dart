/// Regression test for #342 — "Inbox/Next Actions watchers go stale after
/// clarify-routing on a new planning day."
///
/// In production `todos` is a PowerSync **view** with INSTEAD OF triggers, so a
/// Drift `UpdateStatement.write` against it reports `changes() == 0` (the
/// trigger body, not the view, mutates rows). Drift gates its own stream
/// invalidation on `rows > 0`, so it never fires for such writes — leaving the
/// async `SqliteAsyncDriftConnection` bridge as the *only* path that refreshes
/// the `todos`-view watchers. When that bridge is silent (observed on the first
/// cold start of a new planning day) the Inbox list / badge and Next Actions
/// list freeze until the app restarts.
///
/// This test recreates that exact topology on a real on-disk sqlite_async
/// database: `todos` is a view over a backing `todos_data` table with INSTEAD OF
/// triggers, wired to Drift through the same `SqliteAsyncDriftConnection` used
/// in production. Because the bridge's update notifications name the backing
/// table (`todos_data`), not the `todos` view, they never invalidate the
/// view-backed watchers — so the only way `watchNext` can refresh after
/// `applyRouting` is Drift's own in-process notification, which the fix
/// restores. No mocks; the write really persists through the trigger.
///
/// The guarded regression is the `todos`-view invalidation mechanism itself, so
/// any live `todos` watcher exercises it; `watchNext` stands in for the Inbox /
/// Next Actions lists that froze in #342 (the Inbox now reads `captures`, a
/// separate view — see ADR-0006).
@TestOn('!browser')
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_async/sqlite_async.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show RoutingKind;

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

/// Rewrites `todos` from a real table into a PowerSync-style view over a
/// `todos_data` backing table with INSTEAD OF triggers, mirroring what
/// `powersync_replace_schema` installs in production.
Future<void> _convertTodosToView(SqliteDatabase raw) async {
  final info = await raw.getAll('PRAGMA table_info(todos)');
  final cols = info.map((r) => r['name'] as String).toList();
  final colList = cols.join(', ');
  final newValues = cols.map((c) => 'NEW.$c').join(', ');
  final setClause =
      cols.where((c) => c != 'id').map((c) => '$c = NEW.$c').join(', ');

  await raw.writeTransaction((tx) async {
    await tx.execute('ALTER TABLE todos RENAME TO todos_data');
    await tx.execute('CREATE VIEW todos AS SELECT $colList FROM todos_data');
    await tx.execute('''
CREATE TRIGGER todos_insert INSTEAD OF INSERT ON todos BEGIN
  INSERT INTO todos_data ($colList) VALUES ($newValues);
END;''');
    await tx.execute('''
CREATE TRIGGER todos_update INSTEAD OF UPDATE ON todos BEGIN
  UPDATE todos_data SET $setClause WHERE id = OLD.id;
END;''');
    await tx.execute('''
CREATE TRIGGER todos_delete INSTEAD OF DELETE ON todos BEGIN
  DELETE FROM todos_data WHERE id = OLD.id;
END;''');
  });
}

void main() {
  late Directory tempDir;
  late String dbPath;
  late SqliteDatabase raw;
  late GtdDatabase db;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('jeeves_342_');
    dbPath = '${tempDir.path}/jeeves.sqlite';

    raw = SqliteDatabase(path: dbPath);
    await raw.initialize();

    // First open: let Drift's migrator build the full schema as real tables and
    // stamp user_version, exactly as it would on a fresh device.
    final bootstrap = GtdDatabase(SqliteAsyncDriftConnection(raw));
    await bootstrap.customSelect('SELECT 1').get();
    await bootstrap.close();

    // Swap `todos` for a view + INSTEAD OF triggers (the production shape).
    await _convertTodosToView(raw);

    // Reopen: user_version already matches, so no migration runs and the DAOs
    // now read/write the `todos` view through the async bridge.
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
    'clarify-routing a todos row refreshes the Next Actions watcher '
    'even when the async update bridge never names the todos view',
    () async {
      // Seed an unclarified row directly (the pre-split Inbox shape); it is
      // absent from Next until routing flips clarified + intent.
      await db.into(db.todos).insert(TodosCompanion(
        id: const Value('t1'),
        title: const Value('Draft the quarterly plan'),
        clarified: const Value(false),
        createdAt: Value(DateTime.now()),
        userId: const Value('user-1'),
      ));

      final next = <List<Todo>>[];
      final subNext = db.todoDao.watchNext().listen(next.add);
      addTearDown(() => subNext.cancel());

      // Initial state: nothing on Next (the row is still unclarified).
      await _waitUntil(() => next.isNotEmpty);
      expect(next.last, isEmpty);

      // PROCESS TO → Next Action from the Clarify card.
      await db.todoDao.applyRouting(
        't1',
        to: RoutingKind.nextAction,
        actionText: 'Outline the three sections',
      );

      // The write persisted (trigger wrote todos_data), but on `main` the view
      // UPDATE reports changes()==0 and the bridge only names `todos_data`, so
      // without the fix this wait times out — the stale condition from #342.
      await _waitUntil(() => next.last.length == 1);
      expect(next.last.map((t) => t.id), ['t1']);
    },
  );
}
