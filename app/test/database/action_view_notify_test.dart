/// ADR-0010 view-notify regression for `actions` (issue #472), sibling of
/// `clarify_routing_view_notify_test.dart`.
///
/// In production `actions` is a PowerSync **view** with INSTEAD OF triggers, so
/// a Drift write against it reports `changes() == 0` and Drift's own stream
/// invalidation (gated on `rows > 0`) never fires — the only thing that
/// refreshes an `actions`-view watcher is the explicit
/// `GtdDatabase.notifyActionsViewWrite` an [ActionDao] write issues after
/// commit. This recreates that exact topology on a real sqlite_async database
/// and proves (a) an ActionDao primitive refreshes an `actions` watcher, and
/// (b) a `TodoDao` dual-write refreshes both the `todos`- and `actions`-view
/// watchers.
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
Future<void> _convertTableToView(SqliteDatabase raw, String table) async {
  final info = await raw.getAll('PRAGMA table_info($table)');
  final cols = info.map((r) => r['name'] as String).toList();
  final colList = cols.join(', ');
  final newValues = cols.map((c) => 'NEW.$c').join(', ');
  final setClause =
      cols.where((c) => c != 'id').map((c) => '$c = NEW.$c').join(', ');

  await raw.writeTransaction((tx) async {
    await tx.execute('ALTER TABLE $table RENAME TO ${table}_data');
    await tx.execute('CREATE VIEW $table AS SELECT $colList FROM ${table}_data');
    await tx.execute('''
CREATE TRIGGER ${table}_insert INSTEAD OF INSERT ON $table BEGIN
  INSERT INTO ${table}_data ($colList) VALUES ($newValues);
END;''');
    await tx.execute('''
CREATE TRIGGER ${table}_update INSTEAD OF UPDATE ON $table BEGIN
  UPDATE ${table}_data SET $setClause WHERE id = OLD.id;
END;''');
    await tx.execute('''
CREATE TRIGGER ${table}_delete INSTEAD OF DELETE ON $table BEGIN
  DELETE FROM ${table}_data WHERE id = OLD.id;
END;''');
  });
}

