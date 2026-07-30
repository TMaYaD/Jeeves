/// Regression test for #342 — "Inbox/Next Actions watchers go stale after
/// clarify-routing on a new planning day."
///
/// Over the **production topology**: `jeeves_domain.sqlite` on disk through
/// `sqlite_async`, `todos` a real table Drift created (#595). The file used to
/// rewrite `todos` into a PowerSync-style view with INSTEAD OF triggers, because
/// that was the shape #342 happened in — a Drift write against a view reports
/// `changes() == 0`, Drift's invalidation is gated on `rows > 0`, and the async
/// bridge named the backing table rather than the view. None of that topology
/// exists any more.
///
/// What survives is the claim that matters: `applyRouting` refreshes `watchNext`.
/// `watchNext` is a read across `todos`, `actions` and `time_logs`, so the
/// explicit `notifyTodosViewWrite` remains the contract rather than an
/// optimisation — a routing write that moved only an Action would otherwise leave
/// the list stale. `watchNext` stands in for the lists that froze in #342 (the
/// Inbox now reads `captures` — see ADR-0006). No mocks; the write really
/// persists.
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
    'clarify-routing an Outcome refreshes the Next Actions watcher',
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

      // Without the post-commit notify this wait times out for the reads that
      // span `actions` — the stale condition from #342.
      await _waitUntil(() => next.last.length == 1);
      expect(next.last.map((t) => t.id), ['t1']);
    },
  );
}