void main() {
  late Directory tempDir;
  late SqliteDatabase raw;
  late GtdDatabase db;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('jeeves_472_');
    final dbPath = '${tempDir.path}/jeeves.sqlite';

    raw = SqliteDatabase(path: dbPath);
    await raw.initialize();

    // Let Drift build the full schema as real tables on first open.
    final bootstrap = GtdDatabase(SqliteAsyncDriftConnection(raw));
    await bootstrap.customSelect('SELECT 1').get();
    await bootstrap.close();

    // Swap `todos`, `actions` and `time_logs` for view + INSTEAD OF triggers
    // (production topology): a Drift write reports changes()==0 and a watcher on
    // the view only refreshes via the DAO's explicit post-commit notify.
    await _convertTableToView(raw, 'todos');
    await _convertTableToView(raw, 'actions');
    await _convertTableToView(raw, 'time_logs');

    db = GtdDatabase(SqliteAsyncDriftConnection(raw));
    // Insert through the Drift API so column defaults (e.g. the NOT NULL
    // `intent`) are applied before the view's INSTEAD OF trigger forwards them.
    await db.into(db.todos).insert(TodosCompanion(
          id: const Value('o1'),
          title: const Value('Outcome'),
          userId: const Value('u1'),
          createdAt: Value(DateTime.parse('2026-07-01T09:00:00.000Z')),
          clarified: const Value(true),
        ));
  });

  tearDown(() async {
    await db.close();
    await raw.close();
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  Stream<List<String>> watchActionTexts() => db
      .customSelect(
        "SELECT text FROM actions WHERE outcome_id = 'o1' AND role = 'current'",
        readsFrom: {db.actions},
      )
      .watch()
      .map((rows) => rows.map((r) => r.read<String>('text')).toList());

  test('an ActionDao primitive refreshes an actions-view watcher even though '
      'the trigger makes the write report changes()==0', () async {
    final seen = <List<String>>[];
    final sub = watchActionTexts().listen(seen.add);
    addTearDown(sub.cancel);

    await _waitUntil(() => seen.isNotEmpty);
    expect(seen.last, isEmpty);

    await db.actionDao.setCurrentAction('o1', 'call the plumber');

    await _waitUntil(() => seen.last.length == 1);
    expect(seen.last, ['call the plumber']);
  });

  test('completeCurrentAction refreshes both view watchers — the cursor clear '
      'touches `todos` without stamping, so the todos notify cannot be gated '
      'on the stamp', () async {
    await db.todoDao.setNextActionText('o1', 'call the plumber');

    final cursors = <List<String>>[];
    final actionRoles = <List<String>>[];
    final subTodo = db
        .customSelect(
          "SELECT next_action_text FROM todos WHERE id = 'o1'",
          readsFrom: {db.todos},
        )
        .watch()
        .map((rows) =>
            rows.map((r) => r.read<String?>('next_action_text') ?? '').toList())
        .listen(cursors.add);
    final subAction = db
        .customSelect(
          "SELECT role FROM actions WHERE outcome_id = 'o1'",
          readsFrom: {db.actions},
        )
        .watch()
        .map((rows) => rows.map((r) => r.read<String>('role')).toList())
        .listen(actionRoles.add);
    addTearDown(subTodo.cancel);
    addTearDown(subAction.cancel);

    await _waitUntil(() =>
        cursors.isNotEmpty &&
        cursors.last.first == 'call the plumber' &&
        actionRoles.isNotEmpty &&
        actionRoles.last.contains('current'));

    await db.actionDao.completeCurrentAction('o1');

    await _waitUntil(() =>
        cursors.last.first == '' && actionRoles.last.contains('done'));
    expect(cursors.last, ['']);
    expect(actionRoles.last, ['done']);
  });

  test('clearCurrentAction refreshes both view watchers — its cursor clear '
      'rides on the stamp, which an abandon always moves', () async {
    await db.todoDao.setNextActionText('o1', 'call the plumber');

    final cursors = <List<String>>[];
    final actionRoles = <List<String>>[];
    final subTodo = db
        .customSelect(
          "SELECT next_action_text FROM todos WHERE id = 'o1'",
          readsFrom: {db.todos},
        )
        .watch()
        .map((rows) =>
            rows.map((r) => r.read<String?>('next_action_text') ?? '').toList())
        .listen(cursors.add);
    final subAction = db
        .customSelect(
          "SELECT role FROM actions WHERE outcome_id = 'o1'",
          readsFrom: {db.actions},
        )
        .watch()
        .map((rows) => rows.map((r) => r.read<String>('role')).toList())
        .listen(actionRoles.add);
    addTearDown(subTodo.cancel);
    addTearDown(subAction.cancel);

    await _waitUntil(() =>
        cursors.isNotEmpty &&
        cursors.last.first == 'call the plumber' &&
        actionRoles.isNotEmpty &&
        actionRoles.last.contains('current'));

    await db.actionDao.clearCurrentAction('o1');

    await _waitUntil(() =>
        cursors.last.first == '' && actionRoles.last.contains('superseded'));
    expect(cursors.last, ['']);
    expect(actionRoles.last, ['superseded']);
  });

  test('completeCurrentAction refreshes a time_logs-view watcher when it '
      'closes the open log (ADR-0010, issue #476)', () async {
    await db.actionDao.setCurrentAction('o1', 'call the plumber');
    final current = await db.actionDao.getCurrentAction('o1');
    // Open a stint against the current Action (through the view's trigger).
    await db.into(db.timeLogs).insert(TimeLogsCompanion(
          id: const Value('log-1'),
          userId: const Value('u1'),
          taskId: const Value('o1'),
          actionId: Value(current!.id),
          startedAt:
              Value(DateTime.parse('2026-07-01T10:00:00.000Z').toIso8601String()),
        ));

    final openCounts = <int>[];
    final sub = db
        .customSelect(
          'SELECT COUNT(*) AS c FROM time_logs WHERE ended_at IS NULL',
          readsFrom: {db.timeLogs},
        )
        .watch()
        .map((rows) => rows.first.read<int>('c'))
        .listen(openCounts.add);
    addTearDown(sub.cancel);

    await _waitUntil(() => openCounts.isNotEmpty && openCounts.last == 1);

    // Completing the Action closes the log; the time_logs view write reports
    // changes()==0, so only notifyTimeLogsViewWrite refreshes this watcher.
    await db.actionDao.completeCurrentAction('o1');

    await _waitUntil(() => openCounts.last == 0);
    expect(openCounts.last, 0);
  });

  test('a TodoDao dual-write refreshes both the todos- and actions-view '
      'watchers', () async {
    final todoTitles = <List<String>>[];
    final actionTexts = <List<String>>[];
    final subTodo = db
        .customSelect(
          "SELECT next_action_text FROM todos WHERE id = 'o1'",
          readsFrom: {db.todos},
        )
        .watch()
        .map((rows) =>
            rows.map((r) => r.read<String?>('next_action_text') ?? '').toList())
        .listen(todoTitles.add);
    final subAction = watchActionTexts().listen(actionTexts.add);
    addTearDown(subTodo.cancel);
    addTearDown(subAction.cancel);

    await _waitUntil(() => todoTitles.isNotEmpty && actionTexts.isNotEmpty);

    await db.todoDao.setNextActionText('o1', 'draft the plan');

    await _waitUntil(() =>
        todoTitles.last.length == 1 &&
        todoTitles.last.first == 'draft the plan' &&
        actionTexts.last.length == 1 &&
        actionTexts.last.first == 'draft the plan');
    expect(todoTitles.last, ['draft the plan']);
    expect(actionTexts.last, ['draft the plan']);
  });
}
